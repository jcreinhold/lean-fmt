#!/usr/bin/env bash
# Measurements behind RLC-SPEC's choice of layout model.
#
# Every check below asserts a declared outcome rather than printing a number for a human to admire.
# The design note frozen from this run says, among other things, that Lean's parser puts every
# comment in the *preceding* token's trailing trivia, that a mode-dependent separator is
# inexpressible in both rejected candidates, and that the textbook rendering algorithm is exponential
# in a strict language. If a toolchain bump changes any of those, this script fails instead of
# quietly rewriting the contract.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

failures=0
work=${1:-$(mktemp -d)}
mkdir -p "$work"

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == *"$expected"* ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n    expected to contain: %s\n    actual: %s\n' "$name" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

LEAN_NUM_THREADS=1 lake build >/dev/null

printf -- '--- comment ownership ---\n'
trivia=$(lake exe layout-probe trivia fixtures/Comments.lean)
printf '%s\n' "$trivia" >"$work/trivia.txt"
# The contract-deciding facts. `Syntax.updateLeading` is documented to split a token's trailing at
# the first newline so comments attach to the intuitively correct token; it has no caller in the
# 4.32 tree. If that ever changes, `nonempty_leading` stops being 0 and the split below becomes the
# parser's job instead of ours.
check "every comment is in a trailing run" "comment_in_leading=0" "$trivia"
check "no leaf carries leading trivia" "nonempty_leading=0" "$trivia"
check "trailing runs span newlines" "trailing_spans_newline=11" "$trivia"
check "parser does not split trivia" "verdict=trailing-greedy" "$trivia"
# Comments before the first command are header text. A module linter never receives the header, so
# these are not attachable by the layout engine at all.
check "header owns pre-command comments" "comment_bearing_header_leaves=1" "$trivia"

printf -- '--- expressiveness: mode-dependent separator ---\n'
express=$(lake exe layout-probe express)
printf '%s\n' "$express" >"$work/express.txt"
# Flat, all three agree. Broken, only a `line` that carries its own flat text drops the separator;
# `Std.Format.line` and Oppen's `Break` both emit blanks and strand the semicolon.
check "chosen model drops the separator when broken" \
  'wadler_bounded="do\n  act1\n  act2"' "$express"
check "oppen strands the separator" 'oppen="do\n  act1;\n  act2"' "$express"
check "Std.Format strands the separator too" 'std_format="do\n  act1;\n  act2"' "$express"

printf -- '--- fit: the two models are not distinguished by their break decisions ---\n'
fit=$(lake exe layout-probe fit)
printf '%s\n' "$fit" >"$work/fit.txt"
check "models agree at every margin" "margins_where_models_disagree=0" "$fit"

printf -- '--- width: a column is a codepoint, as in Lean core ---\n'
stdfmt=$(lake exe layout-probe stdfmt)
printf '%s\n' "$stdfmt" >"$work/stdfmt.txt"
# 6 codepoints, 12 terminal cells. Core keeps it flat at width 8, so core counts codepoints.
check "core counts codepoints, not cells" 'cjk_at_width_8="世界世界世界 x"' "$stdfmt"
check "one more codepoint than fits breaks" 'cjk_at_width_7="世界世界世界\nx"' "$stdfmt"
width=$(lake exe layout-probe width)
printf '%s\n' "$width" >"$work/width.txt"
# The same grapheme measures 1 column precomposed and 2 decomposed. Codepoint counting is not
# normalization-stable, and the note says so rather than implying the policy is exact.
check "codepoint width is not normalization-stable" "combining bytes=3 codepoints=2" "$width"
check "precomposed form of the same grapheme differs" "precomposed bytes=2 codepoints=1" "$width"

printf -- '--- complexity ---\n'
complexity=$(lake exe layout-probe complexity)
printf '%s\n' "$complexity" >"$work/complexity.txt"
# The textbook algorithm renders 180 bytes of output for 161006 steps at 20 sibling groups, growing
# by a factor of ~1.62 per group. The bounded renderer of the same algebra is 18n-1 steps.
check "textbook renderer is exponential in sibling groups" "textbook n=20 steps=161006" "$complexity"
check "bounded renderer is linear" "bounded n=100000 steps=1799999" "$complexity"
check "oppen is linear" "oppen n=100000 steps=1000000" "$complexity"
# Oppen's buffer is constant on sibling groups at every n, which is its whole advantage...
check "oppen buffer is bounded on sibling groups" "out_bytes=900000 peak_buffer=12" "$complexity"
# ...and it stays constant on nested groups too, at 100x the depth. The advantage is real, and the
# chosen model does not have it: a document tree is O(n) by construction. Candidate B is rejected on
# expressiveness (see `express` above), not on memory. Both nested fixtures must render byte-identical
# output or this comparison is measuring two different documents rather than two models.
check "oppen is linear on nested groups" "oppen n=10000 steps=110011" "$complexity"
check "oppen nested buffer does not grow with depth" "out_bytes=200050001 peak_buffer=32" "$complexity"
# The nested fixtures must be the same document in both models, or their sizes and times compare
# nothing. This caught a real defect: the Oppen stream originally omitted the closing `)`, rendered
# half the bytes, and reported a 2n buffer that vanished once the fixture matched.
nested_bytes=$(printf '%s\n' "$complexity" | sed -n '/nested groups/,$p' |
  grep -oE '(bounded|oppen) n=10000 .*out_bytes=[0-9]+' | grep -oE 'out_bytes=[0-9]+' | sort -u)
check "both models render the same nested document" "out_bytes=200050001" "$nested_bytes"
check "nested fixtures agree on exactly one size" "1" "$(printf '%s\n' "$nested_bytes" | grep -c .)"

printf -- '--- output assembly ---\n'
assemble=$(lake exe layout-probe assemble)
printf '%s\n' "$assemble" >"$work/assemble.txt"
check "append and join agree" "same=true" "$assemble"

printf 'evidence written to %s\n' "$work"
printf 'failures=%d\n' "$failures"
exit $((failures > 0 ? 1 : 0))
