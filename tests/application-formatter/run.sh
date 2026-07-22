#!/usr/bin/env bash
set -euo pipefail

# Validated frontend-native layout through preview, diff, cache, and all-or-nothing publication.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "$repo_root/tests/application-formatter/.tmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt FormatterAdapterFixtures
application=$(lake -q query lean-fmt --text)

cat >"$work/A.lean" <<'LEAN'
module

def alpha : Nat := 1
LEAN
cat >"$work/B.lean" <<'LEAN'
module

def beta : Nat := 2
LEAN
cp "$work/A.lean" "$work/A.original"
cp "$work/B.lean" "$work/B.original"

set +e
LEAN_FMT_PROFILE_PHASES=1 "$application" format --check --root "$repo_root" --no-cache --json \
  "$work/A.lean" "$work/B.lean" >"$work/preview.json" 2>"$work/preview.json.stderr"
preview_code=$?
"$application" diff --root "$repo_root" --no-cache --output-format json \
  "$work/A.lean" "$work/B.lean" >"$work/diff.json"
diff_code=$?
set -e
[[ $preview_code == 1 && $diff_code == 1 ]]
[[ $(grep -c '^cache.path_exact_render=1$' "$work/preview.json.stderr") == 2 ]]
python3 - "$work/preview.json" "$work/diff.json" "$work/A.expected" "$work/B.expected" <<'PY'
import json, pathlib, sys
preview, diff = (json.load(open(p)) for p in sys.argv[1:3])
assert [f["path"] for f in preview["files"]] == [f["path"] for f in diff["files"]]
assert all(f["status"] == "would-format" for f in preview["files"]), preview
assert all(f["status"] == "would-diff" for f in diff["files"]), diff
for file, target in zip(preview["files"], sys.argv[3:]):
    pathlib.Path(target).write_text(file["formatted"])
print("  ok   format --check and diff agree on the same admitted candidates")
PY

# A cached canonical answer is still selection-independent and must not rerun the frontend.
"$application" format --check --root "$repo_root" --json "$work/A.lean" >/dev/null || true
set +e
LEAN_FMT_PROFILE_PHASES=1 LEAN_FMT_TEST_ANALYZER=/usr/bin/false \
  "$application" format --check --root "$repo_root" --json "$work/A.lean" \
  >"$work/cache.json" 2>"$work/cache.profile"
cache_code=$?
set -e
[[ $cache_code == 1 ]]
grep -q '^cache.path_cache_hit=1$' "$work/cache.profile"
printf '  ok   admitted canonical text is served from cache without a frontend rerun\n'

LEAN_FMT_PROFILE_PHASES=1 "$application" check --root "$repo_root" --no-cache \
  tests/check/Clean.lean >/dev/null 2>"$work/source.profile"
grep -q '^cache.path_source_shortcut=1$' "$work/source.profile"
printf '  ok   path metrics distinguish source shortcut, exact render, and cache service\n'

cat >"$work/stale-hook" <<'SH'
#!/usr/bin/env bash
if [[ $1 == */B.lean ]]; then printf '\n-- concurrent edit\n' >>"$1"; fi
SH
chmod +x "$work/stale-hook"
set +e
LEAN_FMT_TEST_BEFORE_WRITE="$work/stale-hook" "$application" format --root "$repo_root" \
  --no-cache --json "$work/A.lean" "$work/B.lean" >"$work/stale.json"
stale_code=$?
set -e
[[ $stale_code == 1 ]]
cmp "$work/A.lean" "$work/A.original"
cmp <(head -n 3 "$work/B.lean") "$work/B.original"
grep -q 'concurrent edit' "$work/B.lean"
python3 - "$work/stale.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and all(f["status"] == "rejected" for f in r["files"]), r
assert any("source changed after analysis" in d for f in r["files"] for d in f["diagnostics"]), r
print("  ok   one stale member prevents every formatter publication in the batch")
PY

cp "$work/B.original" "$work/B.lean"
"$application" format --root "$repo_root" --no-cache --json \
  "$work/A.lean" "$work/B.lean" >"$work/write.json"
cmp "$work/A.lean" "$work/A.expected"
cmp "$work/B.lean" "$work/B.expected"
python3 - "$work/write.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 2 and all(f["written"] for f in r["files"]), r
print("  ok   the complete admitted batch publishes the previewed bytes")
PY

cat >"$work/Throwing.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

throwing_command
LEAN
set +e
LEAN_FMT_PROFILE_PHASES=1 "$application" format --check --root "$repo_root" --no-cache --json \
  "$work/Throwing.lean" >"$work/refusal.json" 2>"$work/refusal.profile"
refusal_code=$?
set -e
[[ $refusal_code == 2 ]]
grep -q '^cache.path_validation_failure=1$' "$work/refusal.profile"
python3 - "$work/refusal.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["written"] == 0 and r["infrastructureFailures"], r
assert r["files"][0]["status"] == "infrastructure-failure", r
print("  ok   formatter admission refusal maps to infrastructure exit 2")
PY

printf 'tests/application-formatter: ok\n'
