#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
source_file="$repo_root/tests/check/Findings.lean"
layout_file="$repo_root/tests/check/Layout.lean"
artifact_root="$repo_root/.lake/build/lean-fmt-artifacts"
# RDF-LAYOUT regression fixtures carry trailing whitespace and so are built at runtime, never committed
# (`git diff --check` rejects a checked-in file with trailing spaces, and editors strip them on save).
# They live under the lake root because `format`/`fix` need the file there; untracked, invisible to the
# printer corpus (`git ls-files 'LeanFmt/*.lean'`), removed by the trap.
nosel_fixture="$repo_root/tests/modes/.rdf-layout-nosel.lean"
string_fixture="$repo_root/tests/modes/.rdf-layout-string.lean"
tail_fixture="$repo_root/tests/modes/.rdf-layout-tail.lean"
# The RDF-IMPL mixed fixture carries both a layout defect (`namespace␣␣␣␣␣Alpha`) and an admitted fix (a
# duplicate import, FMT003). It imports `LeanFmt.Basic`, so it must live under the lake root; `fix`
# mutates it, so it is a fresh scratch, untracked, removed by the trap.
mixed_fixture="$repo_root/tests/modes/.rdf-impl-mixed.lean"
# RDF-FINAL confluence fixtures: two scratch copies of the mixed source driven through the two
# composition orders (`fix; format` and `format; fix`) to prove both reach the same fixed-point bytes.
comp_a_fixture="$repo_root/tests/modes/.rdf-final-comp-a.lean"
comp_b_fixture="$repo_root/tests/modes/.rdf-final-comp-b.lean"
# FIP-FINAL (`ruff-11d`) in-place-write acceptance fixtures: layout-dirty (exact-bytes/idempotence/
# --check), an elaboration-error `broken` file, a CRLF file and an in-string-whitespace file (write
# round-trip), a stale-source victim, and a no-arg project-selection pair (included + excluded). All
# scratch under the lake root, untracked, trap-removed; the CRLF/whitespace ones cannot be committed.
fin_exact_fixture="$repo_root/tests/modes/.fip-final-exact.lean"
fin_broken_fixture="$repo_root/tests/modes/.fip-final-broken.lean"
fin_crlf_fixture="$repo_root/tests/modes/.fip-final-crlf.lean"
fin_string_fixture="$repo_root/tests/modes/.fip-final-string.lean"
fin_stale_fixture="$repo_root/tests/modes/.fip-final-stale.lean"
fin_incl_fixture="$repo_root/tests/modes/.fip-final-incl.lean"
fin_excl_fixture="$repo_root/tests/modes/.fip-final-excl.lean"
# RCD-IMPL (`ruff-13`) write-path fixtures. `rcd_floor_fixture` lives *inside* `.lake` on purpose: gate
# 1 is the one selection gate no configuration key can lift, and the only honest way to test it is to
# put a real, writable, layout-dirty Lean file there and confirm every mode refuses it.
rcd_excl_fixture="$repo_root/tests/modes/.rcd-impl-excluded.lean"
rcd_floor_fixture="$repo_root/.lake/build/.rcd-impl-floor.lean"

# Both fixtures are edited in place below and both are tracked files, so restoring them is not
# cleanup — it is the difference between a failing test and a dirty working tree the next run
# silently measures instead.
restore() {
  if [[ -f "$work/Findings.lean" ]]; then
    cp -p "$work/Findings.lean" "$source_file"
  fi
  if [[ -f "$work/Layout.lean" ]]; then
    cp -p "$work/Layout.lean" "$layout_file"
  fi
  rm -rf "$cache_root" "$work" \
    "$nosel_fixture" "$string_fixture" "$tail_fixture" "$mixed_fixture" \
    "$comp_a_fixture" "$comp_b_fixture" \
    "$fin_exact_fixture" "$fin_broken_fixture" "$fin_crlf_fixture" "$fin_string_fixture" \
    "$fin_stale_fixture" "$fin_incl_fixture" "$fin_excl_fixture" \
    "$rcd_excl_fixture" "$rcd_floor_fixture"
  rm -f "$repo_root"/tests/modes/.fip-final-*.lean.lean-fmt-tmp-*
}
trap restore EXIT

cd "$repo_root"
cp -p "$source_file" "$work/Findings.lean"
cp -p "$layout_file" "$work/Layout.lean"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests \
  LocalSyntax:leanFmtArtifact Findings:leanFmtArtifact Clean:leanFmtArtifact \
  Layout:leanFmtArtifact
application=$(lake -q query lean-fmt --text)

run_expect() {
  local expected=$1
  local output=$2
  shift 2
  set +e
  "$@" >"$output" 2>"$output.stderr"
  local actual=$?
  set -e
  if [[ $actual -ne $expected ]]; then
    printf 'expected exit %s, got %s\n' "$expected" "$actual" >&2
    cat "$output" >&2
    cat "$output.stderr" >&2
    exit 1
  fi
}

metadata() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
for name in sys.argv[1:]:
    data = open(name, "rb").read()
    stat = os.stat(name)
    print(name, hashlib.sha256(data).hexdigest(), stat.st_mtime_ns, stat.st_mode & 0o777)
PY
}

tree_metadata() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
for directory, _, files in os.walk(root):
    for base in sorted(files):
        name = os.path.join(directory, base)
        data = open(name, "rb").read()
        stat = os.stat(name)
        print(os.path.relpath(name, root), hashlib.sha256(data).hexdigest(),
              stat.st_mtime_ns, stat.st_mode & 0o777)
PY
}

# Every non-writing preview — `check`, `format --check` (`ruff-11d`: the opt-in CI preview), and `diff`
# — consumes the same result and leaves source bytes, mtimes, and permissions untouched. `Findings.lean`
# is layout-clean but carries one FMT003 (duplicate import). Since `ruff-11c` RDF-IMPL split layout from
# fix, `format`/`diff` reflow only and apply **no** rule fix: on a layout-clean file they are `clean` and
# exit 0 even though `check` still reports the finding — the FMT003 dedup is a fix, not layout, and rides
# `fix` (exercised below), never `format`. (Plain `format` writes in place since `ruff-11d`; these
# previews use `--check` so the shared `Findings.lean` fixture stays byte-stable for the asserts below.)
metadata "$source_file" >"$work/source.before"
run_expect 1 "$work/check.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 0 "$work/format.json" "$application" format --check --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 0 "$work/diff.txt" "$application" diff --root . --no-cache \
  tests/check/Findings.lean
metadata "$source_file" >"$work/source.after-previews"
cmp "$work/source.before" "$work/source.after-previews"

python3 - "$work/check.json" "$work/format.json" "$work/diff.txt" <<'PY'
import json, sys
check = json.load(open(sys.argv[1]))
formatted = json.load(open(sys.argv[2]))
diff = open(sys.argv[3]).read()
# `check` reports the finding and its safe fix; it changes nothing on disk.
assert check["mode"] == "check" and check["changed"] == 1 and check["written"] == 0
assert [f["code"] for f in check["files"][0]["findings"]] == ["FMT003"]
# `format` applies no rule fix and the file is layout-clean, so it is `clean` — but it still reports the
# finding at original coordinates (`notes/01-model.md` §4: the report survives the patch split).
assert formatted["mode"] == "format" and formatted["changed"] == 0
assert formatted["files"][0]["status"] == "clean"
assert formatted["files"][0]["formatted"] is None
assert [f["code"] for f in formatted["files"][0]["findings"]] == ["FMT003"]
# `diff` likewise shows no layout change — an empty diff body, `changed=0`, the FMT003 dedup withheld
# from the layout preview. The stats line still reports the finding.
assert "@@" not in diff, repr(diff)
assert diff == ("mode=diff files=1 findings=1 changed=0 written=0 broken=0 rejected=0 "
    "withheld_unsafe=0 suppressed=0 infrastructure_failures=0\n"), repr(diff)
