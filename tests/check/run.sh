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
assert fallback == integrated
assert any(c["kind"] == "commandEmit_local_command" for c in fallback["commands"])
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

snapshot_metadata "${sources[@]}" >"$work/after"
cmp "$work/before" "$work/after"

printf 'lean-fmt check integration tests passed\n'
