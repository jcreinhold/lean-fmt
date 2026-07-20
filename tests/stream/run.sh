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

###############################################################################
# `ruff-14` RSF-FINAL — boundary stability and pipeline behavior.
#
# Everything above characterizes the surface RSF-IMPL shipped. What follows is the acceptance pass:
# the cases the freeze names and the result note admitted were unfixtured -- the forward extension on
# real source, `normalizeEof` at the tail, custom syntax, the `#exit` tail, header-only ranges, empty
# ranges, comment ownership at a boundary, nested nodes, and what happens when the pipe on the other
# end goes away.
###############################################################################

units() {  # unit lattice of a buffer, as "start-stop start-stop ..." over the *source*
  fmt format - --stdin-filename "$identity" --json < "$1" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join("%d-%d" % (m["source"]["start"], m["source"]["stop"]) for m in d["sourceMap"]))'
}
actual() { fmt format - --stdin-filename "$identity" "$@" 2>&1 >/dev/null | tail -1; }

printf -- '--- the forward extension, on source rather than on a Doc probe (§4) ---\n'
# The clause exists because `Doc.fits` walks the *tail* of the work list: a unit that does not end at
# a line boundary can be rebroken by whatever follows, so a range stopping there must keep extending
# or it rewrites bytes it reported as untouched. RSF-IMPL measured that on a synthetic `Doc` and
# pinned it with a selection test; this is the same clause firing on two real commands sharing a line.
pair="$work/pair.lean"
printf 'module\n\ndef a := 1 def b := 2\n' > "$pair"     # 30 bytes; units 0-8, 8-19, 19-30, 30-30
check "two commands on one line are two units" "$(units "$pair")" "0-8 8-19 19-30 30-30"
check "a range over the first extends through the second" \
  "$(actual --range 8:18 < "$pair")" "$identity: formatted range 8-30"
# And the reason it must: the first unit's rendered bytes end in a space, not a newline.
check "the first unit does not end at a line boundary" \
  "$(fmt format - --stdin-filename "$identity" --json < "$pair" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d["sourceMap"][1]["output"]
print(repr(d["formatted"].encode()[m["stop"] - 1 : m["stop"]].decode()))')" "' '"

printf -- '--- normalizeEof at the tail (§5) ---\n'
# A buffer with no final newline, ranged over its last unit: `normalizeEof` applies only when the
# selection includes the tail, and here it does, so the streamed slice gains the newline.
nonl="$work/nonl.lean"
printf 'module\n\ndef  x   :=   1' > "$nonl"             # 23 bytes, no trailing newline
check "a range over the last unit of a newline-less buffer ends in a newline" \
  "$(fmt format - --stdin-filename "$identity" --range 8:23 < "$nonl" 2>/dev/null \
     | python3 -c 'import sys; print(repr(sys.stdin.buffer.read()))')" \
  "b'module\\n\\ndef x   :=   1\\n'"

printf -- '--- custom syntax and the #exit tail (§4) ---\n'
# The exactness property a range must not break: syntax declared by a command *outside* the range is
# still in scope for the command inside it, because the whole buffer is analyzed and only the slice is
# emitted. Format the user of a notation without formatting its declaration.
syn="$work/syn.lean"
printf 'module\n\nnotation:65 lhs:65 " \xe2\x8a\x95 " rhs:66 => Nat.add lhs rhs\n\ndef  total   :=   1 \xe2\x8a\x95 2\n\ndef  other   :=   3\n' > "$syn"
ranged_syn=$(fmt format - --stdin-filename "$identity" --range-lines 5:1-5:20 < "$syn" 2>/dev/null)
check "a range over a notation's user keeps the notation" \
  "$(printf '%s' "$ranged_syn" | sed -n '5p')" "def total   :=   1 ⊕ 2"
check "  ... and leaves the command after it alone" \
  "$(printf '%s' "$ranged_syn" | sed -n '7p')" "def  other   :=   3"

# `#exit` never enters the command stream, so the modelled region ends where the terminal *begins* and
# the rest is one verbatim tail unit -- including text that is not Lean at all.
terminal="$work/exit.lean"
printf 'module\n\ndef  x   :=   1\n\n#exit\n\nthis is not lean at all\n' > "$terminal"   # 56 bytes
check "the tail unit begins at #exit" "$(units "$terminal")" "0-8 8-25 25-56"
check "the tail streams back verbatim" \
  "$(fmt format - --stdin-filename "$identity" < "$terminal" 2>/dev/null | tail -1)" \
  "this is not lean at all"

printf -- '--- header-only, empty, and nested ranges (§4) ---\n'
hdr="$work/hdr.lean"
printf 'module\n\nimport   LeanFmt.Basic\nimport LeanFmt.Doc\n\ndef  x   :=   1\n' > "$hdr"
check "a range inside the header selects the whole header" \
  "$(actual --range 0:20 < "$hdr")" "$identity: formatted range 0-51"
