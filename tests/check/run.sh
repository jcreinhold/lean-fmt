#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
trap 'rm -rf "$work" "$cache_root"' EXIT

cd "$repo_root"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt LocalSyntax:leanFmtArtifact Findings:leanFmtArtifact
application=$(lake -q query lean-fmt --text)

snapshot_metadata() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
for name in sys.argv[1:]:
    data = open(name, "rb").read()
    print(name, hashlib.sha256(data).hexdigest(), os.stat(name).st_mtime_ns)
PY
}

sources=(
  tests/compiler/LocalSyntax.lean
  tests/check/Clean.lean
  tests/check/Findings.lean
  tests/check/MalformedHeader.lean
  tests/check/UnresolvedImport.lean
  tests/check/Security.lean
)
snapshot_metadata "${sources[@]}" >"$work/before"

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

run_expect 0 "$work/help" "$application" check --help
run_expect 0 "$work/clean.json" "$application" check --root . --json --no-cache \
  tests/check/Clean.lean
run_expect 1 "$work/artifact-findings.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 1 "$work/fallback-findings.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json --no-cache tests/check/Findings.lean
cmp "$work/artifact-findings.json" "$work/fallback-findings.json"

# `check` and `format` must never disagree about one unchanged file — the invariant
# `notes/01-rule-facts.md` §2 caught the product violating. The trigger it used is gone (there is no
# `leanFmt.trailingWhitespace` to turn off any more), so this asserts the invariant itself rather than
# replaying a defect that can no longer be spelled.
#
# It is not the `cmp` above: that compares the artifact path against the exact-frontend fallback, and
# both of those report. This compares the two paths that actually diverged. `check` here takes the
# source-only shortcut in `availableAnalysis` — every rule is source-tier, the mode renders nothing,
# and module evidence is current — while `format` takes the artifact path for the projection it must
# print. Only the findings are comparable; mode, status, and rendered text are meant to differ.
run_expect 1 "$work/agreement-check.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
run_expect 1 "$work/agreement-format.json" "$application" format --root . --json --no-cache \
  tests/check/Findings.lean
python3 - "$work/agreement-check.json" "$work/agreement-format.json" <<'PY'
import json, sys
def findings(path):
    report = json.load(open(path))
    file, = report["files"]
    return [(f["code"], f["range"]["start"], f["range"]["stop"], f["message"]) for f in file["findings"]]
checked, formatted = findings(sys.argv[1]), findings(sys.argv[2])
assert checked, "the agreement fixture produced no findings, so agreement is vacuous"
assert checked == formatted, f"check and format disagree: {checked} != {formatted}"
PY

run_expect 0 "$work/artifact-custom.json" "$application" check --root . --json --no-cache \
  tests/compiler/LocalSyntax.lean
run_expect 0 "$work/fallback-custom.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json --no-cache tests/compiler/LocalSyntax.lean
cmp "$work/artifact-custom.json" "$work/fallback-custom.json"

LEAN_NUM_THREADS=1 lake setup-file tests/compiler/LocalSyntax.lean >"$work/local.setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/local.setup.json" tests/compiler/LocalSyntax.lean \
  tests/compiler/LocalSyntax.lean 8589934592 >"$work/exact-envelope.json"
python3 - "$work/exact-envelope.json" \
  .lake/build/lean-fmt-artifacts/LocalSyntax.json <<'PY'
import json, sys
fallback = json.load(open(sys.argv[1]))["artifact"]
integrated = json.load(open(sys.argv[2]))
# The exact frontend and the compiler plugin must project one module identically. They reach the
# same producer with the same arguments, so any difference here is a real divergence, not drift.
assert fallback == integrated
source = fallback["source"]
# File-local `syntax` reaches the kind table, which only an elaborated environment can parse.
assert "commandEmit_local_command" in source["kinds"]
# The projection covers the whole file: header, then a token stream tiling up to the terminal.
assert source["headerStop"] > 0
assert source["terminalStop"] == source["normalizedBytes"]
assert source["tokens"], "the projection recorded no tokens"
PY

run_expect 1 "$work/broken.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json \
  --no-cache \
  tests/check/UnresolvedImport.lean tests/check/MalformedHeader.lean
python3 - "$work/broken.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
paths = [f["path"] for f in r["files"]]
assert paths == sorted(paths) == [
    "tests/check/MalformedHeader.lean", "tests/check/UnresolvedImport.lean"]
text = "\n".join(d for f in r["files"] for d in f["diagnostics"])
assert "unexpected end of input" in text
assert "DefinitelyMissing" in text
assert r["broken"] == 2 and not r["infrastructureFailures"]
PY

