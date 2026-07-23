#!/usr/bin/env bash
set -euo pipefail

# One-run whole-module draft: region tiling, terminal/tail, normalized line endings, exact setup, and
# deterministic counters. Structural admission belongs to tests/formatter and Prompt 09.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$repo_root"

LEAN_NUM_THREADS=1 lake build lean-fmt FormatterAdapterFixtures CompilerFixtures
application=$(lake -q query lean-fmt --text)

analyze() {
  local setup=$1 source=$2 output=$3 mode=${4:-draft}
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$setup" "$source" "$source" 8589934592 "$mode" >"$output"
}

cat >"$work/Terminal.lean" <<'LEAN'
module

import AdapterSyntax

open AdapterSyntax

descriptor_command beforeExit := twice(1)

-- terminal-leading payload
#exit
verbatim tail λ that must not be parsed
LEAN
LEAN_NUM_THREADS=1 lake setup-file "$work/Terminal.lean" >"$work/terminal-setup.json"
analyze "$work/terminal-setup.json" "$work/Terminal.lean" "$work/terminal-a.json" draft:72
analyze "$work/terminal-setup.json" "$work/Terminal.lean" "$work/terminal-b.json" draft:72

python3 - "$work/Terminal.lean" "$work/terminal-a.json" "$work/terminal-b.json" <<'PY'
import json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes().replace(b"\r\n", b"\n")
left, right = (json.load(open(path)) for path in sys.argv[2:])
assert left["formatDraft"] == right["formatDraft"], "draft or metrics are nondeterministic"
draft = left["formatDraft"]
assert draft["metrics"]["frontendRuns"] == 1, draft
assert draft["metrics"]["registryDocuments"] == 0, draft
assert draft["metrics"]["descriptorDocuments"] == 1, draft
assert draft["metrics"]["registryNodes"] >= draft["metrics"]["registryDocuments"], draft
assert draft["terminalStop"] < draft["sourceBytes"], draft
tail = raw[draft["terminalStop"]:]
assert tail.startswith(b"#exit") and draft["text"].encode().endswith(tail), (tail, draft["text"])

source_cursor = output_cursor = 0
for mark in draft["sourceMap"]:
    assert mark["source"]["start"] == source_cursor, mark
    assert mark["output"]["start"] == output_cursor, mark
    source_cursor = mark["source"]["stop"]
    output_cursor = mark["output"]["stop"]
assert source_cursor == len(raw) == draft["sourceBytes"], draft
assert output_cursor == len(draft["text"].encode()), draft
assert draft["text"].startswith("module\nimport AdapterSyntax\n\n"), draft
assert "ident:AdapterSyntax" in draft["headerContract"], draft
print("  ok   deterministic header/command/tail draft tiles source and output")
PY

printf 'module\n\n#exit\nterminal-only tail\n' >"$work/OnlyExit.lean"
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed-setup.json"
analyze "$work/borrowed-setup.json" "$work/OnlyExit.lean" "$work/only-exit.json"
python3 - "$work/OnlyExit.lean" "$work/only-exit.json" <<'PY'
import json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
draft = json.load(open(sys.argv[2]))["formatDraft"]
assert draft["metrics"]["commands"] == 0, draft
assert draft["headerStop"] == draft["terminalStop"] == source.index("#exit"), draft
assert draft["text"] == source and len(draft["sourceMap"]) == 2, draft
print("  ok   terminal-only module has disjoint header and verbatim tail")
PY

cat >"$work/LineEnd.lean" <<'LEAN'
module

def finalLine := List.map (fun value => value + 1) [1, 2, 3, 4, 5, 6]
LEAN
python3 - "$work/LineEnd.lean" "$work/NoFinal.lean" "$work/CRLF.lean" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(text.rstrip("\n"))
pathlib.Path(sys.argv[3]).write_bytes(text.replace("\n", "\r\n").encode())
PY
LEAN_NUM_THREADS=1 lake setup-file "$work/LineEnd.lean" >"$work/line-setup.json"
for name in LineEnd NoFinal CRLF; do
  analyze "$work/line-setup.json" "$work/$name.lean" "$work/$name.json" draft:40
done
python3 - "$work/LineEnd.json" "$work/NoFinal.json" "$work/CRLF.json" <<'PY'
import json, sys
lf, nofinal, crlf = (json.load(open(path))["formatDraft"] for path in sys.argv[1:])
assert lf["text"].endswith("\n") and not nofinal["text"].endswith("\n"), (lf, nofinal)
assert lf == crlf, "CRLF and LF did not produce the same normalized draft"
print("  ok   final-newline convention is preserved and CRLF normalizes identically")
PY

# The module belongs to a plugin-enabled Lake target and contains a real `choice` node plus imported
# custom notation, doc comments, nested comments, and Unicode.
LEAN_NUM_THREADS=1 lake setup-file tests/compiler/LocalSyntax.lean >"$work/plugin-setup.json"
analyze "$work/plugin-setup.json" tests/compiler/LocalSyntax.lean "$work/plugin.json"
python3 - "$work/plugin.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1]))
draft = envelope["formatDraft"]
assert envelope.get("formatFailure") is None and not envelope["diagnostics"], envelope
assert draft["metrics"]["commands"] == 8, draft
assert draft["metrics"]["coreDocuments"] + draft["metrics"]["registryDocuments"] == 9, draft
assert draft["metrics"]["registryNodes"] >= draft["metrics"]["commands"], draft
assert draft["metrics"]["commentOwners"] == 6, draft
assert "emit_local_command" in draft["text"] and "an identifier with spaces" in draft["text"], draft["text"]
print("  ok   plugin setup, imported syntax, choice, comments, and Unicode format in one frontend")
PY

# Broken headers and unresolved imports are frontend refusals, never format drafts.
printf 'module\nimport\n' >"$work/Malformed.lean"
printf 'module\n\nimport Definitely.Does.Not.Exist\n' >"$work/Unresolved.lean"
for name in Malformed Unresolved; do
  analyze "$work/borrowed-setup.json" "$work/$name.lean" "$work/$name.json"
done
python3 - "$work/Malformed.json" "$work/Unresolved.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    envelope = json.load(open(path))
    assert envelope.get("formatDraft") is None and envelope.get("artifact") is None, envelope
    assert envelope["diagnostics"], envelope
print("  ok   malformed header and unresolved import produce diagnostics without drafts")
PY

printf 'tests/module-formatter: ok\n'