PY

# `RFP-IMPL`: **`format` formats.** This was `RFP-SPEC`'s characterization of the opposite — it
# asserted exit 0 and `clean`, pinning a `format` that previewed lint fixes and never looked at
# layout. Wiring the printer in flips it, which is what that test existed to force. Driven through
# `format --check` (`ruff-11d`) so the render is exercised without writing the tracked fixture; the
# in-place write of this same reflow is FIP-FINAL's exact-bytes acceptance.
#
# `tests/check/Layout.lean` holds `namespace     Alpha` — five spaces where `LeanFmt.Printer` renders
# exactly one (`Printer.lean:344-348` `wholeSpan?` -> `spaceSeparated`, `:511-515` citing Lean's
# `Command.lean:317-318`). It is otherwise lint-clean, which is the point: `findings` is 0 and
# `changed` is 1, so the report cannot be explained by a fix. Only layout moved.
#
# This is also the regression test for `PreparedFile.changed`. Basing the patch on canonical text
# makes `patch.changed` — "are there fix edits?" — the wrong question, and it answers `false` here.
# Had that survived, `format` would report this file clean while printing a different body, and
# `RFP-SPEC`'s test would have passed as though nothing were wired in at all.
run_expect 1 "$work/layout-format.json" "$application" format --check --root . --json --no-cache \
  tests/check/Layout.lean
python3 - "$work/layout-format.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["mode"] == "format", r["mode"]
assert r["findings"] == 0, f"layout-only change must carry no findings: {r}"
assert r["changed"] == 1 and r["written"] == 0, r
assert r["files"][0]["status"] == "would-format", r["files"][0]
assert r["files"][0]["formatted"] == \
    "module\n\nnamespace Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha\n", \
    repr(r["files"][0]["formatted"])
PY
grep -q 'namespace     Alpha' tests/check/Layout.lean ||
  {
    echo 'fixture lost its non-canonical spacing; the check above proves nothing' >&2
    exit 1
  }

# `check` does not move, and that is the roadmap's first bullet rather than an optimization:
# formatting is a canonical transformation, not a selectable rule, so it cannot enter rule selection
# and `check` reports selected rules. The same file `format` calls `would-format` is `check`-clean.
run_expect 0 "$work/layout-check.json" "$application" check --root . --json --no-cache \
  tests/check/Layout.lean
python3 - "$work/layout-check.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["mode"] == "check" and r["findings"] == 0 and r["changed"] == 0, r
assert r["files"][0]["status"] == "clean", r["files"][0]
PY

# A file whose only defect is the missing final newline. This is the case that decides whether
# `unifiedDiff` compares lines or *files*: `diffSource` reads the terminator into `finalNewline` and
# drops it, so "end Alpha\n" and "end Alpha" both project to the line "end Alpha". A diff over bare
# strings pairs them as unchanged and emits an empty hunk list — reporting `changed=1` above a diff
# showing nothing, for the single edit the formatter's final-newline normalization makes (a layout
# concern since `ruff-11c` RDF-LAYOUT, no longer the retired final-newline rule). `DiffLine` carries the terminator
# into the compared element to keep them unequal, and this test is why that type is not over-engineering.
printf 'module\n\nnamespace Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha' >"$layout_file"
run_expect 1 "$work/layout-nonl.diff" "$application" diff --root . --no-cache \
  tests/check/Layout.lean
python3 - "$work/layout-nonl.diff" <<'PY'
import sys
diff = open(sys.argv[1]).read()
# GNU diff's exact rendering: the marker follows the side that lacks the terminator, so the same
# text appears once removed and once added.
expected = "".join(line + "\n" for line in [
    "--- a/tests/check/Layout.lean",
    "+++ b/tests/check/Layout.lean",
    "@@ -4,4 +4,4 @@",
    " ",
    " def layoutValue : Nat := 1",
    " ",
    "-end Alpha",
    "\\ No newline at end of file",
    "+end Alpha",
    "mode=diff files=1 findings=0 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 "
    "suppressed=0 infrastructure_failures=0",
])
assert diff == expected, repr(diff)
PY
cp -p "$work/Layout.lean" "$layout_file"

# Artifact, exact fallback, and semantic-cache hit project to identical formatted output — the reflowed
# layout. `Layout.lean` reflows (`namespace     Alpha` -> `namespace Alpha`), so unlike the layout-clean
# `Findings.lean` above (on which `format` is now clean) it exercises a real canonical render across all
# three paths. Driven through `format --check`: the render is the same on every path, and `--check` keeps
# the cache-only fast path so the semantic-cache hit stays usable WITHOUT invoking an analyzer
# (`LEAN_FMT_TEST_ANALYZER=/usr/bin/false` proves it) — a writing `format` would need the validator child
# there and could not be served from cache alone (`ruff-11d` FIP-SPEC §5).
run_expect 1 "$work/format-artifact.json" "$application" format --check --root . --json \
  tests/check/Layout.lean
run_expect 1 "$work/format-hit.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" format --check --root . --json \
  tests/check/Layout.lean
cmp "$work/format-artifact.json" "$work/format-hit.json"
run_expect 1 "$work/format-fallback.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  "$application" format --check --root . --json --no-cache tests/check/Layout.lean
cmp "$work/format-artifact.json" "$work/format-fallback.json"
rm -rf "$cache_root"

# A `check`-populated entry is a **miss** for a rendering mode, not an under-populated hit. `check`
# takes the source-only shortcut and stores no canonical text, so serving its entry to `format` would
# put `prepareFile` on the `renderCanonical = true` but `canonical? = none` path — where it silently
# bases the patch on the file's own bytes and consults no layout. That is `RFP-SPEC`'s "format does
# not format", reintroduced through the cache and invisible: the report says `clean`, exit 0, which is
# indistinguishable from a file that needs nothing. `cacheHitServes` is the only thing standing there,
# so this pins it. The entry `check` leaves behind is real; only its usefulness to `format` is not.
rm -rf "$cache_root"
run_expect 0 "$work/seed-check.json" "$application" check --root . --json tests/check/Layout.lean
run_expect 1 "$work/after-check-format.json" "$application" format --check --root . --json \
  tests/check/Layout.lean
python3 - "$work/seed-check.json" "$work/after-check-format.json" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2]))
assert seed["files"][0]["status"] == "clean", seed
assert after["changed"] == 1, f"a check-populated hit suppressed layout: {after}"
assert after["files"][0]["status"] == "would-format", after["files"][0]
assert after["files"][0]["formatted"] == \
    "module\n\nnamespace Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha\n", \
    repr(after["files"][0]["formatted"])
PY
rm -rf "$cache_root"