run_expect 2 "$work/abort.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  --no-cache \
  tests/check/Findings.lean tests/check/Clean.lean
python3 - "$work/abort.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert [f["path"] for f in r["files"]] == [
    "tests/check/Clean.lean", "tests/check/Findings.lean"]
assert len(r["infrastructureFailures"]) == 2
PY

run_expect 2 "$work/memory.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_MAX_BYTES=1 "$application" check --root . --json \
  --no-cache \
  tests/check/Clean.lean
grep -q 'resource envelope exhausted' "$work/memory.json"

run_expect 1 "$work/repeated.json" "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
cmp "$work/artifact-findings.json" "$work/repeated.json"

# The result cache is semantic rather than strategy-based. A module-evidence entry and a fresh exact
# entry must be byte-identical, and a real hit must bypass the analyzer child.
rm -rf "$cache_root"
run_expect 1 "$work/cache-artifact.json" "$application" check --root . --json \
  tests/check/Findings.lean
cache_entry=$(find "$cache_root/results" -type f -name '*.json' -print)
test "$(printf '%s\n' "$cache_entry" | sed '/^$/d' | wc -l | tr -d ' ')" = 1
cp "$cache_entry" "$work/module-cache-entry.json"
run_expect 1 "$work/cache-hit.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
cmp "$work/cache-artifact.json" "$work/cache-hit.json"

rm -rf "$cache_root"
run_expect 1 "$work/cache-fallback.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json tests/check/Findings.lean
fallback_entry=$(find "$cache_root/results" -type f -name '*.json' -print)
cmp "$work/module-cache-entry.json" "$fallback_entry"
cmp "$work/cache-artifact.json" "$work/cache-fallback.json"

# Selection is a projection over one cached result, not a component of its identity. Two runs that
# differ only in `--select` must collide onto the same entry: the completion contract says selection
# "never selects worker, artifact, cache, or scheduling strategy", and this is the cache half of it.
# `LeanFmtTest.lean`'s `testMixedSelection` covers the other half (what a selection costs to obtain).
#
# The collision must be an entry collision, not a report collision — the reports differ, and are
# meant to. So this counts entries and makes a miss fatal for the second run: it must produce its
# answer from an entry a *differently selected* run wrote, or not at all.
#
# All three env vars are load-bearing and `LEAN_FMT_TEST_ANALYZER` alone is not enough. A plain
# `check` on a current module takes the source-only shortcut in `availableAnalysis` and never
# consults the analyzer or the cache, so a disabled analyzer would prove nothing — the run would
# pass without a hit and the test would be vacuous. Disabling module evidence is what forces the
# second run to need the cache; disabling the artifact closes the other way out.
rm -rf "$cache_root"
run_expect 1 "$work/select-all.json" "$application" check --root . --json \
  tests/check/Findings.lean
run_expect 0 "$work/select-fmt002.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" check --root . --json --select FMT002 tests/check/Findings.lean
test "$(find "$cache_root/results" -type f -name '*.json' | wc -l | tr -d ' ')" = 1
python3 - "$work/select-all.json" "$work/select-fmt002.json" <<'PY'
import json, sys
def codes(path):
    file, = json.load(open(path))["files"]
    return [f["code"] for f in file["findings"]]
every, selected = codes(sys.argv[0 + 1]), codes(sys.argv[2])
assert "FMT001" in every, f"the selection fixture lost its unselected rule: {every}"
assert selected == [], f"--select FMT002 reported something else: {selected}"
PY

# Corrupt committed entries are misses. A stray partial temporary file cannot shadow a valid entry.
printf '{"partial":' >"$fallback_entry"
run_expect 2 "$work/cache-corrupt.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
run_expect 1 "$work/cache-repaired.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  "$application" check --root . --json tests/check/Findings.lean
printf '{"partial":' >"$fallback_entry.tmp-interrupted"
run_expect 1 "$work/cache-partial.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
cmp "$work/cache-repaired.json" "$work/cache-partial.json"

# Exact source bytes and the trusted build-trace epoch independently invalidate a result.
cp -p tests/check/Findings.lean "$work/Findings.lean.backup"
printf '\n-- cache-source-invalidation\n' >>tests/check/Findings.lean
run_expect 2 "$work/cache-source-miss.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
cp -p "$work/Findings.lean.backup" tests/check/Findings.lean

