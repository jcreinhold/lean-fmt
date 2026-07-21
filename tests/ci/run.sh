#!/usr/bin/env bash
set -euo pipefail

# The CI recipes in `docs/ci.md`, executed. A documented command nobody runs is a claim, not a
# recipe, and every claim in that document is about a *consuming* project: a git `require`, real
# commit history, and no warm state. This repository's own tree has none of those properties, so the
# suite builds a scratch consumer in a temporary directory and throws it away.
#
# `tests/downstream/run.sh` is deliberately not extended. It exercises the three consumption levels
# against a committed fixture with a *path* require and no git history at all; `--changed-since`
# needs a merge base and the cache invariant below needs a dependency binary under `.lake`. Different
# shape, different harness.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

ok() {
  printf '  ok   %s\n' "$1"
}

git_q() {
  git -c user.email=ci@lean-fmt.invalid -c user.name='lean-fmt ci' "$@"
}

# The pin is this working tree's HEAD, cloned over `file://`. A network clone would make the suite
# depend on what has been pushed rather than on what is being tested.
#
# Note what that excludes: `git archive` and a `file://` clone both read committed state, so
# uncommitted changes in this tree are NOT under test here. That is the right scope -- this suite
# answers "can a consumer install and run what is committed" -- but it means a green run says nothing
# about work in progress. Commit first, then run this.
head_sha=$(cd "$repo_root" && git rev-parse HEAD)

consumer="$work/consumer"
mkdir -p "$consumer/Demo"
cd "$consumer"
cp "$repo_root/lean-toolchain" .

cat > lakefile.lean <<EOF
import Lake
open Lake DSL

require «lean-fmt» from git "file://$repo_root" @ "$head_sha"

package demo where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]

@[default_target]
lean_lib Demo
EOF

cat > Demo.lean <<'EOF'
module

import Demo.Basic
EOF

cat > Demo/Basic.lean <<'EOF'
module

public def greeting : String := "hello"
EOF

cat > .gitignore <<'EOF'
.lake/
.lean-fmt-cache/
*.sarif
*.xml
EOF

git init -q .
git_q add -A
git_q commit -qm 'clean baseline'

lake update >/dev/null 2>&1 || fail 'lake update could not resolve the git dependency'
lake build >/dev/null 2>&1 || fail 'the consuming project did not build'

printf -- '--- Recipe 1: the minimal lake lint job ---\n'

# `leanprover/lean-action` probes `check-lint` before running `lake lint`, so a driver that does not
# announce itself is a job that silently lints nothing.
lake check-lint >/dev/null 2>&1 || fail 'lake check-lint does not see a configured driver'
ok 'lake check-lint reports a configured driver'

set +e
lake lint >"$work/lint-clean.log" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || fail "lake lint on a clean tree returned $status, expected 0"
ok 'lake lint exits 0 on a clean tree'

# Now give it something to find. FMT005 is a duplicate import: stable, safe-fixable, and it does not
# depend on line width or preview status.
cat > Demo/Dirty.lean <<'EOF'
module

import Demo.Basic
import Demo.Basic

public def other : String := greeting
EOF
printf 'import Demo.Dirty\n' >> Demo.lean
git_q add -A
git_q commit -qm 'add a module with a duplicate import'

set +e
lake lint >"$work/lint-dirty.log" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "lake lint with findings returned $status, expected 1"
grep -q 'FMT005 duplicate import' "$work/lint-dirty.log" ||
  fail 'lake lint did not carry the driver output through'
ok 'lake lint exits 1 and reports findings through the driver'

printf -- '--- Recipe 2: SARIF into code scanning ---\n'

# The recipe uploads unconditionally and guards on the file existing. Both halves are load-bearing
# and both are asserted here, because getting either wrong fails only in CI, months later.
set +e
lake exe lean-fmt check --root . --output-format sarif --output-file findings.sarif
status=$?
set -e
[ "$status" -eq 1 ] || fail "sarif run with findings returned $status, expected 1"
[ -s findings.sarif ] || fail 'a run with findings wrote no SARIF log'
ok 'a run with findings writes a SARIF log and exits 1'