cat >"$work/per-file.toml" <<'EOF'
select = ["default"]
[per-file-ignores]
"tests/check/Findings.lean" = ["FMT003"]
EOF
run_expect 0 "$work/projected-hit.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  --config "$work/per-file.toml" tests/check/Findings.lean
python3 - "$work/projected-hit.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["findings"] == r["changed"] == 0 and r["files"][0]["status"] == "clean"
PY

# Applicability travels on the finding's fix. `Findings.lean`'s one FMT003 is safe (an exact duplicate
# import is idempotent — removing it preserves what the elaborator records), so `check` reports it with
# an edit and nothing is withheld.
run_expect 1 "$work/applic-check.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
python3 - "$work/applic-check.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
fix = r["files"][0]["findings"][0]["fix"]
assert fix["applicability"] == "safe", fix
assert fix["edits"] and "range" in fix["edits"][0], fix
assert r["withheldUnsafe"] == 0, r
PY

# `extend-unsafe-fixes` demotes FMT003 as a plan projection no rule reads (`notes/01-model.md` §2).
# The reported finding now says `unsafe`; default `fix` withholds it with no write; `--unsafe-fixes`
# opts in and applies it. The one admission rule governs preview and write alike, so `check` above and
# `fix` here agree on what would apply. The file is layout-clean, so a withheld FMT003 leaves the
# canonical reflow with nothing to change — the write comes only from the admitted fix.
cat >"$work/demote.toml" <<'EOF'
select = ["default"]
extend-unsafe-fixes = ["FMT003"]
EOF
run_expect 1 "$work/demote-check.json" "$application" check --root . --json --no-cache \
  --config "$work/demote.toml" tests/check/Findings.lean
python3 - "$work/demote-check.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["files"][0]["findings"][0]["fix"]["applicability"] == "unsafe", r
assert r["withheldUnsafe"] == 1, r
PY
run_expect 0 "$work/demote-withhold.json" "$application" fix --root . --json --no-cache \
  --config "$work/demote.toml" tests/check/Findings.lean
metadata "$source_file" >"$work/source.after-withhold"
cmp "$work/source.before" "$work/source.after-withhold"
python3 - "$work/demote-withhold.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and r["withheldUnsafe"] == 1, r
assert r["files"][0]["status"] == "clean", r["files"][0]
PY
run_expect 0 "$work/demote-apply.json" "$application" fix --root . --json --no-cache \
  --unsafe-fixes --config "$work/demote.toml" tests/check/Findings.lean
python3 - "$work/demote-apply.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 1 and r["withheldUnsafe"] == 0, r
assert r["files"][0]["status"] == "fixed", r["files"][0]
PY
cp -p "$work/Findings.lean" "$source_file"

# A rule in both extend lists is a config contradiction, rejected before any file is read.
cat >"$work/both-lists.toml" <<'EOF'
extend-safe-fixes = ["FMT003"]
extend-unsafe-fixes = ["FMT003"]
EOF
run_expect 2 "$work/both-lists.out" "$application" check --root . --json --no-cache \
  --config "$work/both-lists.toml" tests/check/Findings.lean
grep -q 'both extend-safe-fixes and extend-unsafe-fixes' "$work/both-lists.out.stderr"

# Config path filtering, layered selector precedence, unknown-key rejection, and stderr-only
# statistics are product behavior rather than execution strategy.
cat >"$work/include.toml" <<'EOF'
include = ["tests/check/Clean.lean"]
select = ["default"]
EOF
run_expect 0 "$work/include.json" "$application" check --root . --json --no-cache \
  --config "$work/include.toml"
python3 - "$work/include.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert [f["path"] for f in r["files"]] == ["tests/check/Clean.lean"]
PY

cat >"$work/ignore.toml" <<'EOF'
select = ["default"]
ignore = ["FMT003"]
EOF
run_expect 0 "$work/config-ignore.json" "$application" check --root . --json --no-cache \
  --config "$work/ignore.toml" tests/check/Findings.lean
run_expect 1 "$work/cli-select.json" "$application" check --root . --json --no-cache \
  --config "$work/ignore.toml" --select FMT003 tests/check/Findings.lean

printf 'unknown = true\n' >"$work/unknown.toml"
run_expect 2 "$work/unknown.out" "$application" check --root . --json --no-cache \
  --config "$work/unknown.toml" tests/check/Clean.lean
grep -q 'unknown configuration key' "$work/unknown.out.stderr"

run_expect 1 "$work/statistics.json" "$application" check --root . --json --no-cache \
  --statistics tests/check/Findings.lean
python3 -m json.tool "$work/statistics.json" >/dev/null
grep -q '^lean-fmt statistics:' "$work/statistics.json.stderr"

# A semantic validation rejection and a stale-source race both reject the whole file without a
# formatter write. Successful fix preserves permissions, and a second fix is an unchanged no-op.
cat >"$work/reject-validator" <<'EOF'
#!/bin/sh
printf '%s\n' '{"artifact":null,"diagnostics":["forced validation rejection"]}'
EOF
chmod +x "$work/reject-validator"
run_expect 1 "$work/rejected.json" env LEAN_FMT_TEST_VALIDATOR="$work/reject-validator" \
  "$application" fix --root . --json --no-cache tests/check/Findings.lean
metadata "$source_file" >"$work/source.after-rejection"
cmp "$work/source.before" "$work/source.after-rejection"
python3 - "$work/rejected.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rejected"] == 1 and r["written"] == 0
assert "forced validation rejection" in r["files"][0]["diagnostics"]
PY

cat >"$work/stale-hook" <<'EOF'
#!/bin/sh
printf '\n-- concurrent change\n' >>"$1"
EOF
chmod +x "$work/stale-hook"
run_expect 1 "$work/stale.json" env LEAN_FMT_TEST_BEFORE_WRITE="$work/stale-hook" \
  "$application" fix --root . --json --no-cache tests/check/Findings.lean
grep -q 'source changed after analysis' "$work/stale.json"
cp -p "$work/Findings.lean" "$source_file"

# A crash between validation and the rename that commits the write. The before-write hook fails after
# the temp file exists but before `rename`, standing in for a process death at that instant. The commit
# is the single atomic `rename`, so the target keeps its exact bytes/mtime/mode, the run is an
# infrastructure failure (exit 2), and no `.lean-fmt-tmp-*` file is orphaned beside the source.
cat >"$work/crash-hook" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$work/crash-hook"
run_expect 2 "$work/crash.json" env LEAN_FMT_TEST_BEFORE_WRITE="$work/crash-hook" \
  "$application" fix --root . --json --no-cache tests/check/Findings.lean
metadata "$source_file" >"$work/source.after-crash"
cmp "$work/source.before" "$work/source.after-crash"
if compgen -G "$repo_root/tests/check/Findings.lean.lean-fmt-tmp-*" >/dev/null; then
  echo 'a crash before rename orphaned a temp file at the target' >&2
  exit 1
fi

original_mode=$(stat -f %Lp "$source_file" 2>/dev/null || stat -c %a "$source_file")
run_expect 0 "$work/fixed.json" "$application" fix --root . --json --no-cache --check-elab \
  tests/check/Findings.lean
