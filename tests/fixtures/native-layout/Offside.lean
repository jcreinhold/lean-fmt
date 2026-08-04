/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lean

/- The offside constraints the adapter enforces, and the constructs they must compose with.

Each constraint names a parser-significant column that native layout alone does not preserve:

- a guarded `let ... | ...` whose continuation is a sibling statement, which native layout can
  reparent under the guard's own sequence -- including an arrow guard, whose bar `doPatDecl`
  wraps a `null` deeper, and a bail-out carrying an interpolated string, whose island the
  toolchain's formatter drops from the document;
- the first item of a `sepByIndent` list whose separators the source wrote out, which has to begin on
  its own line so that a later separator breaking cannot dedent an item below it -- and the same list
  spelled with line-break separators, which the formatter's own `align` already positions and which a
  second break would displace;
- the term of a `return`, which must stay on the `return` line;
- a command written inside another command, which begins at the enclosing command's own column and not
  at the indent the embedding node's `nest` would otherwise impose;
- the two places where a line's *end* is the column in question: a discretionary break Lean's document
  spells directly in front of a hard newline, and a doc comment written between two tokens, which has
  to keep the side of the break the source put it on.

`do`, nested `match`, tactic blocks, `where`, and equation alternatives are here because the
constraints have to compose with them, not because each needs a rule of its own. -/

public section

namespace NativeLayoutOffside

/- Guarded `let` whose `| return` continuation is followed by a sibling statement at the owning
indentation. Reparenting the sibling under the guard changes what runs. -/
def guardedSibling (value : Option Nat) : Nat := Id.run do
  let some current := value | return 0
  let doubled := current + current
  return doubled + 1

/- Two guards in one sequence, so the constraint has to apply per owner rather than once per command. -/
def guardedTwice (left right : Option Nat) : Nat := Id.run do
  let some first := left | return 0
  let some second := right | return first
  return first + second

/- A guarded `let` whose bail-out is long enough to need a break of its own. The short bail-outs above
cannot tell an honest boundary from one that only looks right at width 100: a constraint that pins this
bar's break has to leave the term's own break somewhere the `do` block still reads as part of the
bail-out. §1b renders this at 20 and 40, where it must break. -/
def guardedLongBailout (value : Option Nat) : Nat := Id.run do
  let some measured := value | return (Array.replicate 12 0).size + Array.size #[1, 2, 3]
  return measured

/- A bail-out the source spells on more than one line. The join is collected only for a bail-out the
source already fit on one line, because that is what makes flattening it free of the two leaves
flattening cannot remove -- and what bounds the resulting line. This one is not collected, keeps its
break after the bar, and is the negative half of that rule. -/
def guardedSpanningBailout (value : Option Nat) : Nat := Id.run do
  let some measured := value |
    let fallback := 3
    return fallback + 1
  return measured

/- A guarded arrow-let whose bail-out carries an interpolated string, and two things that guard
hides. The guard parses through `doPatDecl`, which wraps its `| bail-out` one `null` deeper than
the `doLetElse` shape above, so the bail-out's bar is not a direct child of the guard node. And
the `m!` is a protected island the toolchain's formatter drops from the document entirely: glued
to the leaf that follows it, neither the bail-out's flatten nor the continuation's offside
constraint has a node to land on, which is what `Mathlib/Tactic/Simproc/VecPerm.lean` reported as
`applied 0/2 offside constraints`. Glued to the terminal before it, the island is inside the
bail-out's own node and the join proceeds. -/
def guardedDroppedIsland (value : Option Nat) : Lean.MetaM Nat := do
  let some current ← pure value | Lean.throwError m!"missing {value}"
  return current

structure Packet where
  first : Nat
  second : Nat
  third : Nat
  fourth : Nat

/- A record update whose field sequence is long enough to break at a later separator. -/
def updated (base : Packet) : Packet :=
  { base with first := 1, second := 2, third := 3, fourth := 4 }

/- The same update with the separators spelled as line breaks. `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:211-223`) emits a forced `align` for exactly this spelling, so the sequence is
already positioned; the rule above must not fire here. It used to, and the extra break put a blank line
above `first` and left it indented one level past its siblings, which is where the parser stopped
reading fields. -/
def relaid (base : Packet) : Packet :=
  { base with
    first := 1
    second := 2
    third := 3
    fourth := 4 }

/- Nested `match` inside `do`, with alternatives whose bodies break. -/
def nestedMatch (value : Nat) : Nat := Id.run do
  let result :=
    match value with
    | 0 => 1
    | n + 1 =>
      match n with
      | 0 => 2
      | m + 1 => m + 3
  return result

/- A tactic block whose steps must stay siblings. -/
theorem tacticSiblings (n : Nat) : n + 0 = n := by
  have step : n + 0 = n := Nat.add_zero n
  exact step

