#!/usr/bin/env bash
set -euo pipefail

# `ruff-14` RSF-IMPL — the stdin/stdout and range surface.
#
# Every case drives the real executable through a pipe, because the thing under test *is* the pipe
# behavior: what reaches stdout, what reaches stderr, what the exit code is, and what is NOT written.
# The frozen contract is `docs/projects/ruff-14-stream-range/notes/01-stream-range.md`; section
# numbers below refer to it.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
work=$(mktemp -d)
# The identity used by most cases. It names a path that does NOT exist: a buffer an editor has never
# saved is the case `--stdin-filename` exists for, and `Project.unsavedTarget` must not read it.
identity="tests/stream/Unsaved.lean"
# A real, tracked file used once, to prove naming an existing path does not write it.
witness="$repo_root/tests/check/Layout.lean"
cleanup() { rm -rf "$work" "$repo_root/.lean-fmt-cache"; }
trap cleanup EXIT

failures=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }

fmt() { lake exe lean-fmt "$@"; }

# A buffer with one layout defect (`namespace␣␣␣␣␣Alpha`) in its own command, and a second command
# after it. Two commands is the minimum that can show a range leaving the other one alone.
dirty="$work/dirty.lean"
printf 'module\n\nimport LeanFmt.Basic\n\nnamespace     Alpha\n\ndef  x   :=   1\n\nend Alpha\n' > "$dirty"

printf -- '--- usage rejections (§2) ---\n'
run_err() { fmt "$@" < "$dirty" 2>&1 >/dev/null | head -1; }
code()    { set +e; fmt "$@" < "$dirty" >/dev/null 2>&1; printf '%s' "$?"; set -e; }

check "- without --stdin-filename is rejected" \
  "$(run_err format -)" "stdin requires --stdin-filename to establish project identity"
check "  ... with exit 2" "$(code format -)" "2"
check "--stdin-filename without - is rejected" \
  "$(run_err format --stdin-filename "$identity")" "--stdin-filename is valid only with the - stdin target"
check "--range without - is rejected" \
  "$(run_err format --range 0:10)" "--range is valid only with the - stdin target"
check "--range-lines names the flag the caller typed" \
  "$(run_err format --range-lines 1:1-2:1)" "--range-lines is valid only with the - stdin target"
check "- alongside another target is rejected" \
  "$(run_err format - --stdin-filename "$identity" other.lean)" "- must be the only target"
check "a malformed --range is rejected" \
  "$(run_err format - --stdin-filename "$identity" --range bogus)" \
  "--range expects START:STOP byte offsets, got: bogus"
check "a reversed --range is rejected" \
  "$(run_err format - --stdin-filename "$identity" --range 40:10)" \
  "--range start 40 is past its stop 10"
check "a --range past the end is rejected" \
  "$(run_err format - --stdin-filename "$identity" --range 0:99999)" \
  "--range stop 99999 is past the end of the received source (78 bytes)"

printf -- '--- identity gates, naming the caller'"'"'s own argument (§2) ---\n'
# Gate 1 (`.lake`) is not liftable by the stdin form any more than by a file argument: `ruff-13` closed
# that as a write-safety defect and arriving through a pipe must not reopen it.
check "a path outside the root is rejected" \
  "$(run_err format - --stdin-filename ../evil.lean)" \
  "lean-fmt: selected file is outside the project root: ../evil.lean"
check "a path inside .lake is rejected" \
  "$(run_err format - --stdin-filename .lake/build/x.lean)" \
  "lean-fmt: selected file is inside the Lake build directory: .lake/build/x.lean"
check "a non-Lean path is rejected" \
  "$(run_err format - --stdin-filename notes.txt)" \
  "lean-fmt: selected file is not a Lean source: notes.txt"

printf -- '--- format streams, and writes nothing (§7) ---\n'
formatted=$(fmt format - --stdin-filename "$identity" < "$dirty")
check "format canonicalizes the buffer" \
  "$(printf '%s' "$formatted" | sed -n '5p')" "namespace Alpha"
check "format - exits 0 having streamed (§6)" "$(code format - --stdin-filename "$identity")" "0"

# Naming a real file must not write it, and no run may leave a persistent cache entry behind.
rm -rf "$repo_root/.lean-fmt-cache"
before=$(shasum "$witness" | cut -d' ' -f1)
fmt format - --stdin-filename tests/check/Layout.lean < "$dirty" > /dev/null
after=$(shasum "$witness" | cut -d' ' -f1)
check "naming an existing file does not write it" "$before" "$after"
if [[ -d "$repo_root/.lean-fmt-cache" ]]; then
  fail "a stdin run created a persistent cache directory"
else
  ok "a stdin run creates no persistent cache entry"
fi

printf -- '--- the other modes (§6) ---\n'
check "check - is silent on stdout" "$(fmt check - --stdin-filename "$identity" < "$dirty" | wc -c | tr -d ' ')" "0"
check "diff - emits a unified diff" \
  "$(fmt diff - --stdin-filename "$identity" < "$dirty" 2>/dev/null | head -1)" "--- a/$identity"
check "diff - exits 1 when it would change (CI code)" \
  "$(code diff - --stdin-filename "$identity")" "1"
check "format --check - is silent on stdout" \
  "$(fmt format --check - --stdin-filename "$identity" < "$dirty" 2>/dev/null | wc -c | tr -d ' ')" "0"
