#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
source_file="$repo_root/tests/compiler/LocalSyntax.lean"
plugin_source="$repo_root/LeanFmt/CompilerPlugin.lean"
rules_source="$repo_root/LeanFmt/Rules.lean"
olean="$repo_root/.lake/build/lib/lean/LocalSyntax.olean"
trace="$repo_root/.lake/build/lib/lean/LocalSyntax.trace"
broken_olean="$repo_root/.lake/build/lib/lean/Broken.olean"
artifact="$repo_root/.lake/build/lean-fmt-artifacts/LocalSyntax.json"
artifact_trace="$artifact.trace"
broken_artifact="$repo_root/.lake/build/lean-fmt-artifacts/Broken.json"
backup=$(mktemp)
fixture_backup=$(mktemp)
plugin_backup=$(mktemp)
rules_backup=$(mktemp)
shadow_dir=$(mktemp -d)
cache_dir=$(mktemp -d)
cache_log=$(mktemp)
cp "$source_file" "$backup"
cp "$plugin_source" "$plugin_backup"
cp "$rules_source" "$rules_backup"
cleanup() {
  cp "$backup" "$source_file"
  cp "$plugin_backup" "$plugin_source"
  cp "$rules_backup" "$rules_source"
  rm -f "$backup" "$fixture_backup"
  rm -f "$plugin_backup" "$rules_backup" "$cache_log"
  rm -rf "$shadow_dir" "$cache_dir"
}
trap cleanup EXIT

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "emit_local_command\n"
new = "emit_local_command  \n"
if source.count(old) != 1:
    raise SystemExit("trailing-whitespace fixture could not find its unique command")
path.write_text(source.replace(old, new))
PY
cp "$source_file" "$fixture_backup"

cd "$repo_root"
rm -f "$olean" "$trace" "$broken_olean" "$artifact" "$artifact_trace" "$artifact.hash" \
  "$broken_artifact" "$broken_artifact.trace" "$broken_artifact.hash"

verify_artifacts() {
  local expected_hash
  expected_hash=$(LEAN_NUM_THREADS=1 lake exe lean-fmt-tests print-lake-hash "$artifact")
  LEAN_NUM_THREADS=1 lake exe lean-fmt-tests \
    verify-plugin-artifact LocalSyntax tests/compiler/LocalSyntax.lean
  LEAN_NUM_THREADS=1 lake exe lean-fmt-tests \
    verify-facet-artifact "$artifact" tests/compiler/LocalSyntax.lean "$expected_hash"
}

LEAN_NUM_THREADS=1 lake -R build +LocalSyntax:leanFmtArtifact
verify_artifacts
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests verify-official-facet \
  . tests/compiler/LocalSyntax.lean

# The extractor must use the exact `.olean` returned by the facet even when ambient `LEAN_PATH`
# contains a different module with the same name first.
printf 'module\n\ndef shadow : Nat := 1\n' > "$shadow_dir/LocalSyntax.lean"
plugin=$(lake -q query LeanFmtCompilerPlugin:shared --text)
extractor=$(lake -q query artifactExtractor --text)
lean_bin=$(lake env which lean)
repo_lib="$repo_root/.lake/build/lib/lean"
(
  cd "$shadow_dir"
  LEAN_PATH="$repo_lib" "$lean_bin" --plugin="$plugin" \
    -o LocalSyntax.olean LocalSyntax.lean
)
LEAN_PATH="$shadow_dir:$repo_lib" "$extractor" LocalSyntax "$olean" "$shadow_dir/exact.json"
exact_hash=$(LEAN_NUM_THREADS=1 lake exe lean-fmt-tests print-lake-hash "$shadow_dir/exact.json")
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests verify-facet-artifact \
  "$shadow_dir/exact.json" tests/compiler/LocalSyntax.lean "$exact_hash"

enabled_trace=$(python3 -c \
  'import json; print(json.load(open(".lake/build/lib/lean/LocalSyntax.trace"))["depHash"])')
enabled_olean=$(shasum -a 256 "$olean" | cut -d' ' -f1)

# An up-to-date facet must continue to expose the payload embedded in the exact `.olean`.
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
verify_artifacts
test "$enabled_olean" = "$(shasum -a 256 "$olean" | cut -d' ' -f1)"

# The two probes below are a matched pair, and neither means anything alone.
#
# `notes/01-rule-facts.md` §3 measured what this file used to assert the opposite of: editing one
# rule's message text changed `LocalSyntax.olean`'s bytes and invalidated its Lake trace, because the
# plugin carried the rule engine into every integrated module's build graph. A rule's prose has no
# business in an `.olean`, so the first probe requires a rule edit to change *nothing* here.
#
# A passing "nothing changed" is worthless on its own — a harness that rebuilt no module at all would
# pass it. The second probe is the control: a real change inside the plugin's own closure must still
# invalidate the module through Lake's plugin dependency. Together they say the boundary is where it
# is claimed to be, rather than everywhere or nowhere.
LEAN_NUM_THREADS=1 lake -R build +LocalSyntax:leanFmtArtifact
python3 - "$rules_source" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = 'message := "trailing whitespace"'
new = 'message := "probe: trailing whitespace"'
if source.count(old) != 1:
    raise SystemExit("rule invalidation probe could not find its unique source marker")
