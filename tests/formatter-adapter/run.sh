#!/usr/bin/env bash
set -euo pipefail

# Actual imported syntax through the live whole-module draft. Mode 4 is a private audit transport;
# product callers cannot select it.

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
for width in 32 100; do
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/setup.json" "$work/AdapterInput.lean" "AdapterInput.lean" 8589934592 "4:$width" \
    >"$work/envelope-$width.json"
done

python3 - "$work/envelope-100.json" "$work/envelope-32.json" "$work/Candidate.lean" <<'PY'
import json, pathlib, sys

envelope = json.load(open(sys.argv[1]))
draft = envelope.get("formatDraft")
narrow = json.load(open(sys.argv[2])).get("formatDraft")
assert draft is not None and envelope.get("formatFailure") is None, envelope
assert narrow is not None and narrow["text"] != draft["text"], narrow
metrics = draft["metrics"]
assert metrics["frontendRuns"] == 1 and metrics["commands"] == 6, metrics
assert metrics["registryDocuments"] == 6 and metrics["registryNodes"] == 6, metrics
assert metrics["explicitDocuments"] == 5 and metrics["descriptorDocuments"] == 1, metrics
assert metrics["commentOwners"] == 3 and metrics["nativeEvents"] > 0, metrics

output = draft["text"]
assert "explicit_command selectedName" in output, output
assert "explicit_command       selectedName" not in output, output
assert "twice(" in output and "adapter_exact" in output, output
assert "Nat -> Nat" in output, output
for payload in ["adapter block payload", "adapter trailing payload", "adapter tactic payload"]:
    assert output.count(payload) == 1, (payload, output)

source_cursor = output_cursor = 0
for unit in draft["sourceMap"]:
    assert unit["source"]["start"] == source_cursor, (source_cursor, unit)
    assert unit["output"]["start"] == output_cursor, (output_cursor, unit)
    source_cursor = unit["source"]["stop"]
    output_cursor = unit["output"]["stop"]
assert source_cursor == draft["sourceBytes"], (source_cursor, draft)
assert output_cursor == len(output.encode()), (output_cursor, len(output.encode()))

pathlib.Path(sys.argv[3]).write_text(output)
print(json.dumps({
    "commands": metrics["commands"],
    "comments": metrics["commentOwners"],
    "descriptor": metrics["descriptorDocuments"],
    "explicit": metrics["explicitDocuments"],
    "units": len(draft["sourceMap"]),
    "widthSensitive": narrow["text"] != output,
}, sort_keys=True, separators=(",", ":")))
PY

LEAN_NUM_THREADS=1 lake setup-file "$work/Candidate.lean" >/dev/null
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/setup.json" "$work/Candidate.lean" "Candidate.lean" 8589934592 0 \
  >"$work/candidate-envelope.json"
python3 - "$work/envelope-100.json" "$work/candidate-envelope.json" <<'PY'
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
envelope = json.load(open(sys.argv[1]))
assert envelope.get("formatDraft") is None, envelope
failure = envelope["formatFailure"]
assert "throwingCommand" in failure["trace"]["kind"], failure
assert "explicit" in failure["trace"]["resolution"], failure
assert "adapter fixture formatter failure" in failure["detail"], failure
assert failure["range"]["stop"] > failure["range"]["start"], failure
print("  ok   throwing formatter surfaced a typed hard failure with kind/category/range/trace")
PY

printf 'tests/formatter-adapter: ok\n'
