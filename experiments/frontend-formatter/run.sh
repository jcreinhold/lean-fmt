#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
mathlib=/Users/jcreinhold/Code/mathlib4
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$here"
LEAN_NUM_THREADS=1 lake build frontendFormatter
prototype=$(lake -q query frontendFormatter --text)
prototype_path=$(lake env printenv LEAN_PATH)

cd "$repo"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)
oracle=(python3 tests/formatter/oracle.py --application "$application" --tests "$tests")

setup_and_path() {
  local root=$1 source=$2 setup=$3 path_file=$4
  (cd "$root" && lake setup-file "$source" >"$setup" && lake env printenv LEAN_PATH >"$path_file")
}

run_oracle() {
  local label=$1 root=$2 source=$3 module=$4 shape=$5 width=$6
  local setup="$work/$label.setup.json"
  local path_file="$work/$label.lean-path"
  setup_and_path "$root" "$source" "$setup" "$path_file"
  local lean_path
  lean_path=$(<"$path_file")
  "${oracle[@]}" --setup "$setup" --source "$root/$source" -- \
    env LEAN_PATH="$lean_path" "$prototype" "$shape" "$width" "$module" \
    >"$work/$label.$shape.json"
  python3 - "$label" "$shape" "$work/$label.$shape.json" <<'PY'
import json, sys
label, shape, path = sys.argv[1:]
result = json.load(open(path))
assert result["status"] == "ok" and result["unsupported"] == 0, result
assert result["changed"] in (0, 1), result
print(f"ok   {label:30} shape={shape:9} changed={result['changed']} "
      f"digest={result['digest']} bytes={result['outputBytes']}")
PY
}

printf -- '--- shape capability and width checks ---\n'
for shape in converted opaque; do
  for width in 40 100; do
    env LEAN_PATH="$prototype_path" "$prototype" "$shape" "$width" FormatterPrototype.Fixture \
      <"$here/fixtures/Prototype.lean" >"$work/synthetic.$shape.$width.candidate.json"
  done
done
python3 - "$work" <<'PY'
import hashlib, json, pathlib, sys
work = pathlib.Path(sys.argv[1])
rows = {}
for shape in ("converted", "opaque"):
    for width in (40, 100):
        result = json.load(open(work / f"synthetic.{shape}.{width}.candidate.json"))
        metrics = result["metrics"]
        assert metrics["formatterFailures"] == 0, metrics
        assert metrics["tagBoundaries"] > 0, metrics
        assert metrics["registryDocuments"] > 0, metrics
        if width == 40:
            assert metrics["changedCommands"] > 0, metrics
        if shape == "converted":
            assert metrics["convertedNodes"] == metrics["documentNodes"] > 0, metrics
        else:
            assert metrics["convertedNodes"] == 0 and metrics["coreOverrides"] > 0, metrics
        output = result["formatted"].encode()
        rows[shape, width] = output
        digest = hashlib.sha256(output).hexdigest()
        print(f"ok   synthetic metrics              shape={shape:9} width={width} digest={digest} {metrics}")
    assert rows[shape, 40] != rows[shape, 100], shape
assert rows["converted", 100] != rows["opaque", 100]
PY

run_oracle synthetic "$here" fixtures/Prototype.lean FormatterPrototype.Fixture converted 40
run_oracle synthetic "$here" fixtures/Prototype.lean FormatterPrototype.Fixture opaque 40

printf -- '--- lean-fmt modules ---\n'
for shape in converted opaque; do
  run_oracle leanfmt-doc "$repo" LeanFmt/Doc.lean LeanFmt.Doc "$shape" 80
  run_oracle leanfmt-analysis "$repo" LeanFmt/Analysis.lean LeanFmt.Analysis "$shape" 80
done

printf -- '--- current mathlib stratified sample ---\n'
for shape in converted opaque; do
  run_oracle mathlib-notation "$mathlib" Mathlib/FieldTheory/Galois/Notation.lean \
    Mathlib.FieldTheory.Galois.Notation "$shape" 80
  run_oracle mathlib-macro "$mathlib" Mathlib/Tactic/WithoutCDot.lean \
    Mathlib.Tactic.WithoutCDot "$shape" 80
  run_oracle mathlib-syntax "$mathlib" Mathlib/Logic/ExistsUnique.lean \
    Mathlib.Logic.ExistsUnique "$shape" 80
done

printf 'frontend-native formatter prototype passed\n'