header_ranged=$(fmt format - --stdin-filename "$identity" --range 0:20 < "$hdr" 2>/dev/null)
check "  ... and formats the imports" "$(printf '%s' "$header_ranged" | sed -n '3p')" "import LeanFmt.Basic"
check "  ... without touching the body" "$(printf '%s' "$header_ranged" | sed -n '6p')" "def  x   :=   1"

# An empty range is a cursor: it selects the one unit that contains the position.
check "an empty range selects the unit containing it" \
  "$(actual --range 30:30 < "$dirty")" "$identity: formatted range 30-51"

# The lattice is command-granular by construction, so a request naming six bytes deep inside a
# structure instance widens to the enclosing command -- there is no finer unit to select.
nest="$work/nest.lean"
printf 'module\n\nstructure Point where\n  x : Nat\n  y : Nat\n\ndef  origin   : Point   :=   { x := 0, y := 0 }\n' > "$nest"
check "a range inside a nested node widens to its command" \
  "$(actual --range 82:88 < "$nest")" "$identity: formatted range 51-99"

printf -- '--- comment ownership at an extent boundary (§4.3) ---\n'
# Trailing-greedy: a comment written *above* a declaration is in the *earlier* command's extent. This
# is the frozen `RLC-SPEC` verdict (`nonempty_leading=0`) and it surprises people, so it is asserted
# rather than left to be rediscovered. It is extent ownership, not the finer `Comments.partitions`
# attachment `tests/layout/run.sh` reports as `own-line comments lead the next token`; both hold.
cmt="$work/cmt.lean"
printf 'module\n\ndef  a   :=   1\n\n-- a comment written above b\ndef  b   :=   2\n' > "$cmt"
check "the comment above b belongs to a's unit" "$(units "$cmt")" "0-8 8-54 54-70 70-70"

printf -- '--- pipes and a stdout that goes away (§6) ---\n'
# Chaining the tool through itself is a fixed point: the second run receives canonical bytes.
once="$work/once.lean"; twice="$work/twice.lean"
fmt format - --stdin-filename "$identity" < "$nest" 2>/dev/null > "$once"
fmt format - --stdin-filename "$identity" < "$once" 2>/dev/null > "$twice"
if cmp -s "$once" "$twice"; then ok "format - piped into itself is a fixed point"; else fail "piping format - into itself changed the bytes"; fi

# A reader that exits before the writer finishes. The buffer is large enough that the write cannot
# fit in the pipe buffer, so the failure is real rather than lucky. The contract is that this is an
# infrastructure failure (exit 2, §6) reported on stderr -- not a crash, and not a silent 0 that would
# tell a caller its bytes were delivered when they were not.
big="$work/big.lean"
{ printf 'module\n\n'; for i in $(seq 0 20000); do printf 'def  x%s   :=   %s\n\n' "$i" "$i"; done; } > "$big"
set +e
fmt format - --stdin-filename "$identity" < "$big" 2> "$work/pipe.err" | { read -r _ignored; exit 0; }
pipe_code=${PIPESTATUS[0]}
set -e
check "a stdout that goes away is exit 2, not a crash" "$pipe_code" "2"
check "  ... and says so on stderr" \
  "$(grep -c 'broken pipe' "$work/pipe.err")" "1"

# §6 fixes this wording; without an explicit decode it would be the Lean runtime's incidental phrasing.
printf 'module\n\ndef x := \xff\xfe\n' > "$work/binary.lean"
check "invalid UTF-8 on stdin is rejected with the frozen message" \
  "$(fmt format - --stdin-filename "$identity" < "$work/binary.lean" 2>&1 >/dev/null | head -1)" \
  "lean-fmt: stdin is not valid UTF-8"
check "  ... with exit 2" \
  "$(set +e; fmt format - --stdin-filename "$identity" < "$work/binary.lean" >/dev/null 2>&1; printf '%s' "$?")" "2"

printf -- '--- fix - streams like format - (§6) ---\n'
check "fix - exits 0 having streamed" \
  "$(code fix - --stdin-filename "$identity")" "0"
# `fix` publishes admitted rule fixes at *original* coordinates; it is not `format`, and a buffer with
# no admitted fix streams back unchanged. Asserting the canonical layout here would be asserting the
# wrong operation -- the first draft did, and this is what it actually does.
check "fix - streams the buffer at original coordinates" \
  "$(fmt fix - --stdin-filename "$identity" < "$dirty" 2>/dev/null | sed -n '5p')" "namespace     Alpha"

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ "$failures" -eq 0 ]]