path.write_text(source.replace(old, new))
PY
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
rules_trace=$(python3 -c \
  'import json; print(json.load(open(".lake/build/lib/lean/LocalSyntax.trace"))["depHash"])')
if [[ "$enabled_trace" != "$rules_trace" ]]; then
  printf 'editing a rule invalidated the owning Lake module trace\n' >&2
  exit 1
fi
if [[ "$enabled_olean" != "$(shasum -a 256 "$olean" | cut -d' ' -f1)" ]]; then
  printf 'editing a rule changed the compiled bytes of an unrelated module\n' >&2
  exit 1
fi
verify_artifacts
cp "$rules_backup" "$rules_source"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact

# The control: a real plugin binary change must invalidate the module job through Lake's plugin
# dependency, rather than through a formatter-maintained identity field.
python3 - "$plugin_source" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "private def produceArtifact"
new = 'private def invalidationProbe : String := "probe"\n\nprivate def produceArtifact'
if source.count(old) != 1:
    raise SystemExit("plugin invalidation probe could not find its unique source marker")
path.write_text(source.replace(old, new))
PY
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
plugin_trace=$(python3 -c \
  'import json; print(json.load(open(".lake/build/lib/lean/LocalSyntax.trace"))["depHash"])')
verify_artifacts
if [[ "$enabled_trace" == "$plugin_trace" ]]; then
  printf 'plugin change did not invalidate the owning Lake module trace\n' >&2
  exit 1
fi
cp "$plugin_backup" "$plugin_source"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact

# Source changes and corrupt output cannot survive the module boundary as apparent hits.
printf '\n-- source-invalidation-probe\n' >> "$source_file"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
verify_artifacts
cp "$fixture_backup" "$source_file"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact

# A corrupt declared facet output is an ordinary consumer miss. Removing its output and trace lets
# Lake reproduce it from the exact module-owned payload.
trusted_artifact_hash=$(LEAN_NUM_THREADS=1 lake exe lean-fmt-tests print-lake-hash "$artifact")
rm -f "$artifact"
printf '{"partial":' > "$artifact"
if LEAN_NUM_THREADS=1 lake exe lean-fmt-tests \
    verify-facet-artifact "$artifact" tests/compiler/LocalSyntax.lean \
    "$trusted_artifact_hash"; then
  printf 'corrupt facet artifact was accepted\n' >&2
  exit 1
fi
# The production consumer runs the registered job in no-build mode rather than trusting presence or
# launching an extractor. Corruption is a miss until the explicit facet prerequisite is rebuilt.
if LEAN_NUM_THREADS=1 lake exe lean-fmt-tests verify-official-facet \
    . tests/compiler/LocalSyntax.lean; then
  printf 'corrupt official facet was consumed without an explicit rebuild\n' >&2
  exit 1
fi
rm -f "$artifact" "$artifact_trace" "$artifact.hash"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests verify-official-facet \
  . tests/compiler/LocalSyntax.lean
verify_artifacts

rm -f "$olean"
printf 'corrupt' > "$olean"
if LEAN_NUM_THREADS=1 lake exe lean-fmt-tests \
    verify-plugin-artifact LocalSyntax tests/compiler/LocalSyntax.lean; then
  printf 'corrupt module artifact was accepted\n' >&2
  exit 1
fi
rm -f "$olean" "$trace"
LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact
verify_artifacts

# The facet is genuinely cacheable: with an isolated writable Lake cache, deleting only the local
# output restores the declared JSON artifact without rerunning the extractor.
rm -f "$artifact" "$artifact_trace" "$artifact.hash"
LAKE_CACHE_DIR="$cache_dir" LAKE_ARTIFACT_CACHE=true LEAN_NUM_THREADS=1 \
  lake build +LocalSyntax:leanFmtArtifact
rm -f "$artifact" "$artifact.hash"
LAKE_CACHE_DIR="$cache_dir" LAKE_ARTIFACT_CACHE=true LEAN_NUM_THREADS=1 \
  lake -v build +LocalSyntax:leanFmtArtifact >"$cache_log" 2>&1
if ! grep -q 'found artifact in cache:' "$cache_log" ||
    ! grep -q 'restored artifact from cache to:' "$cache_log" ||
    ! grep -q 'Replayed .*LocalSyntax:leanFmtArtifact' "$cache_log" ||
    grep -q 'Built .*LocalSyntax:leanFmtArtifact' "$cache_log"; then
  printf 'Lake did not restore the declared facet artifact from its isolated cache\n' >&2
  cat "$cache_log" >&2
  exit 1
fi
verify_artifacts

# Failed elaboration cannot create an `.olean`, so it cannot publish a formatter payload.
rm -f "$broken_olean" "$repo_root/.lake/build/lib/lean/Broken.trace"
if LEAN_NUM_THREADS=1 lake build +Broken:leanFmtArtifact; then
  printf 'broken module unexpectedly published a lean-fmt module artifact\n' >&2
  exit 1
fi
if [[ -e "$broken_olean" ]]; then
  printf 'failed compiler published a lean-fmt module artifact\n' >&2
  exit 1
fi
if [[ -e "$broken_artifact" ]]; then
  printf 'failed compiler published a lean-fmt facet artifact\n' >&2
  exit 1
fi

printf 'lean-fmt compiler facet tests passed\n'