fixed_mode=$(stat -f %Lp "$source_file" 2>/dev/null || stat -c %a "$source_file")
test "$original_mode" = "$fixed_mode"
run_expect 0 "$work/unchanged.json" "$application" fix --root . --json --no-cache \
  tests/check/Findings.lean
python3 - "$work/fixed.json" "$work/unchanged.json" <<'PY'
import json, sys
fixed, unchanged = (json.load(open(path)) for path in sys.argv[1:])
assert fixed["written"] == 1 and fixed["files"][0]["status"] == "fixed"
assert unchanged["written"] == 0 and unchanged["files"][0]["status"] == "clean"
PY
cp -p "$work/Findings.lean" "$source_file"

# Registry and compiler setup do not require a workspace. Setup is deterministic guidance, not a
# lakefile mutation. Status is deterministic and read-only over current module artifacts.
run_expect 0 "$work/rules.json" "$application" rules --json
python3 - "$work/rules.json" <<'PY'
import json, sys
rules = json.load(open(sys.argv[1]))
assert [r["code"] for r in rules] == \
    ["FMT001", "FMT002",
     "FMT006", "FMT007", "FMT008", "FMT009", "FMT010", "FMT011",
     "FMT012", "FMT013", "FMT014", "FMT015",
     "FMT003", "FMT004", "FMT005"], [r["code"] for r in rules]
# The source-security rules are report-only and their own category: FMT001/FMT002 flag bytes the
# formatter cannot express by reformatting. Trailing-whitespace/final-newline normalization is the
# formatter's layout since `ruff-11c` RDF-LAYOUT, not a rule, so no `text`-category rule remains. The
# import family is its own `imports` category: FMT003 (duplicate) carries a safe fix, FMT004
# (redundant, graph-derived) and FMT005 (order/grouping) are report-only.
by_code = {r["code"]: r for r in rules}
assert all((not by_code[c]["fixable"]) and by_code[c]["category"] == "security"
           for c in ("FMT001", "FMT002"))
assert by_code["FMT003"]["fixable"] and by_code["FMT003"]["category"] == "imports"
assert all((not by_code[c]["fixable"]) and by_code[c]["category"] == "imports"
           for c in ("FMT004", "FMT005"))
# FMT001/FMT002 (source-security) and FMT003-FMT005 (imports) are the default-enabled, source-tier
# rules: reported at source coordinates and projected onto the `source` tier for the wire shape.
source_default = ("FMT001", "FMT002", "FMT003", "FMT004", "FMT005")
assert all(by_code[c]["defaultEnabled"] and by_code[c]["input"] == "source" for c in source_default)
# FMT006-013 are the first syntax-tier rules and ship as preview: off by default, indexed on the
# compiler projection (`input == "syntax"`), opted into only by an explicit `--select`. Their
# categories name what each reports; FMT008/011/013 carry redundancy fixes, the rest are report-only.
preview = ("FMT006", "FMT007", "FMT008", "FMT009", "FMT010", "FMT011")
assert all((not by_code[c]["defaultEnabled"]) and by_code[c]["input"] == "syntax" for c in preview)
assert by_code["FMT006"]["category"] == "docs" and not by_code["FMT006"]["fixable"]
assert by_code["FMT007"]["category"] == "structure" and not by_code["FMT007"]["fixable"]
assert by_code["FMT010"]["category"] == "debug" and not by_code["FMT010"]["fixable"]
assert all(by_code[c]["fixable"] and by_code[c]["category"] == "redundancy"
           for c in ("FMT008", "FMT009", "FMT011"))
# FMT012-017 are semantic-tier rules (`ruff-11`): they surface compiler diagnostics, so they ship as
# preview (off by default) and are indexed on the `semantic` tier (`input == "semantic"`). FMT013-017
# stay report-only — an unused binder or a name resemblance is not an edit any fact here proves safe.
# FMT012 is the one owned, fixable semantic rule (`ruff-11b`): its unsafe rename of a deprecated
# reference to its replacement makes it `fixable`, though the fix is withheld unless `--unsafe-fixes`.
semantic = ("FMT012", "FMT013", "FMT014", "FMT015")
assert all((not by_code[c]["defaultEnabled"]) and by_code[c]["input"] == "semantic" for c in semantic)
assert by_code["FMT012"]["fixable"]
assert all(not by_code[c]["fixable"] for c in ("FMT013", "FMT014", "FMT015"))
assert by_code["FMT012"]["category"] == "deprecation"
assert by_code["FMT013"]["category"] == "unused" and by_code["FMT014"]["category"] == "unused"
assert by_code["FMT015"]["category"] == "naming"
PY

run_expect 0 "$work/setup-1.json" "$application" compiler setup --json
run_expect 0 "$work/setup-2.json" "$application" compiler setup --json
cmp "$work/setup-1.json" "$work/setup-2.json"
python3 - "$work/setup-1.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["schema"] == "lean-fmt.compiler-setup.v1"
assert r["plugin"] == "LeanFmtCompilerPlugin:shared" and r["facet"] == "leanFmtArtifact"
PY

mkdir -p "$work/downstream"
cat >"$work/downstream/lakefile.lean" <<EOF
import Lake

open Lake DSL

package Downstream

require lean_fmt from "$repo_root"

lean_lib Downstream where
  roots := #[\`Downstream]
  plugins := #[\`@lean_fmt/LeanFmtCompilerPlugin:shared]
EOF
printf 'leanprover/lean4:v4.32.0\n' >"$work/downstream/lean-toolchain"
cat >"$work/downstream/Downstream.lean" <<'EOF'
module

def downstreamValue : Nat := 1  
EOF
(
  cd "$work/downstream"
  LEAN_NUM_THREADS=1 lake update >/dev/null
  LEAN_NUM_THREADS=1 lake build +Downstream:leanFmtArtifact >/dev/null
)
python3 - "$work/downstream/.lake/build/lean-fmt-artifacts/Downstream.json" <<'PY'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert artifact["source"]["mainModule"] == "Downstream"
# The artifact is the projection and nothing else. A downstream integrator gets facts about its
# module, never this formatter's verdicts about it -- that is what keeps a rule edit out of the
# integrator's build graph (`ruff-05-rule-engine/notes/01-rule-facts.md` §3).
assert "findings" not in artifact, artifact.keys()
assert artifact["source"]["tokens"], "the downstream projection recorded no tokens"
PY

# `compiler status` on a project that really is plugin-integrated. This is the only place a `ready`
# is genuinely earned: the audit at the repository root below reports on lean-fmt's own modules,
# which nothing builds with the plugin, so every one of them is `missing` or `unbuilt`.
run_expect 0 "$work/status-downstream.json" "$application" compiler status \
  --root "$work/downstream" --json
python3 - "$work/status-downstream.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["ready"] >= 1, r
assert [m["status"] for m in r["modules"]] == ["ready"], r["modules"]
PY

if [[ -d $artifact_root ]]; then
  tree_metadata "$artifact_root" >"$work/artifacts.before"
else
  : >"$work/artifacts.before"
fi
run_expect 0 "$work/status-1.json" "$application" compiler status --root . --json
run_expect 0 "$work/status-2.json" "$application" compiler status --root . --json
cmp "$work/status-1.json" "$work/status-2.json"
if [[ -d $artifact_root ]]; then
  tree_metadata "$artifact_root" >"$work/artifacts.after"
else
  : >"$work/artifacts.after"
