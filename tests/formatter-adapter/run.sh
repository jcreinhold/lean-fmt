#!/usr/bin/env bash
set -euo pipefail

# Actual imported syntax through Lean's live formatter registry. The analyzer's mode 4 is a private
# audit transport; product callers cannot select it.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt FormatterAdapterFixtures
application=$(lake -q query lean-fmt --text)

cat >"$work/AdapterInput.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

set_option pp.unicode false

/- adapter block payload -/
descriptor_command narrow := [twice(1), twice(2), twice(3), twice(4), twice(5), twice(6), twice(7), twice(8)]

explicit_command       selectedName -- adapter trailing payload

def tacticProbe : True := by
  -- adapter tactic payload
  adapter_exact True.intro

def optionProbe : Nat → Nat := fun value => value
LEAN

LEAN_NUM_THREADS=1 lake setup-file "$work/AdapterInput.lean" >"$work/setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$work/AdapterInput.lean" "AdapterInput.lean" 8589934592 4 \
  >"$work/envelope.json"

python3 - "$work/envelope.json" "$work/Candidate.lean" <<'PY'
import json, pathlib, sys

envelope = json.load(open(sys.argv[1]))
audit = envelope.get("formatterAudit")
assert audit is not None, envelope
entries = audit["entries"]
assert audit["successes"] == len(entries) and audit["failures"] == 0, audit
assert audit["explicit"] >= 1 and audit["descriptor"] >= 1, audit
assert audit["commentOwners"] == 3, audit
assert all(entry["documentNodes"] == 1 for entry in entries), entries
assert all(entry["narrowNativeEvents"] > 0 and entry["wideNativeEvents"] > 0 for entry in entries), entries

def resolution(entry):
    return entry["trace"]["resolution"]

explicit = [entry for entry in entries if "explicitCommand" in entry["trace"]["kind"]]
assert len(explicit) == 1 and "explicit" in resolution(explicit[0]), explicit
assert explicit[0]["wide"].startswith("explicit_command selectedName"), explicit[0]
assert explicit[0]["wide"] != explicit[0]["source"], explicit[0]

all_narrow = "\n".join(entry["narrow"] for entry in entries)
all_wide = "\n".join(entry["wide"] for entry in entries)
assert all_narrow != all_wide, "registry documents were not width-sensitive"
assert "twice(" in all_wide, all_wide
assert "adapter_exact" in all_wide, all_wide
assert "Nat -> Nat" in all_wide, all_wide
for payload in ["adapter block payload", "adapter trailing payload", "adapter tactic payload"]:
    assert all_wide.count(payload) == 1, (payload, all_wide)

candidate = "module\n\nimport AdapterSyntax\n\n" + all_wide + "\n"
pathlib.Path(sys.argv[2]).write_text(candidate)
print(json.dumps({
    "commands": len(entries),
    "comments": audit["commentOwners"],
    "descriptor": audit["descriptor"],
    "explicit": audit["explicit"],
    "widthSensitive": all_narrow != all_wide,
}, sort_keys=True, separators=(",", ":")))
PY

# The rendered commands remain a module accepted under the same imported extension environment.
LEAN_NUM_THREADS=1 lake setup-file "$work/Candidate.lean" >/dev/null
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$work/Candidate.lean" "Candidate.lean" 8589934592 0 \
  >"$work/candidate-envelope.json"
python3 - "$work/envelope.json" "$work/candidate-envelope.json" <<'PY'
import json, sys
before, after = (json.load(open(path))["artifact"]["source"] for path in sys.argv[1:])
def tree(source):
    kinds = source["kinds"]
    return [(kinds[node[0]], node[1]) for node in source["nodes"]]
assert tree(before) == tree(after), "registered rendering changed normalized syntax parentage"
assert [token[0] for token in before["tokens"]] == [token[0] for token in after["tokens"]], \
    "registered rendering changed token ownership"
print("  ok   narrow/wide output preserves normalized syntax structure")
PY

cat >"$work/Throwing.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

throwing_command
LEAN

LEAN_NUM_THREADS=1 lake setup-file "$work/Throwing.lean" >"$work/throwing-setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/throwing-setup.json" "$work/Throwing.lean" "Throwing.lean" 8589934592 4 \
  >"$work/throwing.json"

python3 - "$work/throwing.json" <<'PY'
import json, sys
audit = json.load(open(sys.argv[1]))["formatterAudit"]
assert audit["failures"] == 1, audit
failed = [entry for entry in audit["entries"] if entry.get("error") is not None]
assert len(failed) == 1, audit
entry = failed[0]
assert "throwingCommand" in entry["trace"]["kind"], entry
assert "explicit" in entry["trace"]["resolution"], entry
assert "adapter fixture formatter failure" in entry["error"], entry
assert entry.get("narrow") is None and entry.get("wide") is None, entry
assert entry["range"]["stop"] > entry["range"]["start"], entry
print("  ok   throwing formatter surfaced a typed hard failure with kind/category/range/trace")
PY

printf 'tests/formatter-adapter: ok\n'