# A clean run must still write a complete log. This is what resolves previously-reported alerts;
# if it ever stops being written, stale alerts stay open forever and nothing else would catch it.
set +e
lake exe lean-fmt check --root . --output-format sarif --output-file clean.sarif Demo/Basic.lean
status=$?
set -e
[ "$status" -eq 0 ] || fail "sarif run on a clean file returned $status, expected 0"
[ -s clean.sarif ] || fail 'a clean run wrote no SARIF log; upload-sarif would never clear old alerts'
results=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["runs"][0]["results"]))' clean.sarif)
[ "$results" = "0" ] || fail "a clean run reported $results SARIF results, expected 0"
ok 'a clean run writes a schema-shaped SARIF log with zero results'

# The `hashFiles(...) != ''` guard in the recipe exists because of exactly this.
rm -f absent.sarif
set +e
lake exe lean-fmt check --root . --output-format sarif --output-file absent.sarif NoSuchFile.lean \
  >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "a missing named file returned $status, expected 2"
[ ! -e absent.sarif ] ||
  fail 'an infrastructure failure left a SARIF file; the recipe guard assumes it does not'
ok 'an exit-2 run writes no SARIF file, which is why the recipe guards on its existence'

if command -v uv >/dev/null 2>&1; then
  if uv run --with check-jsonschema --quiet check-jsonschema \
      --schemafile "$repo_root/tests/reporting/sarif-schema-2.1.0.json" findings.sarif \
      >/dev/null 2>&1; then
    ok 'the consuming project SARIF log validates against the vendored 2.1.0 schema'
  else
    fail 'SARIF from a consuming project failed schema validation'
  fi
else
  printf '  skip the SARIF schema check needs uv\n'
fi

printf -- '--- Recipe 3: changed files on a pull request ---\n'

git_q checkout -q -b feature
cat > Demo/New.lean <<'EOF'
module

import Demo.Basic
import Demo.Basic

public def fresh : String := greeting
EOF
printf 'import Demo.New\n' >> Demo.lean
git_q add -A
git_q commit -qm 'add another module with a duplicate import'

set +e
changed=$(lake exe lean-fmt check --root . --changed-since main 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "--changed-since with findings returned $status, expected 1"
case "$changed" in
*'main...HEAD (merge base)'*) ;;
*) fail "--changed-since stopped announcing its comparison: $changed" ;;
esac
case "$changed" in
*'Demo/New.lean'*) ;;
*) fail '--changed-since did not select the file this branch added' ;;
esac
# The subset claim: a file with a real finding that this branch did not touch stays unselected.
case "$changed" in
*'Demo/Dirty.lean'*) fail '--changed-since selected a file the branch did not change' ;;
esac
ok '--changed-since selects the branch subset and announces its base'

# An empty selection means "nothing to do", not "the whole project". Everywhere else in the CLI an
# empty file list means the opposite, so a wrapper that loses this reformats the tree on a no-op
# commit.
set +e
empty=$(lake exe lean-fmt check --root . --changed-since HEAD 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "--changed-since selecting nothing returned $status, expected 0"
case "$empty" in
*'no changed Lean sources'*) ;;
*) fail "--changed-since selecting nothing lost its notice: $empty" ;;
esac
ok '--changed-since selecting nothing exits 0 with a notice and analyzes nothing'

printf -- '--- Recipe 4: a generic runner, exit codes only ---\n'

# The recipe as published, verbatim in shape: build, run, branch on the code.
set +e
lake exe lean-fmt check --root . --output-format junit --output-file report.xml >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "junit run with findings returned $status, expected 1"
grep -q '<testsuites name="lean-fmt"' report.xml || fail 'the JUnit report lost its root element'
ok 'the generic recipe distinguishes findings (1) from infrastructure failure (2)'