fi
cmp "$work/artifacts.before" "$work/artifacts.after"
metadata "$source_file" >"$work/source.after-status"
cmp "$work/source.before" "$work/source.after-status"
python3 - "$work/status-1.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
paths = [m["path"] for m in r["modules"]]
assert paths == sorted(paths)
# Every module lands in exactly one bucket. Not `ready >= 2`: this repository's own modules are
# not built with the plugin, so a `ready` here would have to come from a fixture the configuration
# excludes -- and `exclude` prunes the walk, so the audit no longer sees one. The earned `ready`
# is asserted against the downstream project above.
assert r["ready"] + r["missing"] + r["unbuilt"] == len(paths)
assert set(m["status"] for m in r["modules"]) <= {"ready", "missing", "unbuilt"}
PY

# Clean removes exactly the project result cache, is idempotent, and leaves source/build artifacts.
mkdir -p "$cache_root"
printf 'cache\n' >"$cache_root/sentinel"
printf 'build\n' >"$work/build-sentinel"
cp "$work/build-sentinel" .lake/build/lean-fmt-clean-sentinel
run_expect 0 "$work/clean-1.json" "$application" clean --root . --json
test ! -e "$cache_root"
test -f .lake/build/lean-fmt-clean-sentinel
run_expect 0 "$work/clean-2.json" "$application" clean --root . --json
python3 - "$work/clean-1.json" "$work/clean-2.json" <<'PY'
import json, sys
first, second = (json.load(open(path)) for path in sys.argv[1:])
assert first["removed"] is True and second["removed"] is False
PY
rm .lake/build/lean-fmt-clean-sentinel
metadata "$source_file" >"$work/source.final"
cmp "$work/source.before" "$work/source.final"

# --- RDF-IMPL: layout and fix are decoupled. On a fixture with **both** a layout defect
#     (`namespace␣␣␣␣␣Alpha`) and an admitted fixable finding (a duplicate import, FMT003), `format`
#     reflows the layout and leaves the finding, while `fix` applies the finding at original coordinates
#     and does **not** reflow. A user composes them as `fix` then `format`, like `ruff check --fix` then
#     `ruff format`. ---
printf 'module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n' \
  >"$mixed_fixture"

# `format --check` reflows the namespace spacing but keeps BOTH imports — the dedup is a fix, not layout
# — and still reports the FMT003 finding at original coordinates. (`--check` so the shared mixed fixture
# is intact for the `fix` step below, which must see the original both-imports source.)
run_expect 1 "$work/mixed-format.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.rdf-impl-mixed.lean
python3 - "$work/mixed-format.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["mode"] == "format" and r["changed"] == 1, r
f, = r["files"]
assert f["status"] == "would-format", f
assert [x["code"] for x in f["findings"]] == ["FMT003"], f          # finding survives format
assert f["formatted"] == \
    "module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace Alpha\n\n" \
    "def mixedValue : Nat := 1\n\nend Alpha\n", repr(f["formatted"])  # reflowed, NOT deduped
PY

# `diff` equals the `format` preview: same reflow, same withheld fix.
run_expect 1 "$work/mixed-diff.txt" "$application" diff --root . --no-cache \
  tests/modes/.rdf-impl-mixed.lean
python3 - "$work/mixed-diff.txt" <<'PY'
import sys
diff = open(sys.argv[1]).read()
# the only hunk collapses the namespace spacing; no import line is removed.
assert "-namespace     Alpha" in diff and "+namespace Alpha" in diff, repr(diff)
assert "import LeanFmt.Basic" not in diff.replace(" import", ""), repr(diff)  # no import edit
assert diff.rstrip().endswith("findings=1 changed=1 written=0 broken=0 rejected=0 "
    "withheld_unsafe=0 suppressed=0 infrastructure_failures=0"), repr(diff)
PY

# `fix` applies the FMT003 dedup at original coordinates and does NOT reflow: the bad namespace spacing
# is preserved byte-for-byte, exactly one import remains, and the file is written.
run_expect 0 "$work/mixed-fix.json" "$application" fix --root . --json --no-cache \
  tests/modes/.rdf-impl-mixed.lean
python3 - "$work/mixed-fix.json" "$mixed_fixture" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 1, r
f, = r["files"]
assert f["status"] == "fixed", f
data = open(sys.argv[2], "rb").read()
assert data == \
    b"module\n\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n", \
    repr(data)  # deduped, layout (five spaces) untouched
PY

# The fixed file is now free of the finding (`check` reports nothing) but still layout-dirty, so a
# following `format` is what reflows it — the two-command composition reaching its fixed point.
run_expect 0 "$work/mixed-recheck.json" "$application" check --root . --json --no-cache \
  tests/modes/.rdf-impl-mixed.lean
python3 - "$work/mixed-recheck.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "clean" and f["findings"] == [], f
PY
run_expect 1 "$work/mixed-postfix-format.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.rdf-impl-mixed.lean
python3 - "$work/mixed-postfix-format.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "would-format" and f["findings"] == [], f
assert f["formatted"] == \
    "module\n\nimport LeanFmt.Basic\n\nnamespace Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n", \
    repr(f["formatted"])
PY

# --- RDF-LAYOUT: the canonical reflow is the sole, sound owner of trailing-horizontal-whitespace and
#     final-newline normalization. `ruff-11c` retired the trailing-whitespace rule and the final
#     newline) as rules and folded the normalization into `LeanFmt.Printer`, mirroring `ruff format`.
#     Three persistent regressions pin what that ownership means. ---

# 1. No rule selected: the reflow trims interior AND final-line trailing whitespace and adds exactly one
#    final newline. The change is pure layout, so `format` carries no findings; `check` (which runs
#    selected rules, never layout) reports the very same file clean.
printf 'module\n\ndef alpha : Nat := 1   \n\ndef beta : Nat := 2   ' >"$nosel_fixture"
run_expect 1 "$work/nosel-format.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.rdf-layout-nosel.lean
python3 - "$work/nosel-format.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["mode"] == "format" and r["changed"] == 1 and r["findings"] == 0, r
f, = r["files"]
assert f["status"] == "would-format", f
assert f["findings"] == [], f  # the reflow, not a rule, made the change
assert f["formatted"] == "module\n\ndef alpha : Nat := 1\n\ndef beta : Nat := 2\n", repr(f["formatted"])
PY
run_expect 0 "$work/nosel-check.json" "$application" check --root . --json --no-cache \
  tests/modes/.rdf-layout-nosel.lean
python3 - "$work/nosel-check.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["changed"] == 0, r  # layout is not a rule, so check does not move
f, = r["files"]
assert f["status"] == "clean" and f["findings"] == [], f
PY

# 2. In-string trailing whitespace is token content, not inter-token trivia, so the trim is sound by
#    construction: the string value survives byte-for-byte and no rule reports it. `format` adds the
#    missing final newline as layout; `fix` — which since RDF-IMPL applies rule fixes, not layout — is a
#    clean no-op on this finding-free file and adds no newline, leaving every byte exactly as written.
#    This is the case the retired trailing-whitespace rule corrupted (it edited the string's bytes);
#    it now cannot recur.
printf 'module\n\ndef stringWsValue : String := "alpha   \n  beta"' >"$string_fixture"
run_expect 1 "$work/string-format.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.rdf-layout-string.lean
python3 - "$work/string-format.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["findings"] == [], f
assert f["formatted"] == 'module\n\ndef stringWsValue : String := "alpha   \n  beta"\n', \
    repr(f["formatted"])
