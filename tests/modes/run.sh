#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
source_file="$repo_root/tests/check/Findings.lean"
layout_file="$repo_root/tests/check/Layout.lean"
artifact_root="$repo_root/.lake/build/lean-fmt-artifacts"

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
  rm -rf "$cache_root" "$work"
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

# Every preview mode consumes the same result, returns deterministic output, and leaves source
# bytes, mtimes, and permissions untouched.
metadata "$source_file" >"$work/source.before"
run_expect 1 "$work/check.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 1 "$work/format.json" "$application" format --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 1 "$work/diff.txt" "$application" diff --root . --no-cache \
  tests/check/Findings.lean
metadata "$source_file" >"$work/source.after-previews"
cmp "$work/source.before" "$work/source.after-previews"

python3 - "$work/check.json" "$work/format.json" "$work/diff.txt" <<'PY'
import json, sys
check = json.load(open(sys.argv[1]))
formatted = json.load(open(sys.argv[2]))
diff = open(sys.argv[3]).read()
assert check["mode"] == "check" and check["changed"] == 1 and check["written"] == 0
assert formatted["files"][0]["formatted"] == "module\n\ndef findingValue : Nat := 1\n"
# `RFP-IMPL` rewrote `unifiedDiff` over `Lean.Diff.diff`. This golden used to pin the naive output,
# which reprinted all three lines as `-` and then all three as `+` to change one of them.
#
# Assembled from explicit pieces rather than written as a literal block: three of these lines end in
# whitespace that is the assertion (the ' ' context marker on the blank line, and the two spaces that
# are FMT001's actual violation), and a literal block would put trailing whitespace in this file for
# `git diff --check` to reject and any editor to strip on save.
#
# The ' ' context lines are the whole point. They are what a diff has and a whole-file rewrite does
# not, so reverting to one fails here.
expected = "".join(line + "\n" for line in [
    "--- a/tests/check/Findings.lean",
    "+++ b/tests/check/Findings.lean",
    "@@ -1,3 +1,3 @@",
    " module",
    " ",
    "-def findingValue : Nat := 1" + "  ",
    "+def findingValue : Nat := 1",
    "mode=diff files=1 findings=1 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 "
    "infrastructure_failures=0",
])
assert diff == expected, repr(diff)
PY

# `RFP-IMPL`: **`format` formats.** This was `RFP-SPEC`'s characterization of the opposite — it
# asserted exit 0 and `clean`, pinning a `format` that previewed lint fixes and never looked at
# layout. Wiring the printer in flips it, which is what that test existed to force.
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
run_expect 1 "$work/layout-format.json" "$application" format --root . --json --no-cache \
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
grep -q 'namespace     Alpha' tests/check/Layout.lean \
  || { echo 'fixture lost its non-canonical spacing; the check above proves nothing' >&2; exit 1; }

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
# showing nothing, for the single edit `FMT002` exists to make. `DiffLine` carries the terminator into
# the compared element to keep them unequal, and this test is why that type is not over-engineering.
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
    "mode=diff files=1 findings=1 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 "
    "infrastructure_failures=0",
])
assert diff == expected, repr(diff)
PY
cp -p "$work/Layout.lean" "$layout_file"

# Artifact, exact fallback, and semantic-cache hit project to identical formatted output. The hit
# remains usable under a different rule projection without invoking an analyzer.
run_expect 1 "$work/format-artifact.json" "$application" format --root . --json \
  tests/check/Findings.lean
run_expect 1 "$work/format-hit.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" format --root . --json \
  tests/check/Findings.lean
cmp "$work/format-artifact.json" "$work/format-hit.json"
run_expect 1 "$work/format-fallback.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  "$application" format --root . --json --no-cache tests/check/Findings.lean
cmp "$work/format-artifact.json" "$work/format-fallback.json"

