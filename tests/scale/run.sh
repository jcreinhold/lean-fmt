#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

project="$work/project"
mkdir -p "$project/Nested" "$project/scripts"
cp lean-toolchain "$project/lean-toolchain"
cat >"$project/lakefile.lean" <<'LEAN'
import Lake

open Lake DSL

package "scale-fixture"

lean_lib Demo where
  roots := #[`Demo]
  globs := #[Glob.one `Demo]
LEAN
cat >"$project/Demo.lean" <<'LEAN'
module

def demo : Nat := 1
LEAN
cat >"$project/scripts/Standalone.lean" <<'LEAN'
module

#check Nat
LEAN
cat >"$project/Nested/lakefile.lean" <<'LEAN'
import Lake

open Lake DSL

package "nested"
LEAN

LEAN_NUM_THREADS=1 lake -d "$project" build Demo

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

run_expect 0 "$work/cold.json" "$application" check --root "$project" --json
python3 - "$work/cold.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
paths = [f["path"] for f in r["files"]]
assert paths == sorted(paths) == [
    "Demo.lean",
    "Nested/lakefile.lean",
    "lakefile.lean",
    "scripts/Standalone.lean",
]
assert all(f["status"] == "clean" for f in r["files"])
assert not r["infrastructureFailures"]
PY

# Every semantic result, including standalone and Lake configuration sources, is cacheable. An
# all-hit run needs neither ordinary module evidence nor an exact frontend child.
run_expect 0 "$work/warm.json" env LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" check --root "$project" --json
cmp "$work/cold.json" "$work/warm.json"

# Source identity independently invalidates the hit and the stale ordinary module cannot authorize
# source-only findings. Other selected sources are retained rather than dropped with the failure.
cp -p "$project/Demo.lean" "$work/Demo.lean"
printf '\n-- stale\n' >>"$project/Demo.lean"
run_expect 2 "$work/stale.json" env LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 \
  LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" check --root "$project" --json
python3 - "$work/stale.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert len(r["files"]) == 4
assert [f["path"] for f in r["files"]] == sorted(f["path"] for f in r["files"])
failed = [f for f in r["files"] if f["status"] == "infrastructure-failure"]
assert [f["path"] for f in failed] == ["Demo.lean"]
PY
cp -p "$work/Demo.lean" "$project/Demo.lean"

printf 'lean-fmt complete-selection and module-evidence tests passed\n'
