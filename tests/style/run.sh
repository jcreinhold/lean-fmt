#!/usr/bin/env bash
set -euo pipefail

# Specification gate. Intended rows are structurally validated now; their owning prompts turn them
# into production byte-idempotent goldens. Known-unsafe current registered output remains a rejection.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

python3 - docs/style.md tests/style/matrix.json <<'PY'
import json, pathlib, sys
doc = pathlib.Path(sys.argv[1]).read_text()
rows = json.loads(pathlib.Path(sys.argv[2]).read_text())
required = {"header", "command", "declaration", "term", "collection", "block", "trivia", "registry"}
assert len(rows) == 19 and len({r["id"] for r in rows}) == len(rows), rows
assert {r["family"] for r in rows} == required, {r["family"] for r in rows}
assert {r["owner"] for r in rows} >= {"11", "11b", "12", "12b", "13", "14"}, rows
for row in rows:
    assert all(row[k].strip() for k in ("flat", "broken", "comment")), row
    assert f"`{row['id']}`" in doc, row["id"]
assert "format-ignore-next" in doc and "two spaces" in doc and "line width" in doc
print("  ok   19 unique style rows cover every prompt 11-14 family and decision axis")
PY

LEAN_NUM_THREADS=1 lake setup-file tests/style/fixtures/PolicyInput.lean >"$work/setup.json"
oracle=(python3 tests/formatter/oracle.py --application "$application" --tests "$tests" \
  --setup "$work/setup.json" --source tests/style/fixtures/PolicyInput.lean --)
"${oracle[@]}" python3 tests/style/expected_candidate.py tests/style/fixtures/Policy.lean \
  >"$work/policy.json"
python3 - "$work/policy.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["status"] == "ok" and r["changed"] == 1, r
assert r["nodes"] > 100 and r["tokens"] > 50 and r["comments"] == 0, r
print("  ok   intended command/declaration/term/collection/block pair preserves full structure")
PY

for width in 20 40 80 100; do
  LEAN_NUM_THREADS=1 lake setup-file tests/style/fixtures/NativeSafe.lean >"$work/native-setup.json"
  "$application" __analyze-exact "$work/native-setup.json" \
    tests/style/fixtures/NativeSafe.lean NativeSafe.lean 8589934592 "4:$width" \
    >"$work/native-$width.json"
done
python3 - "$work" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for width in (20, 40, 80, 100):
    r = json.loads((root / f"native-{width}.json").read_text())
    assert r.get("canonical") is not None and r.get("validationFailure") is None, (width, r)
    assert r["canonical"]["validation"]["renders"] == 2, r
print("  ok   a currently safe style fixed point passes production admission at 20/40/80/100")
PY

LEAN_NUM_THREADS=1 lake setup-file tests/style/fixtures/UnsafeLiteral.lean >"$work/literal-setup.json"
"$application" __analyze-exact "$work/literal-setup.json" \
  tests/style/fixtures/UnsafeLiteral.lean UnsafeLiteral.lean 8589934592 4:100 \
  >"$work/literal.json"
python3 - "$work/literal.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
failure = r["validationFailure"]
assert r.get("canonical") is None and failure["gate"] == "tokens", r
assert "changed spelling" in failure["detail"], failure
print("  ok   known multiline-literal corruption remains a typed production rejection")
PY

printf 'tests/style: ok\n'
