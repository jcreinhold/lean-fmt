#!/usr/bin/env bash
set -euo pipefail

# Actual-syntax comment ownership: no projection-token attachment path is exercised here.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

summary() {
  local setup=$1 source=$2 display=$3 output=$4
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$display" 8589934592 3 >"$work/envelope.json"
  "$tests" comment-summary "$work/envelope.json" >"$output"
  python3 - "$output" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["valid"] is True, value
assert value["comments"] == value["leading"] + value["trailing"] + value["dangling"], value
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

cat >"$work/Ownership.lean" <<'LEAN'
module

/-! Unicode module documentation: λ → 外. -/

syntax "comment_command" ident : command
macro_rules
  | `(comment_command $name) => `(def $name : Nat := 0)

/- outer /- nested -/ comment -/
comment_command generated

/-- Declaration documentation. -/
def empty : List Nat := [ /- empty-container payload -/ ]

def trailing : Nat := 1 -- same-line payload

-- adjacent one
-- adjacent two
def adjacent : Nat := 2

-- lean-fmt: ignore-next
def suppressed : Nat := /- payload inside suppression scope -/ 3

-- before terminal
#exit
-- verbatim tail, outside the parsed region
LEAN

LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed.setup.json"
printf -- '--- custom/macro/delimiter/terminal/suppression fixture ---\n'
summary "$work/borrowed.setup.json" "$work/Ownership.lean" "Ownership.lean" "$work/ownership.json"

python3 - "$work/Ownership.lean" "$work/OwnershipCRLF.lean" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_bytes(text.replace("\n", "\r\n").encode())
PY
printf -- '--- CRLF normalization preserves the ownership digest ---\n'
summary "$work/borrowed.setup.json" "$work/OwnershipCRLF.lean" "OwnershipCRLF.lean" "$work/crlf.json"
python3 - "$work/ownership.json" "$work/crlf.json" <<'PY'
import json, sys
left, right = (json.load(open(path)) for path in sys.argv[1:])
assert left == right, (left, right)
print("  ok   LF and CRLF summaries are byte-identical after normalization")
PY

printf -- '--- imported custom syntax, docstrings, nested comments, Unicode, and choice ---\n'
LEAN_NUM_THREADS=1 lake setup-file tests/compiler/LocalSyntax.lean >"$work/local.setup.json"
summary "$work/local.setup.json" tests/compiler/LocalSyntax.lean \
  tests/compiler/LocalSyntax.lean "$work/local.json"

python3 - "$work/ownership.json" "$work/local.json" <<'PY'
import json, sys
synthetic, local = (json.load(open(path)) for path in sys.argv[1:])
assert synthetic == {
    "comments": 10, "dangling": 1, "leading": 7,
    "payloadDigest": "aeac5503e51c2284f134eaa98da9f9eafe18b2103a2bebc0261ea6b87a7510aa",
    "suppressed": 2, "trailing": 2, "valid": True,
}, synthetic
assert local == {
    "comments": 6, "dangling": 0, "leading": 5,
    "payloadDigest": "e0e388ff4e428c9b7892288a3b908ae25640f0797eb1d18a1d17fc5cd99481e7",
    "suppressed": 0, "trailing": 1, "valid": True,
}, local
print("  ok   exact owner counts and payload/owner digests match")
PY

printf 'tests/comments: ok\n'
