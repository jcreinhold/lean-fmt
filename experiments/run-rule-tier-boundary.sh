#!/usr/bin/env bash
# RRE-SPEC, re-asked of the product RRE-IMPL built.
#
# The original script (commit 5d037d0, output in `evidence/01` and `evidence/02`) asked two questions
# and got two bad answers:
#
#   1. Rule enablement had two spellings — `--ignore FMT001` (a `RulePlan` projection) and
#      `leanFmt.trailingWhitespace=false` (a traced Lean option baked into the module artifact).
#      They did not agree: with the option off, `check` REPORTED FMT001 and `format` suppressed it.
#   2. `LeanFmt/CompilerPlugin.lean` imported `LeanFmt.Rules`, so editing one rule's message text
#      changed the compiled bytes of an unrelated module's `.olean` and invalidated its Lake trace.
#
# Both had one cause: the artifact carried *findings* rather than *facts*. RRE-IMPL deleted the
# option (there is now one spelling) and cut `LeanFmt.Rules` out of the plugin's import graph and its
# Lake library. This script asks the same two questions of the result. Question 1's second spelling
# no longer exists to disagree, so what is checked instead is that the one remaining spelling agrees
# with itself across both modes — the property `evidence/01` showed the product lacked.
#
# This script mutates `tests/compiler/LocalSyntax.lean` and `LeanFmt/Rules.lean` and restores both
# on exit, exactly as `tests/compiler/run.sh` does. It writes no evidence file; capture stdout.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
fixture="$repo_root/tests/compiler/LocalSyntax.lean"
rules="$repo_root/LeanFmt/Rules.lean"
olean="$repo_root/.lake/build/lib/lean/LocalSyntax.olean"
cache_root="$repo_root/.lean-fmt-cache"

fixture_backup=$(mktemp)
rules_backup=$(mktemp)
cp "$fixture" "$fixture_backup"
cp "$rules" "$rules_backup"
cleanup() {
  cp "$fixture_backup" "$fixture"
  cp "$rules_backup" "$rules"
  rm -f "$fixture_backup" "$rules_backup"
  rm -rf "$cache_root"
  cd "$repo_root"
  LEAN_NUM_THREADS=1 lake build lean-fmt +LocalSyntax:leanFmtArtifact >/dev/null 2>&1 || true
}
trap cleanup EXIT
cd "$repo_root"

# The same unique-command mutation `tests/compiler/run.sh` uses to give the fixture one FMT001.
add_trailing_whitespace() {
  python3 - "$fixture" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old, new = "emit_local_command\n", "emit_local_command  \n"
if source.count(old) != 1:
    raise SystemExit("trailing-whitespace fixture could not find its unique command")
path.write_text(source.replace(old, new))
PY
}

summarize() {
  python3 -c '
import json, sys
report = json.load(sys.stdin)
file = report["files"][0]
print("  findings=%s status=%-13s codes=%s"
      % (report["findings"], file["status"], [f["code"] for f in file["findings"]]))
'
}

echo "commit=$(git -C "$repo_root" rev-parse --short HEAD)  toolchain=$(cat "$repo_root/lean-toolchain")"
echo

echo '=== 1. how many spellings of "turn FMT001 off" are there? ==='
echo '$ grep -rn "leanFmt.trailingWhitespace\|trailingWhitespaceEnabled" LeanFmt lakefile.lean'
grep -rn 'leanFmt\.trailingWhitespace\|trailingWhitespaceEnabled' LeanFmt lakefile.lean ||
  echo '  (no match: the traced-option spelling is gone; `--ignore` is the only one left)'
add_trailing_whitespace
LEAN_NUM_THREADS=1 lake -R build lean-fmt +LocalSyntax:leanFmtArtifact >/dev/null 2>&1
echo
echo '--- the one remaining spelling must agree with itself across modes'
for mode in check format; do
  rm -rf "$cache_root"
  echo "\$ lean-fmt $mode --no-cache --json tests/compiler/LocalSyntax.lean"
  LEAN_NUM_THREADS=1 lake exe lean-fmt "$mode" --no-cache --json \
    tests/compiler/LocalSyntax.lean | summarize || true
  rm -rf "$cache_root"
  echo "\$ lean-fmt $mode --no-cache --json --ignore FMT001 tests/compiler/LocalSyntax.lean"
  LEAN_NUM_THREADS=1 lake exe lean-fmt "$mode" --no-cache --json --ignore FMT001 \
    tests/compiler/LocalSyntax.lean | summarize || true
done

echo
echo "=== 2. is one rule's message text in every module's compiled bytes? ==="
echo '$ grep -n "^import" LeanFmt/CompilerPlugin.lean'
grep -n '^import' LeanFmt/CompilerPlugin.lean
LEAN_NUM_THREADS=1 lake -R build +LocalSyntax:leanFmtArtifact >/dev/null 2>&1
before=$(shasum -a 256 "$olean" | cut -d' ' -f1)
before_trace=$(python3 -c \
  'import json; print(json.load(open(".lake/build/lib/lean/LocalSyntax.trace"))["depHash"])')
echo "LocalSyntax.olean      before = $before"
echo "LocalSyntax.trace hash before = $before_trace"

python3 - "$rules" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old, new = 'message := "trailing whitespace"', 'message := "trailing whitespace "'
if source.count(old) != 1:
    raise SystemExit("could not find the unique FMT001 message")
path.write_text(source.replace(old, new))
PY
echo '# edited only FMT001'"'"'s message string in LeanFmt/Rules.lean -- one space, no other change'

LEAN_NUM_THREADS=1 lake build +LocalSyntax:leanFmtArtifact >/dev/null 2>&1
after=$(shasum -a 256 "$olean" | cut -d' ' -f1)
after_trace=$(python3 -c \
  'import json; print(json.load(open(".lake/build/lib/lean/LocalSyntax.trace"))["depHash"])')
echo "LocalSyntax.olean      after  = $after"
echo "LocalSyntax.trace hash after  = $after_trace"
echo
[[ $before_trace != "$after_trace" ]] &&
  echo "trace:  INVALIDATED -- the module is re-elaborated" ||
  echo "trace:  unchanged -- editing a rule does not rebuild the target project"
[[ $before != "$after" ]] &&
  echo "olean:  BYTES CHANGED -- the rule's message is inside an unrelated module's .olean" ||
  echo "olean:  bytes unchanged -- the rule's message is not in the module's compiled bytes"

# A rule edit changing nothing is only meaningful next to a projection edit changing something;
# `tests/compiler/run.sh` runs that control as a permanent gate.