trace=.lake/build/lib/lean/Findings.trace
cp -p "$trace" "$work/Findings.trace.backup"
printf '\n' >>"$trace"
run_expect 2 "$work/cache-trace-miss.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
cp -p "$work/Findings.trace.backup" "$trace"
mv "$trace" "$work/Findings.trace.missing"
run_expect 2 "$work/cache-untrusted-epoch.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
mv "$work/Findings.trace.missing" "$trace"

run_expect 1 "$work/cache-restored-identity.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json \
  tests/check/Findings.lean
cmp "$work/cache-repaired.json" "$work/cache-restored-identity.json"

# Compact artifact-cache traces can omit their source inputs. The aggregate cache epoch therefore
# hashes current source roots independently: changing another project source while leaving every
# build artifact and trace untouched must still force a miss.
project_source=LeanFmt/Cli.lean
cp -p "$project_source" "$work/Cli.lean.backup"
printf '\n-- cache-project-source-invalidation\n' >>"$project_source"
run_expect 2 "$work/cache-dependency-source-miss.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" check --root . --json tests/check/Findings.lean
cp -p "$work/Cli.lean.backup" "$project_source"
run_expect 1 "$work/cache-dependency-source-restored.json" env LEAN_FMT_DISABLE_ARTIFACT=1 \
  LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" check --root . --json tests/check/Findings.lean
cmp "$work/cache-repaired.json" "$work/cache-dependency-source-restored.json"

# Disabled cache performs neither reads nor writes.
run_expect 2 "$work/cache-disabled-read.json" env LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_TEST_ANALYZER=/usr/bin/false "$application" check --root . --json --no-cache \
  tests/check/Findings.lean
rm -rf "$cache_root"
run_expect 0 "$work/cache-disabled-write.json" "$application" check --root . --json --no-cache \
  tests/check/Clean.lean
test ! -e "$cache_root"

mkdir -p "$work/mismatch"
printf 'leanprover/lean4:v0.0.0\n' >"$work/mismatch/lean-toolchain"
run_expect 2 "$work/mismatch.out" "$application" check --root "$work/mismatch" --json
grep -q 'does not match this lean-fmt build' "$work/mismatch.out.stderr"

# A requested file that does not exist is named in the caller's own terms, not `realPath`'s
# partially-resolved buffer (which absolutizes the leading component and mangles the rest — unreadable
# when an unquoted shell variable passes a whole list as one argument under a non-splitting shell like
# zsh). The message matches its outside-root / not-a-Lean-source siblings.
run_expect 2 "$work/missing.out" "$application" check --root . --json tests/check/DoesNotExist.lean
grep -q 'selected file does not exist: tests/check/DoesNotExist.lean' "$work/missing.out.stderr"
# The same, exact, when a whole space-joined list arrives as one argument: the message quotes the
# entire string verbatim, so the shape of the mistake is legible rather than mangled.
run_expect 2 "$work/missing-list.out" "$application" check --root . --json \
  "tests/check/Clean.lean tests/check/Findings.lean"
grep -q 'selected file does not exist: tests/check/Clean.lean tests/check/Findings.lean' \
  "$work/missing-list.out.stderr"

# The source-security family end-to-end, on committed bytes rather than a runtime-crafted string.
# `Security.lean` carries a bidi mark (U+202E) inside a line comment and a NUL inside a string literal
# — the only two places a control or bidi byte reaches accepted source (bare occurrences are parse
# errors, `docs/projects/ruff-08-source-rules/notes/01-catalog.md` §2). The unit and property tests in
# `LeanFmtTest.lean` pin the scans; this pins the whole pipeline — read, normalize, source facts,
# rules, report — surfacing them byte-exact in normalized coordinates. The file is also in `sources`
# above, so the `cmp` at the end proves `check` reads a control-byte file without writing it.
run_expect 1 "$work/security.json" "$application" check --root . --json --no-cache \
  tests/check/Security.lean
python3 - "$work/security.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
file, = r["files"]
assert file["status"] == "findings", file["status"]
findings = [(f["code"], f["range"]["start"], f["range"]["stop"], f["message"]) for f in file["findings"]]
# Position-sorted (`findingOrder`): the comment mark precedes the string byte.
assert findings == [
    ("FMT004", 17, 20, "suspicious bidirectional control U+202E"),
    ("FMT003", 45, 46, "forbidden control byte U+0000"),
], findings
# Report-only: neither security finding carries a fix, and nothing is withheld as unsafe.
assert all("fix" not in f for f in file["findings"]), file["findings"]
assert r["withheldUnsafe"] == 0 and r["written"] == 0, r
PY

snapshot_metadata "${sources[@]}" >"$work/after"
cmp "$work/before" "$work/after"

printf 'lean-fmt check integration tests passed\n'