/- The same list, spelled with `;` instead of line breaks. A tactic sequence is a `sepByIndent` list
like a record update's fields, and `by ` puts its first tactic one column right of the indent the `;`
separators break to -- so breaking a later one and not the first dedents it below the column
`many1Indent` saved, and the block ends there with the rest read as a command. -/
theorem semicolonTactics (n : Nat) : n + 0 = n ∧ n + 0 = n := by
  constructor; exact Nat.add_zero n; exact Nat.add_zero n

/- One tactic has no separator that can break at the wrong column, so nothing is forced and `by` keeps
its tactic. The negative half of the rule, and the reason it counts items rather than matching a kind. -/
theorem singleTactic (n : Nat) : n + 0 = n := by rfl

/- `where` bindings after an equation-alternative body. -/
def withWhere (value : Nat) : Nat :=
  helper value + helper (value + 1)
where
  helper (inner : Nat) : Nat := inner + 1

/- Equation alternatives with guarded bodies. -/
def alternatives : Nat → Nat
  | 0 => 0
  | 1 => 1
  | n + 2 => alternatives n + alternatives (n + 1)

/- A command nested inside another command. `#guard_msgs`'s parser spells `" in" ppLine command` with
no `ppDedent`, so Lean's document puts the embedded command inside the node's own `nest` and it lands
one level in. A command starts at column zero, so the boundary before it is dedented to the enclosing
command's column. -/
/-- info: 3 -/
#guard_msgs in
#eval 1 + 2

/- The same embedding with a comment between `in` and the command. The comment ends the row it is on,
and `insertComments` used to read that as "the boundary is spent" and drop it -- right for the three
layouts that only say *whether* the next token is on this row, wrong for the one that says which
*column* the row starts at. Both the comment and the command landed one level in, with the boundary
still counted as applied so nothing refused. Found on
`MathlibTest/Linter/Multigoal.lean`. -/
/-- info: 7 -/
#guard_msgs in
-- the comment the dedent has to survive
#eval 3 + 4

/- The same embedding again, this time with a body of its own. The dedent above is a *boundary*: it
sets the column of the row the command starts on and says nothing about the rows after it, which keep
the `nest` the embedding node introduced and land one level further in than the command they belong to.
It stayed invisible while the case above had the command itself misplaced and while the first fixture
was a single line with no interior break. -/
#guard_msgs in
example : 1 + 1 = 2 ∧ 2 + 2 = 4 := by
  refine ⟨rfl, ?_⟩
  rfl

/- The negative half: `open … in` spells the same embedding and Lean *does* dedent it. The correction
sets a column rather than adjusting one, so it spells here exactly the newline the document already
had. -/
open Nat in
def afterOpen : Nat := 0

/- A `do` block's `if` whose body is indented under it. Lean's `doIf` spells `ppSpace` before the
`doSeq`, and the sequence begins with its own hard newline, so the document holds a discretionary break
directly in front of a newline. Flattened, that break is a space at the end of the `then` line, so this
is the one case in this file whose evidence is what a line ends with rather than where it
starts. -/
def indentedThen (limit : Nat) : Id Nat := do
  let mut total := 0
  for value in [0:limit] do
    if value != 0 then
      total := total + value
  return total

/- A doc comment written between two tokens rather than in front of the command. `letRecDecl` is
`optional docComment >> letDecl`, and Lean's document spells the comment's closing newline inside a
`nest` and then a discretionary break before the declaration's name -- so the name lands one column
past the `let`, which is where the `where` bindings above land too and is the block's own reference
column either way. What the comment must not do is change which side of the break it is on: the source
put it on its own line, and a reparse that finds it trailing the `rec` hands it to a different owner. -/
def documentedLetRec (value : Nat) : Nat :=
  let rec
    /-- Applies the mapping to a position. -/
    helper (n : Nat) : Nat := n + value
  helper 0

/- The same `sepByIndent` rule as the record update above, read off the carrier instead of the
sequence. `tacticSeq1Indented` is what `tacticSeq` reduces to under `by`, under `(`, under a focus dot
and under `case` alike, so treating the kind itself as ungrouped fires the rule in three places whose
carrier does group the list. Where the carrier's delimiter is the only thing in front of the list --
`(` here, `·` below -- the first item already sits on the column the separators break to, and the break
the rule wanted has nowhere to land but one `nest` past them, which puts `rfl` outside the parentheses.
`case left => ` is the contrast in the other direction: terminals intervene, so the list
does start right of the separators' column and the boundary is still needed. -/
theorem delimitedTactics (a : Nat) : a = a ∧ a = a := by
  constructor <;> (skip; rfl)