check "format --check - exits 1 when it would change" \
  "$(code format --check - --stdin-filename "$identity" --check)" "1"

# A buffer that does not elaborate streams NOTHING -- not partial bytes, not the input echoed back.
# Echoing would let a shell redirect write a broken buffer over a good file.
broken="$work/broken.lean"
printf 'module\n\ndef x : Nat := "not a nat"\n' > "$broken"
set +e
fmt format - --stdin-filename "$identity" < "$broken" > "$work/broken.out" 2> "$work/broken.err"
broken_code=$?
set -e
check "a broken buffer streams zero bytes" "$(wc -c < "$work/broken.out" | tr -d ' ')" "0"
check "a broken buffer exits 1" "$broken_code" "1"
check "a broken buffer says why on stderr" \
  "$(grep -c 'broken' "$work/broken.err")" "1"

printf -- '--- range expansion (§4) ---\n'
# `namespace     Alpha` occupies bytes 30..49; its layout *unit* runs to 51 (the extent owns the
# trailing trivia through the blank line, §4.3), so the reported actual range is wider than asked.
ranged=$(fmt format - --stdin-filename "$identity" --range 30:49 < "$dirty" 2>/dev/null)
check "a range formats its own unit" "$(printf '%s' "$ranged" | sed -n '5p')" "namespace Alpha"
check "a range leaves the other command's bytes alone" \
  "$(printf '%s' "$ranged" | sed -n '7p')" "def  x   :=   1"
check "the reported actual range is the unit, not the request" \
  "$(fmt format - --stdin-filename "$identity" --range 30:49 < "$dirty" 2>&1 >/dev/null | tail -1)" \
  "$identity: formatted range 30-51"

# Whole-file and full-range must be the same bytes -- the roadmap's equivalence contract.
full=$(fmt format - --stdin-filename "$identity" --range 0:78 < "$dirty" 2>/dev/null)
check "full range == whole file" "$full" "$formatted"

# Idempotence, stated in the only coordinates where it can be true.
#
# Re-running the *requested* range over the output is NOT a fixed point and must not be asserted to
# be: formatting the unit changed its length, so byte 30:49 of the output names a different region
# than it named in the input -- here it reaches into the next command and formats that too. The freeze
# says so (§5), and the first draft of this suite asserted the false version and failed.
#
# What is a fixed point is re-running the range the unit *now* occupies, which is exactly what the
# source map's `output` range reports and exactly what an editor holding that map would send back.
map=$(fmt format - --stdin-filename "$identity" --range 30:49 --json < "$dirty" 2>/dev/null)
out_start=$(printf '%s' "$map" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sourceMap"][0]["output"]["start"])')
out_stop=$(printf '%s' "$map" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sourceMap"][0]["output"]["stop"])')
again=$(printf '%s' "$ranged" | fmt format - --stdin-filename "$identity" --range "$out_start:$out_stop" 2>/dev/null)
check "range formatting is idempotent in output coordinates" "$again" "$ranged"

printf -- '--- encodings (§3, §5) ---\n'
# Positions are codepoints, not bytes: line 3 is `namespace     αβγ`, 17 codepoints over 20 bytes.
utf8="$work/utf8.lean"
printf 'module\n\nnamespace     αβγ\n\nend αβγ\n' > "$utf8"
check "a codepoint column resolves past multibyte text" \
  "$(fmt format - --stdin-filename "$identity" --range-lines 3:1-3:18 --json < "$utf8" 2>/dev/null \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["requestedRange"]["stop"])')" "28"
check "the multibyte buffer still formats" \
  "$(fmt format - --stdin-filename "$identity" --range-lines 3:1-3:18 < "$utf8" 2>/dev/null | sed -n '3p')" \
  "namespace αβγ"

# A CRLF buffer streams back CRLF: positions index the normalized text, output is denormalized.
crlf="$work/crlf.lean"
printf 'module\r\n\r\nnamespace     Alpha\r\n\r\nend Alpha\r\n' > "$crlf"
check "a CRLF buffer round-trips its line endings" \
  "$(fmt format - --stdin-filename "$identity" < "$crlf" | od -c | grep -c '\\r')" \
  "$(fmt format - --stdin-filename "$identity" < "$crlf" | od -c | grep -c '\\r')"
if fmt format - --stdin-filename "$identity" < "$crlf" | grep -q $'\r'; then
  ok "a CRLF buffer streams back CRLF"
else
  fail "a CRLF buffer lost its line endings"
fi

printf -- '--- json (§5.1) ---\n'
json=$(fmt format - --stdin-filename "$identity" --range 30:49 --json < "$dirty" 2>/dev/null)
check "json carries the schema" \
  "$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')" \
  "lean-fmt.stream.v1"
check "json carries the bytes, so a consumer needs one run" \
  "$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["formatted"].splitlines()[4])')" \
  "namespace Alpha"
check "json carries the source map" \
  "$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sourceMap"]))')" "1"
check "the source map indexes the streamed text" \
  "$(printf '%s' "$json" | python3 -c '
import json,sys
d = json.load(sys.stdin)
m = d["sourceMap"][0]["output"]
print(d["formatted"].encode()[m["start"]:m["stop"]].decode().strip())')" \
  "namespace Alpha"

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ "$failures" -eq 0 ]]
