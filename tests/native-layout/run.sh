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
# §7 is the unusual section: it pins the layout defects these fixtures *found*, exactly as measured, so
# that fixing one shows up here as a failure rather than passing unnoticed. Six are repaired and their
# claims now sit in §4 and §6 as positive assertions, so those six survive there only as the record of
# what they were. A seventh turned up and is pinned live: D7, the space Lean's `pushToken` does not put
# between `]` and `do`. Re-pin there for an eighth.

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

printf -- '--- every family still validates at narrow widths (§1b) ---\n'
# Every section below reads a width-100 render, and that is not enough to keep a boundary honest. A
# flat boundary substitutes an unbreakable `.text " "`, so the renderer re-measures and breaks at the
# next soft line instead -- possibly inside a construct whose continuation indentation comes from the
# enclosing `nest` rather than from the column the boundary just moved. At width 100 these fixtures fit
# and nothing moves; the defect only appears where something has to break. D4's reverted repair
# (`929b067`) failed exactly this way and only `tests/block-formatter`, which renders at four widths,
# saw it. These two widths are cheap and put the check where the boundaries are written.
#
# Verified to fail: with `929b067`'s guard collector restored, `Offside` reports
# `infrastructure-failure` at the diagnostics gate at width 20. Width 40 still passes there, so both
# widths are load-bearing -- and so is `guardedLongBailout`, whose bail-out is the only one in these
# fixtures long enough to have to break.
for width in 20 40; do
  printf '[format]\nline-width = %s\n' "$width" >"$work/width-$width.toml"
  for fixture in "${fixtures[@]}"; do
    set +e
    "$application" format --check --root . --json --no-cache --config "$work/width-$width.toml" \
      "tests/native-layout/$fixture.lean" >"$work/$fixture-$width.json" 2>"$work/$fixture-$width.err"
    set -e
    status=$(python3 -c '
import json, sys
record = json.load(open(sys.argv[1]))["files"][0]
detail = "; ".join(record["diagnostics"]) if record["diagnostics"] else ""
print(record["status"] + (f" ({detail})" if detail else ""))' "$work/$fixture-$width.json")
    check "$fixture validates at width $width" "$status" "would-format"
  done
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
  '-- dangling comment after the last statement' \
  '-- indented past every block, aligned with none of them'; do
  check "placed once: $body" "$(count "$boundaries" "$body")" "1"
done
# Ownership, not just presence. A field docstring hoisted to the front of its command would land on
# the structure; this pins it to the line directly above the field it documents.
check "the field docstring still precedes its field" \
  "$(grep -A1 -F '/-- A field doc comment' "$boundaries" | tail -1)" "  first : Nat"
# Was D2, and it was upstream twice over: `def ctor` wraps the docstring in a `nest -2` and puts the
# constructor's newline inside the `"\n| "` atom that follows it, so the docstring came out at column
# zero with a blank line under it -- and reparsed onto no constructor at all. The repair is an elided
# boundary at the `|`, which removes the first of the two newlines, and a constraint cancelling the
# `nest -2` over the docstring's own range.
check "the constructor docstring keeps its constructor's indentation" \
  "$(grep -c '^  /-- A constructor doc comment stays on its constructor. -/$' "$boundaries")" "1"
check "  ... and its constructor follows on the next line, with no blank between" \
  "$(grep -A1 -F 'A constructor doc comment stays on its constructor' "$boundaries" | tail -1)" \
  "  | left"
# A docstring spanning more than one line is where the two halves of that repair pull against each
# other. The docstring is an exact island, so its bytes carry absolute source columns and a cancelling
# `nest` has to reach column zero -- but that nest is computed from the native document's own depth
# during the walk, and the constraint's nest is added by an *ancestor*, which post-order finishes
# afterwards. Verified to fail: without `containingConstraintNest`, this file is not merely misindented
# but rejected, at the token gate, `token 75 (Lean.Parser.Command.docComment) changed spelling`.
check "a constructor docstring's continuation lines do not move with its first" \
  "$(grep -A2 -F 'A constructor doc comment can run onto a second line' "$boundaries" | tail -1)" \
  "  exact island already carries exactly where they are. -/"
check "  ... and its constructor still follows it" \
  "$(grep -A3 -F 'A constructor doc comment can run onto a second line' "$boundaries" | tail -1)" \
  "  | only"
check "the trailing comment stays on its owner's last line" \
  "$(grep -F -- '-- trailing line comment' "$boundaries")" "  0 -- trailing line comment"
# Was D3, and unlike D1, D2, and D6 it was an *ownership* defect rather than a layout one: the comment
# is indented past the token after it, so `assignWithNeighbors` had no rule for it and handed it to
# that token as leading trivia. It then rendered at that token's column -- zero -- outside the block it
# was written in, while the comment multiset stayed intact, which is why every count above passed.
# These two lines are the repair's claim: the comment lines up with the statement it follows, and the
# statement is still the last thing in the block.
check "a block's dangling comment stays inside the block" \
  "$(grep -B1 -F -- '-- dangling comment after the last statement' "$boundaries" | head -1)" \
  "    return value"
check "  ... at the column of the statement it follows" \
  "$(grep -c '^    -- dangling comment after the last statement$' "$boundaries")" "1"
# The negative half of the same rule, and the reason `enclosingBlock?` compares columns for equality
# rather than `<=`. This comment is also indented past the token after it, but it lines up with no
# item of any block that ends where it starts, so it has no block to belong to and stays what it has
# always been: leading trivia of the next command's first token, rendered at that token's column. A
# `<=` test would have handed it to the command root, which is a block the adapter has no break inside
# to hang it on -- the comment gate would then refuse the whole file rather than move one comment.
check "a comment aligned with no block item keeps its leading assignment" \
  "$(grep -c '^-- indented past every block, aligned with none of them$' "$boundaries")" "1"
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
# the guard, where they would run conditionally. The bail-out's own placement is the other half, and
# both are positive claims now; §7 records what D4 was and why joining is the only sound layout for it.
check "a guarded let's bail-out stays on the bar's line" \
  "$(grep -c '^    let some current := value | return 0$' "$offside")" "1"
check "  ... and its siblings stay at the owning indentation" \
  "$(grep -A2 -F 'let some current := value |' "$offside" | tail -2)" \
  "    let doubled := current + current
    return doubled + 1"
check "two guards in one sequence each join their own bail-out" \
  "$(grep -c '^    let some \(first := left | return 0\|second := right | return first\)$' "$offside")" "2"
# The join has to survive a bail-out long enough to break, because that is the one the reverted repair
# got wrong: joining moved the break *inside* the term, to an indentation the enclosing `nest` chose
# rather than the bar's column, and the continuation reparsed as a sibling `do` element. Flattening the
# joined span leaves no break there to land wrong. §1b renders this same fixture at 20 and 40.
check "a bail-out long enough to break still joins the bar" \
  "$(grep -c '^    let some measured := value | return (Array.replicate 12 0).size + Array.size #\[1, 2, 3\]$' "$offside")" "1"
# The join is collected only where the source already spelled the bail-out on one line. That is what
# makes flattening total -- `sepByIndent.formatter` is the sole producer of the forced align and the
# hard newline, and only on its `hasNewlineSep` path -- and what bounds the joined line's width.
check "a bail-out the source spelled on several lines keeps its break" \
  "$(grep -A1 -Fx '    let some measured := value |' "$offside" | tail -1)" \
  "      let fallback := 3"
check "  ... and is the only bar in these fixtures left bare" \
  "$(grep -c '^    let some .* |$' "$offside")" "1"

printf -- '--- the defects these fixtures found: six repaired, one pinned (§7) ---\n'
# This section held six pins, each a defect these fixtures found, recorded exactly as measured so that
# repairing one failed here instead of passing silently. All six are repaired; below the D1-D6 record
# is D7, found later and pinned the same way.
#
# D7: a keyword whose parser spells no leading space sits flush against a delimiter before it.
# `pushToken` (`Lean/PrettyPrinter/Formatter.lean:385-407`) decides the discretionary separator by
# re-lexing alone -- it inserts one exactly when `parseToken (tk ++ leadWord)` runs past `tk`. That is
# the right rule for safety and the wrong one for a formatter: `]` then `do` does not re-lex, so the
# document spells them adjacent and the output reads `#[1, 2, 3]do`. It is upstream, and
# `experiments/native-layout-defects/README.md` records the probe, the negative case, and why the
# obvious adapter-side repair ("the source separated these two terminals, so emit a `Format.line`")
# over-fires on `⟨ a, b ⟩`. The output still parses and still validates, which is why no gate catches
# it and why it needs a pin.
check "a for over a bracketed collection loses the space before do" \
  "$(count "$alignment" 'for value in #[1, 2, 3]do')" "1"
check "  ... and the same loop over an identifier keeps it, so a repair must tell them apart" \
  "$(count "$alignment" 'for value in list do')" "1"
#
# D1 is repaired and its assertion moved into §4, where it now reads as the positive claim rather than
# the pinned defect. `experiments/native-layout-defects` records why it was the adapter's: trivia is
# stripped before native formatting, so no native document ever held that comment.
#
# D2 is repaired and its assertions moved into §4, beside the field docstring whose ownership they
# match. It was upstream: `def ctor` puts the newline inside the `"\n| "` atom, which sits *after*
# `optional docComment`, and wraps the docstring in a `nest -2`.
#
# D3 is repaired and its assertions moved into §4. It was the only one of the six that was not a
# layout defect: `Comments.assignWithNeighbors` had no rule for a comment indented past the token after
# it, so the comment changed *owner*, and layout followed the owner. The repair is a column comparison
# in ownership plus one break in the adapter, and the two have to agree or the comment gate refuses.
#
# D4 is repaired and its assertions moved into §6. It was upstream -- Lean's document spells a hard
# `text "\n"` after the bar -- and the last of the six because the obvious repair is wrong for a reason
# the other two upstream ones do not have. A flat boundary at the bar alone was tried and reverted
# (`929b067`): joining the bail-out does not remove its break, it *moves* it inside the term, to an
# indentation the enclosing `nest` chose rather than the bar's column, where `checkColGe` reparses the
# continuation as a sibling `do` element. `Std.Format` has no constructor for "indent to the column
# where this subtree starts" -- `nest` is relative to the indent and `align` pads to it -- so no anchor
# can be expressed, and the only sound join is one that leaves no break behind. That is a flat boundary
# at the bar *plus* flattening the bail-out's own span, collected only where the source already spelled
# it on one line, which is what makes flattening total and bounds the joined line.
# D5 is repaired and its assertion moved into §6. It was the first of the three *upstream* defects to
# go: the flat boundary the adapter already had reaches it, so no new mechanism was needed. Unlike D4,
# joining `by` to `:=` cannot migrate a break: the tactic sequence starts its own line either way.
# D6 is repaired; its assertion moved into §4. It was the adapter's for the same reason as D1 and D3.

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ $failures -eq 0 ]] || exit 1
printf 'lean-fmt native layout invariant families passed\n'
