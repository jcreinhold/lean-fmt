#!/usr/bin/env bash
set -euo pipefail

# The native grammar adapter's four invariant families, one declared fixture module each:
#
#   Alignment.lean   positional terminal alignment -- repeated spellings, multibyte columns, and
#                    literal bases whose source spelling the formatter is free to change
#   Boundaries.lean  comment ownership at every boundary the adapter distinguishes
#   Islands.lean     typed exact islands -- multiline payloads, interpolation, quotation
#   Offside.lean     parser-significant columns native layout alone does not preserve
#
# They are declared modules (`lean_lib NativeLayoutFixtures`) rather than generated buffers, so each
# reaches the adapter through the same exact Lake setup a project file does and can be elaborated
# twice for the idempotence section.
#
# Everything runs through `format --check`, never `format`. These fixtures are committed, and a suite
# that invokes a writing mode against a committed fixture rewrites it the first time the path under
# test starts succeeding -- which is how `tests/check/Clean.lean` was silently rewritten before
# `23b-suite-baseline-repair`.
#
# §7 is the unusual section: it pins layout defects these fixtures *found*, exactly as measured, so
# that fixing one shows up here as a failure rather than passing unnoticed. Each is labelled with the
# prompt that owns it. A green run means "still broken in the recorded way", not "correct".

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"
work=$(mktemp -d)
cleanup() { rm -rf "$work" "$repo_root/.lean-fmt-cache"; }
trap cleanup EXIT

failures=0
ok() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}
check() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
# `grep -c` counts matching *lines*; every pattern below occurs at most once per line.
count() { grep -cF -- "$2" "$1" || true; }

LEAN_NUM_THREADS=1 lake build lean-fmt NativeLayoutFixtures >/dev/null
application=$(lake -q query lean-fmt --text)

fixtures=(Alignment Boundaries Islands Offside)