# A `check`-populated entry is a **miss** for a rendering mode, not an under-populated hit. `check`
# takes the source-only shortcut and stores no canonical text, so serving its entry to `format` would
# put `prepareFile` on the `renderCanonical = true` but `canonical? = none` path — where it silently
# bases the patch on the file's own bytes and consults no layout. That is `RFP-SPEC`'s "format does
# not format", reintroduced through the cache and invisible: the report says `clean`, exit 0, which is
# indistinguishable from a file that needs nothing. `cacheHitServes` is the only thing standing there,
# so this pins it. The entry `check` leaves behind is real; only its usefulness to `format` is not.
rm -rf "$cache_root"
run_expect 0 "$work/seed-check.json" "$application" check --root . --json tests/check/Layout.lean
run_expect 1 "$work/after-check-format.json" "$application" format --root . --json \
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
select = ["all"]
[per-file-ignores]
"tests/check/Findings.lean" = ["FMT001"]
EOF
run_expect 0 "$work/projected-hit.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  --config "$work/per-file.toml" tests/check/Findings.lean
python3 - "$work/projected-hit.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["findings"] == r["changed"] == 0 and r["files"][0]["status"] == "clean"
PY

# Applicability travels on the finding's fix. `Findings.lean`'s one FMT001 is safe by the byte-trivia
# argument (`notes/01-model.md` §1), so `check` reports it with an edit and nothing is withheld.
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

# `extend-unsafe-fixes` demotes FMT001 as a plan projection no rule reads (`notes/01-model.md` §2).
# The reported finding now says `unsafe`; default `fix` withholds it with no write; `--unsafe-fixes`
# opts in and applies it. The one admission rule governs preview and write alike, so `check` above and
# `fix` here agree on what would apply.
cat >"$work/demote.toml" <<'EOF'
select = ["all"]
extend-unsafe-fixes = ["FMT001"]
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
extend-safe-fixes = ["FMT001"]
extend-unsafe-fixes = ["FMT001"]
EOF
run_expect 2 "$work/both-lists.out" "$application" check --root . --json --no-cache \
  --config "$work/both-lists.toml" tests/check/Findings.lean
grep -q 'both extend-safe-fixes and extend-unsafe-fixes' "$work/both-lists.out.stderr"

# Config path filtering, layered selector precedence, unknown-key rejection, and stderr-only
# statistics are product behavior rather than execution strategy.
cat >"$work/include.toml" <<'EOF'
include = ["tests/check/Clean.lean"]
select = ["all"]
EOF
run_expect 0 "$work/include.json" "$application" check --root . --json --no-cache \
  --config "$work/include.toml"
python3 - "$work/include.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert [f["path"] for f in r["files"]] == ["tests/check/Clean.lean"]
PY

cat >"$work/ignore.toml" <<'EOF'
select = ["all"]
ignore = ["FMT001"]
EOF
run_expect 0 "$work/config-ignore.json" "$application" check --root . --json --no-cache \
  --config "$work/ignore.toml" tests/check/Findings.lean
run_expect 1 "$work/cli-select.json" "$application" check --root . --json --no-cache \
  --config "$work/ignore.toml" --select FMT001 tests/check/Findings.lean

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
assert [r["code"] for r in rules] == ["FMT001", "FMT002"]
assert all(r["fixable"] and r["category"] == "text" for r in rules)
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

if [[ -d "$artifact_root" ]]; then
  tree_metadata "$artifact_root" >"$work/artifacts.before"
else
  : >"$work/artifacts.before"
fi
run_expect 0 "$work/status-1.json" "$application" compiler status --root . --json
run_expect 0 "$work/status-2.json" "$application" compiler status --root . --json
cmp "$work/status-1.json" "$work/status-2.json"
if [[ -d "$artifact_root" ]]; then
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
assert r["ready"] >= 2 and r["ready"] + r["missing"] + r["unbuilt"] == len(paths)
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

printf 'lean-fmt product mode integration tests passed\n'
