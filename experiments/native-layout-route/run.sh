#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mathlib=/Users/jcreinhold/Code/mathlib4
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo"
lake env lean "$here/Probe.lean" -o "$work/Probe.olean"
lake build lean-fmt lean-fmt-tests FormatterAdapterFixtures
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)
root_path=$(lake env printenv LEAN_PATH)
mathlib_path=$(cd "$mathlib" && lake env printenv LEAN_PATH)

run_oracle() {
  local root=$1 source=$2 module=$3 width=$4 label=$5
  local setup="$work/$label.setup.json"
  (cd "$root" && lake setup-file "$source" >"$setup")
  python3 "$repo/tests/formatter/oracle.py" \
    --application "$application" --tests "$tests" --setup "$setup" --source "$root/$source" -- \
    env LEAN_PATH="$root_path:$mathlib_path" lake env lean --run "$here/Probe.lean" "$width" "$module"
}

for width in 24 40 60 100; do
  run_oracle "$repo" experiments/native-layout-route/fixtures/Core.lean \
    NativeLayoutRouteFixture "$width" "core-$width"
  run_oracle "$repo" experiments/native-layout-route/fixtures/SourceData.lean \
    NativeLayoutSourceData "$width" "source-data-$width"
done

run_oracle "$repo" experiments/native-layout-route/fixtures/Extension.lean \
  NativeLayoutRouteExtension 40 extension

if [[ ${LEAN_FMT_ROUTE_FIRST24:-0} == 1 ]]; then
  head -24 "$repo/experiments/workloads/mathlib-v4.33.0-rc1-stratified.txt" |
    while IFS= read -r source; do
      module=${source%.lean}
      module=${module//\//.}
      label=${source//\//-}
      run_oracle "$mathlib" "$source" "$module" 80 "$label"
    done
fi

echo 'native layout route probe passed'
