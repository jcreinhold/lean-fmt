#!/usr/bin/env bash
set -euo pipefail

# Closed-core provenance and the zero-core-registry release gate. Inspectable extension descriptors
# are structural leaves; only extension roots with explicit formatters enter the live registry.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt FormatterAdapterFixtures
application=$(lake -q query lean-fmt --text)

LEAN_NUM_THREADS=1 lake env lean --run tests/core-surface/Spec.lean

lake setup-file LeanFmt/Application.lean >"$work/application.setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/application.setup.json" LeanFmt/Application.lean LeanFmt/Application.lean \
  8589934592 draft:100 >"$work/application.json"

cat >"$work/Extension.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

descriptor_command sample := twice(1)
explicit_command sampleName
LEAN
lake setup-file "$work/Extension.lean" >"$work/extension.setup.json"
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/extension.setup.json" "$work/Extension.lean" Extension.lean \
  8589934592 4:100 >"$work/extension.json"

python3 - "$work/application.json" "$work/extension.json" <<'PY'
import copy, json, sys

application_envelope, extension_envelope = (json.load(open(path)) for path in sys.argv[1:])
application = application_envelope["formatDraft"]["metrics"]
extension = extension_envelope["canonical"]["metrics"]
assert extension_envelope.get("validationFailure") is None, extension_envelope

def complete(metrics):
    classified = (metrics["structuralDocuments"] + metrics["coreRegistryDocuments"] +
                  metrics["extensionRegistryDocuments"])
    provenance = metrics["coreDocuments"] + metrics["registryDocuments"]
    return classified == provenance

def release_gate(metrics):
    return complete(metrics) and metrics["coreRegistryDocuments"] == 0

assert complete(application), application
assert release_gate(application), application

assert complete(extension), extension
# Every root reaches Lean's live registry under the native layout adapter, so both extension roots
# are registry documents; `descriptor_command` is no longer withheld as a structural leaf. How Lean
# resolved each formatter is what still separates them, and `descriptorDocuments` pins that.
assert extension["extensionRegistryDocuments"] == 2, extension
assert extension["descriptorDocuments"] == 1, extension

omitted = copy.deepcopy(extension)
omitted["extensionRegistryDocuments"] -= 1
assert not complete(omitted), "an omitted ownership row passed completeness"

misclassified = copy.deepcopy(extension)
misclassified["coreRegistryDocuments"] += misclassified["extensionRegistryDocuments"]
misclassified["extensionRegistryDocuments"] = 0
assert not release_gate(misclassified), "an extension misclassified as core passed the registry gate"

print("core-surface ownership:", {
    "applicationCoreRegistry": application["coreRegistryDocuments"],
    "applicationStructural": application["structuralDocuments"],
    "extensionRegistry": extension["extensionRegistryDocuments"],
})
print("core-surface negative gates: omission and misclassification rejected")
PY

printf 'tests/core-surface: ok\n'