PY
run_expect 0 "$work/string-fix.json" "$application" fix --root . --json --no-cache \
  tests/modes/.rdf-layout-string.lean
python3 - "$work/string-fix.json" "$string_fixture" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0, r          # no finding, and layout is not fix's job
f, = r["files"]
assert f["status"] == "clean", f
data = open(sys.argv[2], "rb").read()
# Byte-identical to the input: the string interior "alpha   " is intact and `fix` added no final newline.
assert data == b'module\n\ndef stringWsValue : String := "alpha   \n  beta"', repr(data)
PY

# 3. A verbatim tail after a terminal `#exit` is emitted byte-for-byte EXCEPT its own trailing
#    horizontal whitespace, which is layout the reflow lays down: it is trimmed and the file gains a
#    final newline. (`#exit` ends the command stream, so everything after it is uninterpreted tail.)
printf 'module\n\ndef x : Nat := 1\n#exit\ntrailing garbage   ' >"$tail_fixture"
run_expect 1 "$work/tail-format.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.rdf-layout-tail.lean
python3 - "$work/tail-format.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["formatted"] == "module\n\ndef x : Nat := 1\n#exit\ntrailing garbage\n", repr(f["formatted"])
PY

# --- RDF-FINAL / FIP-IMPL: composition confluence with `format` WRITING. The two decoupled operations
#     touch disjoint concerns — `fix` rewrites rule-defect bytes at original coordinates and never
#     reflows; `format` reflows layout and never applies a fix — so composing them in either order
#     reaches the SAME fixed point on disk. Since `ruff-11d`, `format` publishes in place, so both orders
#     are materialized by the tools themselves (no captured-preview step) and the two files are compared.
#     `fix` and `format` are both writers now; each still owns only its half. ---
canonical='module\n\nimport LeanFmt.Basic\n\nnamespace Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n'
source='module\n\nimport LeanFmt.Basic\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef mixedValue : Nat := 1\n\nend Alpha\n'

# Order A — `fix` then `format`: fix dedups at original coords (layout still dirty), then format reflows
# and writes it. Both steps write in place; the file on disk is the converged form.
printf "$source" >"$comp_a_fixture"
run_expect 0 "$work/comp-a-fix.json" "$application" fix --root . --no-cache tests/modes/.rdf-final-comp-a.lean
run_expect 0 "$work/comp-a-format.json" "$application" format --root . --json --no-cache \
  tests/modes/.rdf-final-comp-a.lean
python3 - "$work/comp-a-format.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "formatted" and f["written"] is True, ("order A format did not write", f)
PY

# Order B — `format` then `fix`: format reflows (both imports kept) and writes, then fix dedups that
# reflowed file at its own coords and writes. No captured-preview step — `format` materializes itself.
printf "$source" >"$comp_b_fixture"
run_expect 0 "$work/comp-b-format1.json" "$application" format --root . --json --no-cache \
  tests/modes/.rdf-final-comp-b.lean
python3 - "$work/comp-b-format1.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "formatted" and f["written"] is True, ("order B format did not write", f)
PY
run_expect 0 "$work/comp-b-fix.json" "$application" fix --root . --no-cache tests/modes/.rdf-final-comp-b.lean

# Both orders converge to the identical canonical bytes ON DISK. Compare each written file against the
# expected canonical bytes and against each other.
CANON="$canonical" python3 - "$comp_a_fixture" "$comp_b_fixture" <<'PY'
import os, sys
canonical = os.environ["CANON"].encode().decode("unicode_escape")
a_bytes = open(sys.argv[1]).read()
b_bytes = open(sys.argv[2]).read()
assert a_bytes == canonical, ("order A (fix;format) diverged", repr(a_bytes))
assert b_bytes == canonical, ("order B (format;fix) diverged", repr(b_bytes))
assert a_bytes == b_bytes, "the two composition orders are not confluent"
PY
# Each converged file is a fixed point of BOTH operations: a fresh `format` is idempotent (clean,
# nothing to reflow, nothing written) and a fresh `fix` is idempotent (nothing to apply).
run_expect 0 "$work/comp-b-format2.json" "$application" format --root . --json --no-cache \
  tests/modes/.rdf-final-comp-b.lean
python3 - "$work/comp-b-format2.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "clean" and f["written"] is False and f["formatted"] is None, \
    ("order B not a format fixed point", f)
PY
# A post-composition `check` of each converged file is clean — no fix remains either way.
run_expect 0 "$work/comp-a-check.json" "$application" check --root . --json --no-cache \
  tests/modes/.rdf-final-comp-a.lean
run_expect 0 "$work/comp-b-check.json" "$application" check --root . --json --no-cache \
  tests/modes/.rdf-final-comp-b.lean
python3 - "$work/comp-a-check.json" "$work/comp-b-check.json" <<'PY'
import json, sys
for p in sys.argv[1:3]:
    f, = json.load(open(p))["files"]
    assert f["status"] == "clean" and f["findings"] == [], (p, f)
PY

# =================================================================================================
# FIP-FINAL (`ruff-11d`): adversarial acceptance of the in-place default. `format` writes exactly the
# canonical bytes and only those; it is idempotent; `--check` never writes; a broken file is never
# written; CRLF and in-string bytes round-trip on write; the stale-source guard holds for format's
# write as for fix's; no-arg selection writes exactly the included set. `check`/`diff` still never
# write (asserted below and throughout the suite).
# =================================================================================================

# 1+2. Exact bytes + idempotence. A layout-dirty, otherwise lint-clean file: `format` writes EXACTLY the
#      canonical bytes (byte-compared), no rule fix appears, and a second `format` writes nothing.
printf 'module\n\nnamespace     Gamma\n\ndef exactValue : Nat := 1\n\nend Gamma\n' >"$fin_exact_fixture"
canonical_exact='module\n\nnamespace Gamma\n\ndef exactValue : Nat := 1\n\nend Gamma\n'
run_expect 0 "$work/fin-exact.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
CANON="$canonical_exact" python3 - "$work/fin-exact.json" "$fin_exact_fixture" <<'PY'
import json, os, sys
canonical = os.environ["CANON"].encode().decode("unicode_escape")
r = json.load(open(sys.argv[1]))
f, = r["files"]
assert f["status"] == "formatted" and f["written"] is True and r["written"] == 1, f
assert f["findings"] == [], ("a rule fix appeared on a format write", f)  # layout only, no fix
data = open(sys.argv[2]).read()
assert data == canonical, ("format wrote non-canonical bytes", repr(data))
PY
run_expect 0 "$work/fin-exact-2.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
CANON="$canonical_exact" python3 - "$work/fin-exact-2.json" "$fin_exact_fixture" <<'PY'
import json, os, sys
canonical = os.environ["CANON"].encode().decode("unicode_escape")
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "clean" and f["written"] is False, ("format is not idempotent", f)
assert open(sys.argv[2]).read() == canonical, "a second format changed bytes"
PY

