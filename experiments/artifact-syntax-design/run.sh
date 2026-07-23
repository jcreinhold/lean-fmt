#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
experiment="$repo_root/experiments/artifact-syntax-design"
mathlib_root=${1:-/Users/jcreinhold/Code/mathlib4}
mathlib_manifest=${2:-/Users/jcreinhold/Code/prompts/lean-fmt/stacks/01-frontend-native-formatter/evidence/16-current-mathlib-sample.txt}
probe="$experiment/.lake/build/bin/artifactSyntaxProbe"
lean_lib=$(cd "$repo_root" && lake env lean --print-prefix)/lib/lean
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

(cd "$experiment" && lake build && lake -R build OptionProbeFixtures)

printf '%s\n' '--- direct Syntax codec is not a public API ---'
if (cd "$experiment" && lake env lean DirectCodecNegative.lean) \
    >"$scratch/direct-codec.log" 2>&1; then
  printf 'DirectCodecNegative.lean unexpectedly found a public Syntax JSON codec\n' >&2
  exit 1
fi
grep -F 'Lean.ToJson Lean.Syntax' "$scratch/direct-codec.log"
grep -F 'Lean.FromJson Lean.Syntax' "$scratch/direct-codec.log"

printf '%s\n' '--- exact mapped .olean registry, extensions disabled/enabled ---'
adapter_olean="$repo_root/.lake/build/lib/lean/AdapterSyntax.olean"
DYLD_LIBRARY_PATH="$lean_lib" "$probe" --registry-no-exts "$adapter_olean"
DYLD_LIBRARY_PATH="$lean_lib" "$probe" --registry "$adapter_olean"

run_one() {
  local project_root=$1 source=$2
  (cd "$project_root" && lake setup-file "$source") >"$scratch/setup.json"
  (cd "$project_root" && DYLD_LIBRARY_PATH="$lean_lib" "$probe" \
    "$scratch/setup.json" "$source" "$source")
}

printf '%s\n' '--- hard fixtures ---'
run_one "$repo_root" tests/compiler/LocalSyntax.lean
run_one "$repo_root" experiments/artifact-syntax-design/fixtures/Extensions.lean
run_one "$repo_root" experiments/artifact-syntax-design/fixtures/Terminal.lean

aggregate() {
  python3 -c 'import json,sys
rows=[json.loads(line) for line in sys.stdin if line.strip()]
keys=["sourceBytes","wireBytes","syntaxWireBytes","optionsWireBytes","currentArtifactBytes",
      "fragmentedWireBytes","fragmentedSyntaxBytes","fragmentedOptionsBytes",
      "entries","nodes","leaves","choices","synthetic","missing","preresolved","commands",
      "liveFormatMatches","finalEnvironmentMatches","formatterRefusals","encodeUs","decodeUs"]
out={"files":len(rows)}
out.update({key:sum(row[key] for row in rows) for key in keys})
out["wirePerSource"]=round(out["wireBytes"]/out["sourceBytes"],3)
out["currentPerSource"]=round(out["currentArtifactBytes"]/out["sourceBytes"],3)
out["wireVsCurrent"]=round(out["wireBytes"]/out["currentArtifactBytes"],3)
out["fragmentedPerSource"]=round(out["fragmentedWireBytes"]/out["sourceBytes"],3)
out["fragmentedVsCurrent"]=round(out["fragmentedWireBytes"]/out["currentArtifactBytes"],3)
largest=max(rows,key=lambda row:row["wireBytes"])
out["largestWire"]=largest["path"]
out["largestWireBytes"]=largest["wireBytes"]
out["maxDecodeUs"]=max(row["decodeUs"] for row in rows)
out["maxEncodeUs"]=max(row["encodeUs"] for row in rows)
out["maxOptionStates"]=max(row["optionStates"] for row in rows)
out["optionEntries"]=sum(row["optionEntries"] for row in rows)
print(json.dumps(out,sort_keys=True))'
}

printf '%s\n' '--- all lean-fmt sources ---'
while IFS= read -r source; do
  run_one "$repo_root" "$source"
done <"$repo_root/experiments/workloads/lean-fmt-self.txt" | aggregate

printf '%s\n' '--- current mathlib sample ---'
while IFS= read -r source; do
  run_one "$mathlib_root" "$source"
done <"$mathlib_manifest" | aggregate
