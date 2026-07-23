#!/usr/bin/env bash
set -euo pipefail

# Actual imported syntax through the production exact formatter. Descriptor-derived and explicitly
# registered extension roots are admitted only after structural validation and idempotence.

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

macro "adapter_twice" value:term : term => `($value + $value)

local notation "adapterUnit" => (1 : Nat)

def quotationMacroProbe : Nat := adapter_twice adapterUnit

def parserCategoryProbe : Nat := item_term(selectedName)
LEAN

LEAN_NUM_THREADS=1 lake setup-file "$work/AdapterInput.lean" >"$work/setup.json"
for width in 32 100; do
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/setup.json" "$work/AdapterInput.lean" "AdapterInput.lean" 8589934592 "4:$width" \
    >"$work/envelope-$width.json"
done

python3 - "$work/envelope-100.json" "$work/envelope-32.json" <<'PY'
import json, sys

envelope = json.load(open(sys.argv[1]))
draft = envelope.get("canonical")
narrow_envelope = json.load(open(sys.argv[2]))
narrow = narrow_envelope.get("canonical")
assert draft is not None and envelope.get("validationFailure") is None, envelope
assert narrow is not None and narrow_envelope.get("validationFailure") is None, narrow_envelope
assert narrow is not None and narrow["text"] != draft["text"], narrow
metrics = draft["metrics"]
assert metrics["frontendRuns"] == 2 and metrics["commands"] >= 10, metrics
assert metrics["coreDocuments"] > 0 and metrics["registryDocuments"] == 2, metrics
assert metrics["structuralDocuments"] == metrics["coreDocuments"], metrics
assert metrics["coreRegistryDocuments"] == 0, metrics
assert metrics["extensionRegistryDocuments"] == 2, metrics
assert metrics["registryNodes"] >= metrics["commands"], metrics
assert metrics["explicitDocuments"] > 0 and metrics["descriptorDocuments"] > 0, metrics
assert metrics["commentOwners"] == 3 and metrics["nativeEvents"] > 0, metrics
assert draft["validation"]["structuralComparisons"] == 1, draft["validation"]
assert draft["validation"]["idempotencePasses"] == 1, draft["validation"]

output = draft["text"]
assert "explicit_command selectedName" in output, output
assert "explicit_command       selectedName" not in output, output
assert "twice(" in output and "adapter_exact" in output, output
assert "Nat → Nat" in output, output
assert "macro \"adapter_twice\"" in output and "`(" in output, output
assert "local notation \"adapterUnit\"" in output, output
assert "item_term(selectedName)" in output, output
for payload in ["adapter block payload", "adapter trailing payload", "adapter tactic payload"]:
    assert output.count(payload) == 1, (payload, output)

source_cursor = output_cursor = 0
for unit in draft["sourceMap"]:
    assert unit["source"]["start"] == source_cursor, (source_cursor, unit)
    assert unit["output"]["start"] == output_cursor, (output_cursor, unit)
    source_cursor = unit["source"]["stop"]
    output_cursor = unit["output"]["stop"]
assert source_cursor == envelope["artifact"]["source"]["normalizedBytes"], (source_cursor, envelope)
assert output_cursor == len(output.encode()), (output_cursor, len(output.encode()))

print(json.dumps({
    "commands": metrics["commands"],
    "comments": metrics["commentOwners"],
    "descriptor": metrics["descriptorDocuments"],
    "explicit": metrics["explicitDocuments"],
    "units": len(draft["sourceMap"]),
    "widthSensitive": narrow["text"] != output,
}, sort_keys=True, separators=(",", ":")))
print("  ok   narrow/wide output is structurally equal and idempotent")
PY

cat >"$work/Throwing.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

throwing_command
LEAN

LEAN_NUM_THREADS=1 lake setup-file "$work/Throwing.lean" >"$work/throwing-setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/throwing-setup.json" "$work/Throwing.lean" "Throwing.lean" 8589934592 4:100 \
  >"$work/throwing.json"

python3 - "$work/throwing.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
assert envelope.get("canonical") is None, envelope
failure = envelope["formatFailure"]
assert "throwingCommand" in failure["trace"]["kind"], failure
assert "explicit" in failure["trace"]["resolution"], failure
assert "adapter fixture formatter failure" in failure["detail"], failure
assert failure["range"]["stop"] > failure["range"]["start"], failure
print("  ok   throwing formatter surfaced a typed hard failure with kind/category/range/trace")
PY

cat >"$work/Invalid.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

invalid_command
LEAN

LEAN_NUM_THREADS=1 lake setup-file "$work/Invalid.lean" >"$work/invalid-setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/invalid-setup.json" "$work/Invalid.lean" "Invalid.lean" 8589934592 4:100 \
  >"$work/invalid.json"

python3 - "$work/invalid.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
assert envelope.get("canonical") is None, envelope
failure = envelope["validationFailure"]
assert failure["gate"] == "diagnostics", failure
assert "expected" in failure["detail"] and "identifier" in failure["detail"], failure
print("  ok   unparsable extension output was a named diagnostics-gate refusal")
PY

printf 'tests/formatter-adapter: ok\n'