printf -- '--- every family formats and validates (§1) ---\n'
# `would-format` with no diagnostics is the whole admission claim: the adapter resolved a formatter
# for every actual node, aligned every terminal, placed every comment, and the candidate passed the
# structural, comment, diagnostics, and idempotence gates under the exact module setup. A refusal
# would surface here as `rejected` or `infrastructure-failure` with the gate named.
for fixture in "${fixtures[@]}"; do
  set +e
  "$application" format --check --root . --json --no-cache \
    "tests/native-layout/$fixture.lean" >"$work/$fixture.json" 2>"$work/$fixture.err"
  set -e
  status=$(python3 -c '
import json, sys
record = json.load(open(sys.argv[1]))["files"][0]
detail = "; ".join(record["diagnostics"]) if record["diagnostics"] else ""
print(record["status"] + (f" ({detail})" if detail else ""))' "$work/$fixture.json")
  check "$fixture formats and validates" "$status" "would-format"
  python3 -c '
import json, sys
sys.stdout.write(json.load(open(sys.argv[1]))["files"][0]["formatted"])' \
    "$work/$fixture.json" >"$work/$fixture.once"
done

printf -- '--- formatting is a fixed point (§2) ---\n'
# The second pass goes through stdin borrowing the fixture's identity, so it is the same exact setup
# without writing the tracked file. The validator already runs an idempotence gate internally; this
# asserts it end to end, on output the caller can actually see.
for fixture in "${fixtures[@]}"; do
  "$application" format - --stdin-filename "tests/native-layout/$fixture.lean" --root . \
    <"$work/$fixture.once" >"$work/$fixture.twice" 2>/dev/null
  if cmp -s "$work/$fixture.once" "$work/$fixture.twice"; then
    ok "$fixture is unchanged by a second pass"
  else
    fail "$fixture is not idempotent: $(diff "$work/$fixture.once" "$work/$fixture.twice" | head -4)"
  fi
done

printf -- '--- terminal payloads are original bytes, matched by position (§3) ---\n'
alignment="$work/Alignment.once"
# Multibyte spellings: column width and byte width disagree, so an alignment that indexed the source
# by byte would drift from the first one to the end of the command.
check "a guillemet name survives" "$(count "$alignment" 'def «name with spaces»')" "1"
check "greek binders and arrows survive" "$(count "$alignment" '(α : Type) (compose : α → α) : α → α')" "1"
check "the compose operator survives" "$(count "$alignment" 'compose ∘ compose')" "1"
# Literal bases: `Nat.repr` would print `255` and `10`. The source spelling is the contract, so the
# absence of the decimal forms is as much the claim as the presence of the hex and binary ones.
check "hex and binary literals keep their spelling" "$(count "$alignment" '(0xff, 0b1010)')" "1"
check "no literal was renormalized to decimal" "$(count "$alignment" '(255, 10)')" "0"
# Repeated spellings: four `value` and three `+` in one expression, and two `Nat.succ` with two
# distinct projections. A by-spelling matcher cannot say which occurrence a native leaf denotes.
check "a four-fold repeated identifier survives" \
  "$(count "$alignment" 'value + value + value + value')" "1"
check "two same-spelled calls keep their own arguments" \
  "$(count "$alignment" 'Nat.succ pair.fst + Nat.succ pair.snd')" "1"
check "an escaped string is not re-escaped" "$(count "$alignment" '"tab\there"')" "1"

printf -- '--- every comment is placed exactly once (§4) ---\n'
boundaries="$work/Boundaries.once"
for body in \
  '-- leading line comment' \
  '-- trailing line comment' \
  '/- leading block comment -/' \
  '-- first of two consecutive comments' \
  '-- second of two consecutive comments' \
  '-- interior line comment before a continuation' \
  '/- interior block comment inside a delimiter -/' \
  '/-- A declaration doc comment stays on its declaration. -/' \
  '/-- A field doc comment stays on its field, not on the structure. -/' \
  '/-- A constructor doc comment stays on its constructor. -/' \
  '-- dangling comment after the last statement'; do
  check "placed once: $body" "$(count "$boundaries" "$body")" "1"
done
# Ownership, not just presence. A field docstring hoisted to the front of its command would land on
# the structure; this pins it to the line directly above the field it documents.
check "the field docstring still precedes its field" \
  "$(grep -A1 -F '/-- A field doc comment' "$boundaries" | tail -1)" "  first : Nat"
check "the trailing comment stays on its owner's last line" \
  "$(grep -F -- '-- trailing line comment' "$boundaries")" "  0 -- trailing line comment"
check "the interior comment stays between the operator and its continuation" \
  "$(grep -A1 -F -- '-- interior line comment' "$boundaries" | tail -1)" "    4"
# The adapter owns *both* sides of a comment, not only the side facing the token behind it. `[` and `5`
# are adjacent in the list grammar, so the native boundary between them is empty and there is nothing
# to carry a separator after the comment closes. Was D1: the output read `-/5,`, which reparses as one
# token or not at all. A line comment cannot reach this case -- it already ended the row.
check "a block comment closing mid-row is separated from the token after it" \
  "$(grep -F -- '/- interior block comment inside a delimiter -/' "$boundaries")" \
  "  [ /- interior block comment inside a delimiter -/ 5, 6]"
# A blank line the source put between a leading comment and its owner. `Command.place` decides the gap
# *between* commands from their roles, and a leading comment is inside its command's unit, so this gap
# is owned by neither and was dropped. Was D6, and it applied to every file in every Lean project: the
# copyright block ended flush against `module`. Both lines below are the assertion -- that the blank is
# there, and that exactly one line separates the block from `module` rather than two.
check "the blank line after the copyright block survives" \
  "$(awk '/^-\/$/{getline; print; exit}' "$alignment")" ""
check "and module follows it directly" \
  "$(awk '/^-\/$/{getline; getline; print; exit}' "$alignment")" "module"

printf -- '--- exact islands keep payload columns (§5) ---\n'
islands="$work/Islands.once"
# `Format.text` re-indents every newline inside a text leaf to the ambient indentation. A payload
# carrying its own absolute columns must cancel that, so the continuation lines below are asserted at
# the columns the *source* gave them and not at the column the surrounding layout would impose.
check "a multiline payload reaches column zero" "$(grep -c '^gamma"$' "$islands")" "1"
check "a multiline payload keeps its own indented line" "$(grep -c '^  beta$' "$islands")" "1"
check "the same payload one level deeper still owns its columns" \
  "$(grep -c '^  second"$' "$islands")" "1"
check "an interpolated string keeps both holes" \
  "$(count "$islands" 's!"hello {name} and {name}"')" "1"
check "a quotation with an antiquotation survives" \
  "$(count "$islands" '`($(Lean.quote value))')" "1"
check "a multiline doc comment keeps its second line at column zero" \
  "$(grep -c '^Its second line owns its own column. -/$' "$islands")" "1"

printf -- '--- offside carriers compose (§6) ---\n'
offside="$work/Offside.once"
# `sepByIndent` is the one format-algebra carrier for parser-significant columns, and record updates
# are what it covers. The field sequence must begin on its own line once a later separator breaks.
check "a record update opens its field sequence on its own line" \
  "$(grep -A1 -F '{ base with' "$offside" | tail -1)" "    first := 1, second := 2, third := 3, fourth := 4 }"
# `do`, `match`, and equation alternatives have no algebra carrier at all; their offside lives in the
# parser's `withPosition`/`checkColGe`. These assert the columns survived anyway.
check "match arms stay siblings at one column" "$(grep -c '^      | 0 => 1$' "$offside")" "1"
check "the nested match indents one level further" "$(grep -c '^        | 0 => 2$' "$offside")" "1"
check "equation alternatives stay at the declaration's own indent" \
  "$(grep -c '^  | n + 2 => alternatives n + alternatives (n + 1)$' "$offside")" "1"
check "tactic steps stay siblings" \
  "$(grep -A1 -F 'have step : n + 0 = n' "$offside" | tail -1)" "  exact step"
# `Term.byTactic` declares `ppAllowUngrouped` to keep `by` on the `:=` line, and the mechanism fires --
# the native document holds a soft `line`. `Std.Format`'s own `fill` measurement breaks it anyway, as a
# function of the width rather than of this line: measured threshold 136 columns for a line occupying
# 50. A flat boundary at the `by` terminal is what holds it, since `Doc` delegates rendering to
# `Std.Format.prettyM` on purpose and the adapter does not own that decision.
check "by stays on the := line" "$(grep -c ' := by$' "$offside")" "1"
check "and its first tactic still starts the next line" \
  "$(grep -A1 -F ':= by' "$offside" | tail -1)" "  have step : n + 0 = n := Nat.add_zero n"
# A guarded `let`'s siblings are the offside constraint's own job: native layout reparents them *into*
# the guard, where they would run conditionally. The break after the bar is D4 and stays pinned in §7;
# these assert the part that is already right, which nothing asserted before.
check "a guarded let's siblings stay at the owning indentation" \
  "$(grep -A3 -F 'let some current := value |' "$offside" | tail -2)" \
  "    let doubled := current + current
    return doubled + 1"
check "two guards in one sequence each keep their own siblings at that indentation" \
  "$(grep -c '^    let some \(first := left\|second := right\) |$' "$offside")" "2"

printf -- '--- pinned defects these fixtures found, owned by 23c (§7) ---\n'
# Each of these is wrong. They are pinned exactly as measured so that repairing one fails this
# section instead of passing silently, and so 23c inherits minimized reproductions rather than a
# description. A green run here means "still broken in the recorded way".
#
# D1 is repaired and its assertion moved into §4, where it now reads as the positive claim rather than
# the pinned defect. `experiments/native-layout-defects` records why it was the adapter's: trivia is
# stripped before native formatting, so no native document ever held that comment.
#
# D2 -- a constructor docstring is dedented to column zero and gains a blank line before its
#       constructor. This is the upstream `def ctor` shape: the newline lives inside the `"\n| "`
#       atom, which sits *after* `optional docComment`, so the docstring is emitted before the
#       separator that was supposed to precede it.
check "D2 constructor docstring is dedented to column zero" \
  "$(grep -c '^/-- A constructor doc comment stays on its constructor. -/$' "$boundaries")" "1"
check "D2 and is followed by a blank line" \
  "$(grep -A1 -F '/-- A constructor doc comment' "$boundaries" | tail -1)" ""
# D3 -- a comment dangling after the last statement of a `do` block leaves the block entirely and
#       lands at column zero before the next command. The comment multiset is preserved, which is
#       why §4 passes; its owner is not.
check "D3 a dangling do-block comment escapes to column zero" \
  "$(grep -c '^-- dangling comment after the last statement$' "$boundaries")" "1"
# D4 -- a guarded `let ... | return 0` breaks after the `|`. `results/23a` passed this to 23c as an
#       open safety boundary; it validates today, so it is a layout defect and not a correctness one.
#       A flat boundary at the bar was tried and reverted: it is width-unsound. Forcing the bail-out
#       onto the bar's line makes the renderer break *inside* the bail-out instead, at an indentation
#       derived from the enclosing `nest` rather than from the bar's column, and the continuation
#       reparses as a sibling `do` element. `tests/block-formatter` renders the same fixture at four
#       widths and caught it: at 40, `return Array.replicate 12 0 |>.size` split after `12` and the
#       output no longer elaborated. Repairing D4 needs an indentation anchor for the bail-out, not
#       just a flat boundary; `experiments/native-layout-defects/README.md` records the measurement.
check "D4 a guarded let breaks after its bar" \
  "$(grep -c '^    let some current := value |$' "$offside")" "1"
# D5 is repaired and its assertion moved into §6. It was the first of the three *upstream* defects to
# go: the flat boundary the adapter already had reaches it, so no new mechanism was needed. Unlike D4,
# joining `by` to `:=` cannot migrate a break: the tactic sequence starts its own line either way.
# D6 is repaired; its assertion moved into §4. It was the adapter's for the same reason as D1 and D3.

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ $failures -eq 0 ]] || exit 1
printf 'lean-fmt native layout invariant families passed\n'