theorem carriedTactics (a : Nat) : a = a ∧ a = a := by
  constructor
  case left => skip; rfl
  case right => skip; rfl

theorem focusedTactics (a : Nat) : a = a ∧ a = a := by
  constructor
  · skip; rfl
  · skip; rfl

/- `show`'s `by` is not `Term.byTactic`. `byTactic'` (`Term.lean:117`) is the same parser with the
`ppAllowUngrouped` marker removed and its own kind, which Lean's comment says exists only so `show` and
`suffices` can be find-replaced safely; it is registered in no parser category, so it owns no group and
the group is the `show`'s. That puts `by` far to the right of the column the separators break to, which
is the case the boundary exists for -- decline it and `constructor` joins the `by` line while `rfl`
lands below the saved column. `Mathlib/NumberTheory/LSeries/HurwitzZetaEven.lean` refused for it. -/
theorem showCarriedTactics (value : Nat) : value + 0 = value ∧ value + 0 = value :=
  show value + 0 = value ∧ value + 0 = value by constructor; rfl; rfl


/- A tactic-level `have` spells its `:= body` through `Term.letIdDecl`, not `Command.declValSimple`,
so the `:= by` join has to name it too, or the over-measured soft `line` breaks `have h : T :=`
from `by` however short the line. -/
theorem letIdBodyJoins (n : Nat) : n = n := by
  have step : n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n := by
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
    all_goals exact Nat.add_zero n
  exact step.1

/- A `letI`-family body parses only at or left of the keyword's column (`withPosition` saves it and
`argument` is `checkColGt`), so the alignment the source spells is a parse constraint, not a style:
one column right and the body is read as the value's next argument. The `columned` boundaries hold
the keyword's row and the body's row at their source columns. -/
def letChainAligned (x : Nat) : Nat × Nat × Nat :=
  (letI : Inhabited Nat := ⟨x⟩
   letI : OfNat Nat x := ⟨x⟩
   (default, 5, x))


/- A two-statement bail-out falsifies the one-line precondition the single-statement joins rely on:
`doSeqIndent`'s own formatter emits the inter-item break as a leaf flattening cannot remove, one
line of source notwithstanding. The join is not collected, and the guard keeps the upstream break
after the bar. -/
def twoItemBailout (value : Option Nat) : Nat := Id.run do
  let some current := value | dbg_trace "missing"; return 0
  return current + 1

/- A brace collection whose continuation row the source put left of its first element.

`{a, b, c}` is two parsers: this collection literal and a `structInst` whose fields are all
`structInstFieldAbbrev`s. `structInstFields` is `sepByIndent`, so the structure reading needs every
later element at or right of the first one, and a source that spells a row left of it has excluded
that reading. Indent the row and both parsers succeed: the reparse is a `choice` where the source
had a literal, which the structure gate reports as one node too many.
`Proofs/AlgebraicGeometry/EllipticCurve/Projective/Smooth.lean` reported `3755 -> 3756` for it. -/
structure Collected where
  items : List Nat

instance : Singleton Nat Collected := ⟨fun value => ⟨[value]⟩⟩

instance : Insert Nat Collected := ⟨fun value collected => ⟨value :: collected.items⟩⟩

def firstCollected : Nat := 1

def secondCollected : Nat := 2

def thirdCollected : Nat := 3

def fourthCollected : Nat := 4

def collectedRows : Collected :=
  {firstCollected, secondCollected, thirdCollected,
  fourthCollected}

/- A struct instance's closing brace is parse-significant on its own row.

`structInstFields` is a `sepByIndent`, and its indent check fires at exactly the first field's
column: a `}` that begins a row there is read as a continuation of the field list, one empty slot
wider than any other position produces. Hugging the brace, or ending its row anywhere else, parses
to the narrower list. The candidate must reproduce whichever list the source wrote: a brace alone
at the field column keeps a break there, with the fields broken onto their own rows so the columns
still coincide (`rebuiltConfig`); a comment that forces the brace onto the next row anywhere else
dedents it off the field column (`commentedConfig`, `fieldColumnConfig`). The document's own hug
is already safe, so a source that hugs keeps hugging (`flushConfig`).
`MathlibTest/Spread.lean` and `Mathlib/Algebra/Category/AlgCat/Limits.lean` refused on the two
directions of this one rule. -/
structure Config where
  retries : Nat
  verbose : Bool

def baseConfig : Config := ⟨1, false⟩

def commentedConfig : Config := { baseConfig with retries := 2 -- the count that matters
  }

def fieldColumnConfig : Config := { baseConfig with retries := 2 -- the count that matters
    }

def rebuiltConfig (config : Config) : Config := { config with
  retries := 3
  verbose := decide (config.retries = 0)
  }

def flushConfig : Config := { baseConfig with retries := 5 }

end NativeLayoutOffside


