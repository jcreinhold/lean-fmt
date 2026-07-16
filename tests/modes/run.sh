#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
cache_root="$repo_root/.lean-fmt-cache"
source_file="$repo_root/tests/check/Findings.lean"
artifact_root="$repo_root/.lake/build/lean-fmt-artifacts"

restore() {
  if [[ -f "$work/Findings.lean" ]]; then
    cp -p "$work/Findings.lean" "$source_file"
  fi
  rm -rf "$cache_root" "$work"
}
trap restore EXIT

cd "$repo_root"
cp -p "$source_file" "$work/Findings.lean"
rm -rf "$cache_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests \
  LocalSyntax:leanFmtArtifact Findings:leanFmtArtifact Clean:leanFmtArtifact
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
expected = """--- a/tests/check/Findings.lean
+++ b/tests/check/Findings.lean
@@ -1,3 +1,3 @@
-module
-
-def findingValue : Nat := 1  
+module
+
+def findingValue : Nat := 1
mode=diff files=1 findings=1 changed=1 written=0 broken=0 rejected=0 infrastructure_failures=0
"""
assert diff == expected, repr(diff)
PY

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
assert artifact["mainModule"] == "Downstream"
assert [finding["code"] for finding in artifact["findings"]] == ["FMT001"]
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