# 3. `--check` never writes. On the dirty fixture it exits non-zero and leaves the file byte-identical;
#    plain `format` then writes it; on the now-clean file `--check` exits 0.
printf 'module\n\nnamespace     Gamma\n\ndef exactValue : Nat := 1\n\nend Gamma\n' >"$fin_exact_fixture"
metadata "$fin_exact_fixture" >"$work/fin-check.before"
run_expect 1 "$work/fin-check.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
metadata "$fin_exact_fixture" >"$work/fin-check.after"
cmp "$work/fin-check.before" "$work/fin-check.after" # --check wrote nothing at all
python3 - "$work/fin-check.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "would-format" and f["written"] is False, f
PY
run_expect 0 "$work/fin-check-write.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
run_expect 0 "$work/fin-check-clean.json" "$application" format --check --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
python3 - "$work/fin-check-clean.json" <<'PY'
import json, sys
f, = json.load(open(sys.argv[1]))["files"]
assert f["status"] == "clean", ("--check on a clean file must be clean/exit 0", f)
PY

# 4. A broken file is never written and orphans no temp. An elaboration error (`Nat := true`) makes the
#    file `broken`; it is byte-identical afterward and no `.lean-fmt-tmp-*` survives beside it — the
#    validation guard holds for `format` exactly as for `fix`.
printf 'module\n\ndef bad : Nat := true\n' >"$fin_broken_fixture"
metadata "$fin_broken_fixture" >"$work/fin-broken.before"
run_expect 1 "$work/fin-broken.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-broken.lean
metadata "$fin_broken_fixture" >"$work/fin-broken.after"
cmp "$work/fin-broken.before" "$work/fin-broken.after"
python3 - "$work/fin-broken.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f, = r["files"]
assert f["status"] == "broken" and r["broken"] == 1 and r["written"] == 0, f
PY
if compgen -G "$repo_root/tests/modes/.fip-final-broken.lean.lean-fmt-tmp-*" >/dev/null; then
  echo 'a broken format orphaned a temp file at the target' >&2
  exit 1
fi

# 5a. CRLF write round-trip. A CRLF file formatted in place keeps CRLF endings (denormalized on write):
#     no bare LF appears, and the layout is canonical.
printf 'module\r\n\r\nnamespace     Delta\r\n\r\ndef crlfValue : Nat := 1\r\n\r\nend Delta\r\n' \
  >"$fin_crlf_fixture"
run_expect 0 "$work/fin-crlf.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-crlf.lean
python3 - "$fin_crlf_fixture" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert b"\r\n" in data, "format stripped CRLF line endings on write"
assert b"\n" not in data.replace(b"\r\n", b""), "format left a bare LF in a CRLF file"
assert b"namespace Delta\r\n" in data and b"namespace     Delta" not in data, \
    ("layout not canonicalized on a CRLF write", data)
PY

# 5b. In-string trailing whitespace round-trip. `format` adds the missing final newline (layout) but the
#     string value "alpha   " survives byte-for-byte — the trivia-only trim cannot reach token content,
#     so the write cannot corrupt a string the way the retired trailing-whitespace rule once did.
printf 'module\n\ndef stringVal : String := "alpha   \n  beta"' >"$fin_string_fixture"
run_expect 0 "$work/fin-string.json" "$application" format --root . --json --no-cache \
  tests/modes/.fip-final-string.lean
python3 - "$fin_string_fixture" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert data == b'module\n\ndef stringVal : String := "alpha   \n  beta"\n', repr(data)
PY

# 6. Stale-source guard on format's write. A concurrent change between analysis and rename is caught by
#    `publishAtomic` exactly as for `fix`: the write is refused, the file is `rejected`, nothing the
#    formatter produced is published.
printf 'module\n\nnamespace     Epsilon\n\ndef staleValue : Nat := 1\n\nend Epsilon\n' >"$fin_stale_fixture"
cat >"$work/fin-stale-hook" <<'EOF'
#!/bin/sh
printf '\n-- concurrent change\n' >>"$1"
EOF
chmod +x "$work/fin-stale-hook"
run_expect 1 "$work/fin-stale.json" env LEAN_FMT_TEST_BEFORE_WRITE="$work/fin-stale-hook" \
  "$application" format --root . --json --no-cache tests/modes/.fip-final-stale.lean
grep -q 'source changed after analysis' "$work/fin-stale.json"
python3 - "$work/fin-stale.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["rejected"] == 1 and r["written"] == 0, r
PY

# 7. No-arg project-wide write. With `include` scoping selection to exactly one file, `format` with NO
#    file arguments writes that file and leaves the excluded sibling byte-identical: no-arg selection
#    (`Project.load` discovery filtered by `config.includesPath`) chooses the set, and the write default
#    acts on exactly it — no `.lake` or out-of-set file is touched.
printf 'module\n\nnamespace     Incl\n\ndef inclValue : Nat := 1\n\nend Incl\n' >"$fin_incl_fixture"
printf 'module\n\nnamespace     Excl\n\ndef exclValue : Nat := 1\n\nend Excl\n' >"$fin_excl_fixture"
cat >"$work/fin-noarg.toml" <<'EOF'
select = ["default"]
include = ["tests/modes/.fip-final-incl.lean"]
EOF
metadata "$fin_excl_fixture" >"$work/fin-excl.before"
run_expect 0 "$work/fin-noarg.json" "$application" format --root . --json --no-cache \
  --config "$work/fin-noarg.toml"
python3 - "$work/fin-noarg.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
paths = [f["path"] for f in r["files"]]
assert paths == ["tests/modes/.fip-final-incl.lean"], ("no-arg selection is not the included set", paths)
f, = r["files"]
assert f["status"] == "formatted" and f["written"] is True, f
PY
python3 - "$fin_incl_fixture" <<'PY'
import sys
assert open(sys.argv[1]).read() == "module\n\nnamespace Incl\n\ndef inclValue : Nat := 1\n\nend Incl\n"
PY
metadata "$fin_excl_fixture" >"$work/fin-excl.after"
cmp "$work/fin-excl.before" "$work/fin-excl.after" # the excluded sibling was never touched

# 8. `check`/`diff` still never write — on a fresh dirty fixture, both leave it byte-identical.
printf 'module\n\nnamespace     Zeta\n\ndef neverValue : Nat := 1\n\nend Zeta\n' >"$fin_exact_fixture"
metadata "$fin_exact_fixture" >"$work/fin-nw.before"
run_expect 0 "$work/fin-nw-check.json" "$application" check --root . --json --no-cache \
  tests/modes/.fip-final-exact.lean
run_expect 1 "$work/fin-nw-diff.txt" "$application" diff --root . --no-cache \
  tests/modes/.fip-final-exact.lean
metadata "$fin_exact_fixture" >"$work/fin-nw.after"
cmp "$work/fin-nw.before" "$work/fin-nw.after" # check and diff wrote nothing