# A pipeline must not launder a failure into success. This is why the recipes may use pipes.
piped=$(
  set -o pipefail
  lake exe lean-fmt check --root . Demo/Dirty.lean 2>/dev/null | head -1 >/dev/null
  echo $?
)
[ "$piped" -eq 1 ] || fail "a truncated pipeline reported $piped; findings must survive a broken pipe"
ok 'a broken pipe keeps the run exit code'

printf -- '--- Cache: what docs/ci.md tells CI to cache ---\n'

# `docs/ci.md` tells a job to cache `.lake` and `.lean-fmt-cache` together under one key. That
# instruction is only correct because cache identity takes the formatter binary's (path, size,
# mtime) rather than its content -- so a restore that changes the binary's mtime silently misses
# every entry, and a job that rebuilds lean-fmt each run gets nothing from a restored cache.
#
# A total miss looks exactly like a warm cache that is merely slow, so nothing else in the suite
# would notice. These two checks are the gate on that document's central claim.
git_q checkout -q main
rm -rf .lean-fmt-cache
lake exe lean-fmt check --root . >/dev/null 2>&1 || true
before=$(find .lean-fmt-cache -type f -name '*.json' | sort)
[ -n "$before" ] || fail 'a cold run wrote no cache entry'

# Restore preserving mtimes, the way actions/cache unpacks with tar.
tar -czf "$work/cache.tgz" .lake .lean-fmt-cache
rm -rf .lake .lean-fmt-cache
tar -xzf "$work/cache.tgz"
lake exe lean-fmt check --root . >/dev/null 2>&1 || true
after=$(find .lean-fmt-cache -type f -name '*.json' | sort)
[ "$before" = "$after" ] ||
  fail "an mtime-preserving restore did not hit the cache; docs/ci.md's caching recipe is wrong
before: $before
after:  $after"
ok 'an mtime-preserving restore of .lake and .lean-fmt-cache hits the cache'

# The converse. Touching the binary must miss, because that is the failure the recipe warns about:
# rebuilding lean-fmt every run orphans the whole index.
touch .lake/packages/lean-fmt/.lake/build/bin/lean-fmt
lake exe lean-fmt check --root . >/dev/null 2>&1 || true
touched=$(find .lean-fmt-cache -type f -name '*.json' | sort)
[ "$touched" != "$before" ] ||
  fail 'touching the formatter binary did not change cache identity; docs/ci.md overstates the risk'
ok 'a rebuilt formatter binary orphans the index, as docs/ci.md warns'

printf -- '--- Installation from clean sources ---\n'

# `git archive` carries exactly what is committed. Building from it catches a source file that is
# gitignored but needed to build -- a defect invisible from any working tree that has the file.
archive="$work/archive"
mkdir -p "$archive"
(cd "$repo_root" && git archive --format=tar HEAD) | tar -x -C "$archive"

[ ! -e "$archive/.lake" ] || fail 'the archive carries a build directory'
[ ! -e "$archive/.lean-fmt-cache" ] || fail 'the archive carries a result cache'
for required in lean-toolchain lakefile.lean lake-manifest.json lean-fmt.toml; do
  [ -e "$archive/$required" ] || fail "the archive is missing $required, which a consumer needs"
done
ok 'the archive carries the files a build needs and none of the build outputs'

(cd "$archive" && lake build >"$work/archive-build.log" 2>&1) ||
  fail "a clean git archive did not build: $(tail -5 "$work/archive-build.log")"
ok 'a clean git archive builds with no working-tree state'

# And the binary it produced actually runs, against its own tree.
set +e
(cd "$archive" && ./.lake/build/bin/lean-fmt check --root . >"$work/archive-check.log" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] ||
  fail "the archive's own binary reported $status against its own sources: $(tail -3 "$work/archive-check.log")"
ok 'the binary built from the archive runs clean against the archive'

printf 'ci recipes ok\n'