# 9. RCD-IMPL (`ruff-13`) gate 1: a path inside `.lake` is refused by every mode under every
#    configuration. `.lake` holds Lake's build outputs and vendored dependency sources; before this
#    stack an explicit `.lake/...` argument was accepted and *written*
#    (`docs/projects/ruff-13-config-discovery/evidence/01-discovery-baseline.md` §3). The floor is
#    absolute: no `--config`, no `force-exclude` setting, and no explicit argument lifts it, so each
#    setting is asserted separately rather than once with the default.
printf 'module\n\nnamespace     Floor\n\ndef floorValue : Nat := 1\n\nend Floor\n' >"$rcd_floor_fixture"
cat >"$work/rcd-force-on.toml" <<'EOF'
force-exclude = true
EOF
cat >"$work/rcd-force-off.toml" <<'EOF'
force-exclude = false
EOF
metadata "$rcd_floor_fixture" >"$work/rcd-floor.before"
for mode in format fix; do
  run_expect 2 "$work/rcd-floor-$mode.txt" "$application" "$mode" --root . --no-cache \
    .lake/build/.rcd-impl-floor.lean
  grep -q 'inside the Lake build directory' "$work/rcd-floor-$mode.txt.stderr"
  for setting in on off; do
    run_expect 2 "$work/rcd-floor-$mode-$setting.txt" "$application" "$mode" --root . --no-cache \
      --config "$work/rcd-force-$setting.toml" .lake/build/.rcd-impl-floor.lean
    grep -q 'inside the Lake build directory' "$work/rcd-floor-$mode-$setting.txt.stderr"
  done
done
metadata "$rcd_floor_fixture" >"$work/rcd-floor.after"
cmp "$work/rcd-floor.before" "$work/rcd-floor.after" # nothing inside .lake was written
"$application" config show .lake/build/.rcd-impl-floor.lean --root . --json >"$work/rcd-floor.json"
python3 - "$work/rcd-floor.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["selected"] is False and r["gate"] == 1, r
PY

# 10. Gates 2-4 and `force-exclude`: an *explicit* path bypasses configured exclusion by default (the
#     user named the file), and `force-exclude = true` is exactly the setting that makes exclusion
#     apply to explicit paths too. Same file, same argument, same mode - only the setting differs, so
#     a difference in bytes written is attributable to nothing else.
printf 'module\n\nnamespace     Excluded\n\ndef excludedValue : Nat := 1\n\nend Excluded\n' \
  >"$rcd_excl_fixture"
cat >"$work/rcd-excl.toml" <<'EOF'
exclude = ["tests/modes/.rcd-impl-excluded.lean"]
EOF
cat >"$work/rcd-excl-forced.toml" <<'EOF'
exclude = ["tests/modes/.rcd-impl-excluded.lean"]
force-exclude = true
EOF
metadata "$rcd_excl_fixture" >"$work/rcd-excl.before"
run_expect 0 "$work/rcd-excl-forced.json" "$application" format --root . --json --no-cache \
  --config "$work/rcd-excl-forced.toml" tests/modes/.rcd-impl-excluded.lean
python3 - "$work/rcd-excl-forced.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["files"] == [], ("force-exclude did not remove an explicitly named excluded path", r)
assert r["written"] == 0, r
PY
metadata "$rcd_excl_fixture" >"$work/rcd-excl.forced-after"
cmp "$work/rcd-excl.before" "$work/rcd-excl.forced-after" # force-exclude withheld the write
run_expect 0 "$work/rcd-excl-plain.json" "$application" format --root . --json --no-cache \
  --config "$work/rcd-excl.toml" tests/modes/.rcd-impl-excluded.lean
python3 - "$work/rcd-excl-plain.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
f, = r["files"]
assert f["status"] == "formatted" and f["written"] is True, \
    ("an explicit path was not written without force-exclude", r)
PY
python3 - "$rcd_excl_fixture" <<'PY'
import sys
assert open(sys.argv[1]).read() == \
    "module\n\nnamespace Excluded\n\ndef excludedValue : Nat := 1\n\nend Excluded\n"
PY

# 11. `[format] line-width` participates in the result-cache identity and `[lint]` does not
#     (`notes/01-discovery.md` §9.2), asserted behaviorally with the cache **on**: the width-100 run
#     is stored, and the width-20 run that follows must not be served from it. A hit counter would
#     prove less - this asserts the wrong answer cannot be returned, which is the property at stake.
rm -rf "$cache_root"
# A layout-clean file at width 100 whose canonical layout at width 20 differs: without a
# width-sensitive body, both runs are `clean` and the assertion below passes whether or not the
# cache respects the width.
printf 'module\n\nnamespace Width\n\ndef widthValue : Nat := 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10\n\nend Width\n' \
  >"$rcd_excl_fixture"
cat >"$work/rcd-w100.toml" <<'EOF'
[format]
line-width = 100
EOF
cat >"$work/rcd-w20.toml" <<'EOF'
[format]
line-width = 20
EOF
cat >"$work/rcd-w100-lint.toml" <<'EOF'
[format]
line-width = 100
[lint]
select = ["security"]
EOF
run_expect 0 "$work/rcd-w100.json" "$application" format --check --root . --json \
  --config "$work/rcd-w100.toml" tests/modes/.rcd-impl-excluded.lean
run_expect 0 "$work/rcd-w100b.json" "$application" format --check --root . --json \
  --config "$work/rcd-w100.toml" tests/modes/.rcd-impl-excluded.lean
cmp "$work/rcd-w100.json" "$work/rcd-w100b.json" # a warm identical run is byte-identical
run_expect 0 "$work/rcd-w100-lint.json" "$application" format --check --root . --json \
  --config "$work/rcd-w100-lint.toml" tests/modes/.rcd-impl-excluded.lean
python3 - "$work/rcd-w100.json" "$work/rcd-w100-lint.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
assert [f["status"] for f in a["files"]] == [f["status"] for f in b["files"]], (a, b)
PY
run_expect 1 "$work/rcd-w20.json" "$application" format --check --root . --json \
  --config "$work/rcd-w20.toml" tests/modes/.rcd-impl-excluded.lean
python3 - "$work/rcd-w100.json" "$work/rcd-w20.json" <<'PY'
import json, sys
wide, narrow = (json.load(open(p)) for p in sys.argv[1:3])
assert [f["status"] for f in wide["files"]] == ["clean"], wide
assert [f["status"] for f in narrow["files"]] == ["would-format"], \
    ("a width-100 cache entry was served to a width-20 run", narrow)
PY
rm -rf "$cache_root"

# 12. `config show` is read-only and deterministic: two invocations agree byte for byte, the source is
#     untouched, and the provenance names the file and line a setting actually came from.
metadata "$rcd_excl_fixture" >"$work/rcd-show.before"
"$application" config show tests/modes/.rcd-impl-excluded.lean --root . --json \
  --config "$work/rcd-w20.toml" >"$work/rcd-show-a.json"
"$application" config show tests/modes/.rcd-impl-excluded.lean --root . --json \
  --config "$work/rcd-w20.toml" >"$work/rcd-show-b.json"
cmp "$work/rcd-show-a.json" "$work/rcd-show-b.json"
metadata "$rcd_excl_fixture" >"$work/rcd-show.after"
cmp "$work/rcd-show.before" "$work/rcd-show.after" # introspection wrote nothing
python3 - "$work/rcd-show-a.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
settings = {s["key"]: s for s in r["settings"]}
width = settings["format.line-width"]
assert width["value"] == "20", width
assert width["origin"].endswith("rcd-w20.toml:2"), width
assert settings["include"]["origin"] == "default", settings["include"]
assert r["selected"] is True and r["gate"] == 0, r
PY

printf 'lean-fmt product mode integration tests passed\n'
