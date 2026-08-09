/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Config
import all LeanFmt.Formatter
import all LeanFmt.Formatter.Trivia

import Lean.Parser.StrInterpolation

/-! The native grammar-layout adapter.

Lean's registered formatter remains the grammar authority. This module transforms its public
`Std.Format` algebra directly: native non-comment leaves are aligned with the selected source-covering
terminals and replaced by their original bytes, while groups, fills, nesting, alignment, and tags
remain native. Source-data syntax is replaced before formatter execution by a typed marker and restored
at that marker, so a private formatter failure or normalization cannot become a source-text fallback.

Three mechanisms sit on top of that, all collected from grammar shape and all refusing the command
if the document turns out not to have the node they name. A structural anchor interval
(`CommandPlan.anchors`, lowered to `Doc.anchor`) re-bases every break inside one contiguous terminal
interval to the column its first terminal lands at — the `sepByIndent` invariant stated once for
struct-instance fields and indented or bracketed tactic/conv sequences, where per-field pins used to
approximate it row by row. A `BoundaryLayout` replaces the layout between two named terminals with a
space, a newline, or nothing. An `OffsideConstraint` adds a `nest` the document never had, over
exactly one source range, on the node its `ConstraintCarrier` names — the `append` that carries the
break before the range, or the `nest` the document wrapped the range in. All are documented at their
declarations, including why the carrier is not a predicate and why a flat boundary is not free.

The `BoundaryLayout` census (LAY-POSTHOC-RETIREMENT) lives at `CommandPlan.collect`. The distinction
that matters: the anchor is a structural fact about a grammar family, while the surviving
`.columned`/`.anchored` pins are *evidential caps* — they hold a row at the source column that made
the source's own parse commit, capped so a stale pin is a known refusal rather than a silent follow.
The relationship that would survive every layout ("left of wherever the first element lands") names
an output column, which `Std.Format` cannot express, so no resolved-column machinery is introduced.

Doc comments are syntax, not trivia, so they are ordinary terminals: their opening token and body align
and emit original bytes exactly where their owner spells them. Hoisting them to a command prefix moved
a field or constructor docstring off its owner and left the native separator behind — which is why no
prefix mechanism exists here.

Interior comments the walk only *locates*: it splices each boundary's comment run into the document,
and a maximal run of fill-eligible lines (consecutive source rows at one column) goes in as one node
tagged `fillTagBase + index`, carrying the block's verbatim spelling as its body. The lowering maps
the tag to one `Doc.fillWords` leaf, so the block's spelling — verbatim, or paragraphs packed against
the margin — is the renderer's decision, made at the block's true final column with the render-time
policy (`reflow-comments`, `line-width`, `pinned-comments`). The plan and the walk hold no policy:
the comment's bytes are a source fact, the column it lands on is a layout outcome, and the two meet
only at render.

An exact island whose payload spans lines carries its own absolute source columns. `Std.Format`
re-indents every newline inside a `text` leaf to the ambient indentation, and that indentation is
exactly the sum of the enclosing `nest` amounts plus the column the leaf is rendered at — `align` pads
output without changing it (`Init/Data/Format/Basic.lean`). The adapter therefore wraps a multiline
island in a `nest` that cancels both, and `Int.toNat` clamps the result to column zero. The sum
includes the constraint nests an ancestor has not applied yet, which the walk cannot have seen and
`containingConstraintNest` reads out of the spans instead.

The adapter has no core/extension gate and no command/term/tactic visitor. A failure is a typed refusal
with the root category, kind, range, resolution trace, native leaf index, and nearby source terminals.
-/

namespace LeanFmt.Internal

namespace Formatter.NativeLayout

private structure Terminal where
  syntaxSpelling : String
  sourceSpelling : String
  range : SourceRange
  deriving Inhabited

private structure ExactIsland where
  marker : String
  range : SourceRange
  text : String
  /- Whether the payload is a comment. Lean ends a token's trailing trivia at the end of its line, so
  which side of a line break a comment falls on decides whether it is the previous token's trailing
  comment or the next token's leading one. That is the one layout question a comment's own bytes
  cannot answer, and the only reason this flag exists. -/
  comment : Bool := false
  deriving Inhabited

private structure InteriorComment where
  payload : String
  range : SourceRange
  placement : CommentPlacement
  kind : CommentKind
  /-- The extraction row facts (Comments.Comment): the fill-block grouping reads them and never
  re-scans the source. -/
  row : Nat := 0
  column : Nat := 0
  startsRow : Bool := false
  boundary : Nat := 0
  deriving Inhabited

/- Which native node an indentation constraint is written on.

A constraint names a source range, and more than one node in the document spells exactly that range:
the `nest` the formatter put around it and the `append` that joins it to the break before it are both
candidates, and they mean different things. The `append` moves the break *and* what follows it, which
is what an offside sibling needs. The `nest` moves only what is inside it, which is what a wrong nest
needs cancelled.

Left to a single predicate this is not a choice at all — the walk is post-order, so whichever node is
deeper claims the constraint, and for a guarded `let` that is the `nest`, which dedents the body
without moving the break above it and puts the siblings back inside the guard. So the constraint
carries its carrier and `finishConstraint` matches on it. A carrier that never appears leaves the
applied count short and refuses the command, so this cannot silently pick the wrong one. -/
private inductive ConstraintCarrier where
  | boundary
  | nest
  deriving BEq, Inhabited

/- `required` says what an unapplied constraint means, and the two answers are not the same failure.

A fidelity constraint corrects a column the parser reads back, so if it never lands the walk lost the
node it was collected at and the output may not reparse: that refuses the command. A readability
constraint cancels an indent level the document did not have to introduce, so if it never lands the
row is wider than it could be and nothing else changes; refusing there would turn a missed
improvement into a failed file. Only `LAY-CHAIN-COMPENSATION` is not required, and it says why. -/
private structure OffsideConstraint where
  range : SourceRange
  indentAdjustment : Int
  carrier : ConstraintCarrier
  required : Bool := true
  deriving Inhabited

/- What the adapter puts at one boundary in place of whatever the native document laid out there.

A boundary is the layout between two terminals, and these are the three things it can be. Each is a
correction to Lean's own document, collected by grammar shape and applied by terminal index, so a rule
that needs one names the terminal and the spelling and nothing else.

The mechanism is one substitution; the constructors are its values. `flat` joins what the document
broke, `hard` breaks what it joined, `elided` removes a separator the document spelled twice, and
`dedented` breaks to the enclosing command's own column rather than to the document's current indent.

`dedented` is the only one whose spelling depends on where it lands, so it is the only one
`boundaryFormat` needs the transform's state for. It cancels the whole ambient indentation the way an
exact island's payload does, and for the same reason: what follows it carries a column of its own
rather than one the surrounding layout may choose.

`flat` is not free and is not the default reading of "this should be on one line". `.text " "` cannot
break, so the renderer re-measures and breaks at the next soft line instead. When that next line is
inside the construct whose boundary was just moved, its continuation is indented from the enclosing
`nest` rather than from the column the boundary moved, and offside-sensitive syntax reparses. The
guarded `let`'s bar was reverted once for exactly that (`7e838a1`) and is joined today only because
`collectGuardBailouts` pairs the boundary with a flatten that leaves no soft line behind — a `flat`
alone would not be sound there. `hard` and `elided` do not have this failure mode: neither can make a
line longer. -/
/- The layout one boundary spells between two named terminals, in three classes (the
LAY-POSTHOC-RETIREMENT census; the per-producer table is at `CommandPlan.collect`):

- *Break spellings* — `flat`, `hard`, `elided`: a space, a newline, or nothing, where the native
  document would otherwise have decided by width.
- *Evidential caps* — `columned`, `anchored`: the continuation lands at the source's column, the
  column that made the source's parse commit. Capped, never a resolved output column, so a stale
  pin refuses rather than follows.
- *Structure-aware spellings* — `dedented`, `explodedClose`: the row's column is computed from the
  walk's own spans (a nested command's interior dedent, an exploded collection's private nest) --
  neither source evidence nor a width decision. -/
private inductive BoundaryLayout where
  | flat
  | hard
  | elided
  | dedented
  | /-- A break whose continuation lands at this exact column. The column is read off the source:
    the layout that made a column-sensitive parse commit is the source's, and only spelling its
    column again keeps the candidate's reparse committing the same way. -/
  columned (col : Nat)
  | /-- A break whose continuation lands at this exact column, dedenting below the ambient nest
    when the document indented past it.

    `columned` above only ever moves a row right, because a stale pin that moves one left strands
    it outside the construct it belongs to. The `letI`-family body is the one row where right is
    the failing direction: it must stay at or left of its keyword's column or the parser reads it
    as one more argument of the value. So this pin holds the source's column in both directions,
    and `collectLetFamilyAlignments` pairs it with a `columned` pin on the keyword's own row -- the
    two together reproduce the relationship the source proved parseable. -/
  anchored (col : Nat)
  | /-- The closing bracket of a magic-trailing-comma explosion: a hard break whose continuation
    dedents to the collection's own line. The amount is the collection's private `nest`, which only
    the walk can see, so this is spelled as a marker the `.nest` rewrite cancels; see
    `boundaryFormat` and the `explodedCloseTag` it emits. -/
  explodedClose
  deriving BEq, Inhabited, Repr

/-- What a pin asks for, in words rather than a constructor. This type is `private`, so `Repr`
renders its mangled name (`_private.LeanFmt.Formatter.NativeLayout.0.…`); any message that can
reach a user calls this instead. -/
private def BoundaryLayout.describe : BoundaryLayout → String
  | .flat => "no break"
  | .hard => "a break"
  | .elided => "no break and no space"
  | .dedented => "a break back to column zero"
  | .columned col => s!"a break landing at column {col}"
  | .anchored col => s!"a break anchored at column {col}"
  | .explodedClose => "a break before a closing bracket"

/- The spelling that satisfies two rules naming one gap, or `none` when they genuinely disagree.

`anchored c` and `columned c` name the same column and differ only in whether a document that
indented past it may keep that indent, so the exact one satisfies both. A chain of `have`s reaches
this: the outer body's `anchored` pin and the inner keyword's row pin land on one terminal. -/
private def BoundaryLayout.join? : BoundaryLayout → BoundaryLayout → Option BoundaryLayout
  | .anchored left, .columned right | .columned right, .anchored left =>
    if left == right then some (.anchored left) else none
  | left, right => if left == right then some left else none

private structure TokenSpan where
  start : Nat
  stop : Nat
  deriving Inhabited, BEq

/-- Deterministic work performed while adapting one native formatter result. -/
structure Metrics where
  nativeNodes : Nat := 0
  tokenLeaves : Nat := 0
  commentLeaves : Nat := 0
  normalizedTokens : Nat := 0
  exactIslands : Nat := 0
  exactIslandBytes : Nat := 0
  offsideConstraints : Nat := 0
  commentConstraints : Nat := 0
  redundantBreaks : Nat := 0
  /-- Commands the toolchain's own formatter could not lay out, emitted as their source bytes.
  See `command`'s two degradation arms. -/
  verbatimCommands : Nat := 0
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One direct native-layout result before whole-module rendering and validation. -/
structure Document where
  document : Doc
  trace : FormatterTrace
  metrics : Metrics
  deriving Inhabited

private def sourceRange? (stx : Lean.Syntax) : Option SourceRange := do
  let range ← stx.getRange?
  return ⟨range.start.byteIdx, range.stop.byteIdx⟩

private def slice (source : String) (range : SourceRange) : String :=
  (String.fromUTF8? (source.toUTF8.extract range.start range.stop)).getD ""

private def isDocSyntax (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Command.docComment || kind == ``Lean.Parser.Command.moduleDoc

-- A comment has no interior layout. Lean's derived formatter spells a doc comment as its opening
-- token, a `Format.line`, and its body, so at a narrow width it would break a comment across the
-- separator its source never had. The whole comment is therefore one exact island covering both
-- terminals, and the marker replaces the body: the island's own bytes are the only rendering.
private def docSyntaxBody? (stx : Lean.Syntax) : Option Lean.Syntax := do
  guard (isDocSyntax stx.getKind)
  stx.getArgs[1]?

private partial def terminalsFrom (source : String) (stx : Lean.Syntax)
    (result : Array Terminal := #[]) : Array Terminal :=
  match stx with
  | .missing => result
  | .atom _ syntaxSpelling =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty then result
      else result.push { syntaxSpelling, sourceSpelling, range }
    | none => result
  | .ident _ raw _ _ =>
    match sourceRange? stx with
    | some range =>
      let sourceSpelling := slice source range
      if sourceSpelling.isEmpty then result
      else result.push { syntaxSpelling := raw.toString, sourceSpelling, range }
    | none => result
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => terminalsFrom source selected result
      | none => result
    else children.foldl (init := result) fun terminals child => terminalsFrom source child terminals

/- Verify what `terminalsFrom` assumes.

`Lean.Syntax.reprint` (`Syntax.lean:400`) reprints *every* alternative of a `choice` node and refuses
when they disagree. `terminalsFrom` takes `children[0]?` and assumes agreement, and so do the three
other walks below that spell `children[0]?` for the same reason — `selectedLeafRanges`,
`collectIndentedSequenceStarts`, and `collectOffsideConstraints`. That is four assumptions, not four
checks, on a node this repository records hitting 1 of 5 sampled mathlib modules. One gate at the
entry point makes the assumption true for all four rather than repeating the comparison four times.

What has to agree is what the adapter consumes: each alternative's ordered terminal sequence, compared
on `(range, sourceSpelling)`. Those two are not independent — `terminalsFrom` sets
`sourceSpelling := slice source range` — so the comparison reduces to range-sequence equality, and
carrying the spelling along only makes the refusal message readable. That reduction is the point: for
leaves that carry original `SourceInfo`, equal range sequences are exactly what makes `reprint`'s
`lead ++ val ++ trail` agree, so this checks the same property `reprint` does.

`syntaxSpelling` deliberately does not participate. An `atom` and an `ident` over the same bytes spell
it differently and emit the same source, so comparing it would refuse a file that is fine.

Every alternative is descended into, not only the first, so a disagreement nested inside an unselected
alternative is still found. `reprint` does the same.

What this gate does *not* cover is a question about a leaf's *constructor* rather than its bytes: two
alternatives could in principle spell identical source with an atom on one side and an ident on the
other. No walk below asks that today — `containsAtom` did, and went with the record-update rule that
used it — and no such node has been observed, so it is recorded here rather than guarded. -/
private def choiceSpelling (source : String) (alternative : Lean.Syntax) :
    Array (SourceRange × String) :=
  (terminalsFrom source alternative).map fun terminal => (terminal.range, terminal.sourceSpelling)

private def renderChoiceSpelling (terminals : Array (SourceRange × String)) : String :=
  String.intercalate " " (terminals.toList.map fun (range, text) => s!"{range.start}:{repr text}")

private partial def choiceDisagreement? (source : String) (stx : Lean.Syntax) :
    Option (SourceRange × Nat × String × String) :=
  match stx with
  | .node _ kind children =>
    let here :=
      if kind == Lean.choiceKind then
        match children[0]? with
        | none => none
        | some first =>
          let expected := choiceSpelling source first
          match
            (children.extract 1 children.size).findIdx?
              (fun alternative => choiceSpelling source alternative != expected) with
          | some offset =>
            match children[offset + 1]? with
            | none => none
            | some actual =>
              some
                (sourceRange? stx |>.getD ⟨0, 0⟩, offset + 1, renderChoiceSpelling expected,
                  renderChoiceSpelling (choiceSpelling source actual))
          | none => none
      else none
    match here with
    | some found => some found
    | none => children.findSome? (choiceDisagreement? source)
  | _ => none

/- The two interpolation kinds Lean defines: the interpolated string itself and its literal chunks.
Naming them is not the same as testing `kind.toString.contains "interpolatedStr"`, which this replaced:
that also matched every antiquotation kind derived from them, because an antiquotation kind is built by
appending to the kind it quotes. -/
private def interpolationKind (kind : Lean.Name) : Bool :=
  kind == Lean.interpolatedStrKind || kind == Lean.interpolatedStrLitKind

/- An antiquotation node no formatter in scope will accept, which is not the same as an antiquotation
node. The discriminator is the whole of it.

`mkAntiquot` builds the kind as `base ++ (if isPseudoKind then `pseudo else .anonymous) ++ `antiquot`,
so the base is recoverable from the kind. Whether Lean can format the node depends on what dispatches
on it:

- a **concrete parser's slot** formats its own antiquotation. `node.formatter` for `p` is wrapped in
  `withAntiquot.formatter (mkAntiquot.formatter' … p)`, which accepts `p.antiquot` exactly. `p` is a
  declared parser, so `env.contains base` holds.
- a **category position** formats only that category's own pseudo antiquotation.
  `categoryFormatterCore` (`Lean/PrettyPrinter/Formatter.lean:288-301`) wraps the dispatch in
  `withAntiquot.formatter (mkAntiquot.formatter' cat.toString cat (isPseudoKind := true))` and, when
  that backtracks, falls through to `formatterForKind stx.getKind` — which is `runForNodeKind`, which
  treats the kind as a declaration name. A category is not a declaration, so `env.contains base` fails
  and so does the lookup: `Unknown constant term.pseudo.antiquot`, `Unknown constant ident.antiquot`.

The second case is an upstream gap, not a lean-fmt one. `fun $_:ident ↦ $body` parses — `funBinder`
admits `ident` — and then cannot be re-printed, because the formatter asks the *category* first and
the node carries the *token's* kind. Nothing about the node says which category will ask.

So the test is what the base *is*: a syntax category or a token kind, which only a category position
can dispatch on, versus a parser declaration, whose own formatter accepts its own antiquotation. The
registered categories answer the first half directly. The second half is `Name.isAtomic`, because a
token kind is a one-component name — `ident`, `str`, `num` — and a parser declaration never is.

It is exact on the four shapes that pin it. `Lean.Parser.Command.declId.antiquot` in
`` `(def $name : Nat := 1) `` is neither, and must be left alone: protecting it is what made
`macro_rules | `(emit_custom $name) => …` fail with `uncaught backtrack exception`. `ident.antiquot`,
`term.pseudo.antiquot` and their kin are both, and must be protected.

Not `env.contains base`, which asks about the file's imports rather than about the grammar and gets the
same four shapes right only when they are imported. Every builtin parser is registered natively and
formats in an import-less module; `tests/fixtures/native-layout/Islands.lean` is one, and `env.contains` refuses
its `` `(def $name : Nat := 1) `` while every rule that matters says it is fine.

Protection is *in place*: the marker replaces the antiquotation and nothing else, because escalating to
the smallest enclosing node hands a quotation a leaf where its grammar wants a subtree, which is the
same failure from the other side. -/
private def antiquotationKind (categories : Lean.Parser.ParserCategories) (kind : Lean.Name) :
    Bool :=
  match kind with
  | .str base "antiquot" =>
    let base :=
      match base with
      | .str base "pseudo" => base
      | base => base
    categories.contains base || base.isAtomic
  -- The splice family is protected unconditionally. `mkAntiquotSplice` builds `$[p]suffix` nodes as
  -- `kind ++ \`antiquot_scope` and `withAntiquotSuffixSplice` builds `$x,*` nodes as
  -- `kind ++ \`antiquot_suffix_splice` (`Lean/Parser/Basic.lean:1856-1878`), and no formatter in the
  -- toolchain dispatches on either: `Lean/PrettyPrinter/Formatter.lean` wraps antiquotations only
  -- through `withAntiquot.formatter`, which accepts `p.antiquot` exactly, and the parser compiler
  -- generates no splice case. Every dispatch that reaches one falls through to `formatterForKind` and
  -- dies as `Unknown constant sepBy.antiquot_scope` — measured on a `` `(tactic| ($[have := $h];*); …) ``
  -- macro body. Unlike the `antiquot` case there is no declared-parser slot to leave alone, so there is
  -- no base test: the kind alone decides.
  | .str _ "antiquot_scope" => true
  | .str _ "antiquot_suffix_splice" => true
  | _ => false

private def sourceDataKind (kind : Lean.Name) : Bool :=
  kind == Lean.interpolatedStrKind

/- A quotation whose body was parsed by a parser named at runtime, which Lean's formatter cannot
recover. This is the second ordinary upstream bug the module works around.

`Lean.Parser.Term.dynamicQuot` — `` `(cat| body) ``, `Lean/Parser/Term.lean:1033` — parses `body` with
`parserOfStack 1`, which reads the parser's name off the syntax stack. At parse time that is the
`ident`: `parserOfStackFn` takes `stack.get! (stack.size - offset - 1)` and the stack top is the
`"| "` atom (`Lean/Parser/Extension.lean:772`). At format time `parserOfStack.formatter` takes
`parents.back!.getArg (idxs.back! - offset)` (`Lean/PrettyPrinter/Formatter.lean:319`), and
`idxs.back!` is the index of the argument being visited, so the same `offset` lands one slot short —
on the `"| "` atom rather than the `ident`. The formatter then asks `formatterForKind` about an atom,
whose kind is `Name.mkSimple "|"`, and the command dies as `Unknown constant «|»`. Four of the
seventy-two sampled mathlib modules refused on exactly that.

Keying on this kind is keying on the *only* call site of `parserOfStack` in the toolchain, so no other
node can reach that formatter; it is not a shape added because it was seen to fail. The body's category
is chosen at parse time, so there is no grammar here whose layout lean-fmt could validate either. The
quotation is therefore one exact island; its source bytes are its whole rendering. -/
private def dynamicQuotationKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Term.dynamicQuot

/- A marker stands in for protected syntax while the formatter runs, so it has to be a spelling the
formatter cannot confuse with a real token. `command` rejects a source that already spells one rather
than trusting the shape to be unusual; see `markerCollision?`. -/
private def markerFor (range : SourceRange) : String :=
  s!"leanFmtExact{range.start}x{range.stop}"

/- A placeholder replaces the syntax it protects, so it must keep that syntax's leaf constructor:
Lean's formatter for a literal token calls the atom printer and refuses an identifier with
`not an atom`. Only a protected interior node, which has no single spelling of its own, becomes an
identifier. -/
private def placeholder (protected? : Lean.Syntax) (info : Lean.SourceInfo) (marker : String) :
    Lean.Syntax :=
  match protected? with
  | .atom .. => .atom info marker
  | _ => .ident info marker.toRawSubstring marker.toName []

private def stripTriviaInfo : Lean.SourceInfo → Lean.SourceInfo
  | .original leading position trailing endPos =>
    .original { leading with stopPos := leading.startPos } position
      { trailing with stopPos := trailing.startPos } endPos
  | info => info

private partial def withoutTrivia : Lean.Syntax → Lean.Syntax
  | .node info kind children => .node (stripTriviaInfo info) kind (children.map withoutTrivia)
  | .atom info value => .atom (stripTriviaInfo info) value
  | .ident info raw value preresolved => .ident (stripTriviaInfo info) raw value preresolved
  | .missing => .missing

private structure ProtectedSyntax where
  stx : Lean.Syntax
  islands : Array ExactIsland := #[]
  pendingEnvelope : Bool := false
  deriving Inhabited

private def exactPlaceholder (source : String) (stx : Lean.Syntax) (info : Lean.SourceInfo) :
    ProtectedSyntax :=
  match sourceRange? stx with
  | some range =>
    let marker := markerFor range
    { stx := placeholder stx info marker
      islands := #[{ marker, range, text := slice source range }] }
  | none => { stx }

/- A leaf whose own bytes begin or end with whitespace, which no ordinary token's can.

A token's range stops where its trivia begins, so leading or trailing whitespace *inside* the range is
whitespace the parser captured as payload rather than skipped as separator — and a parser that
captures it is one whose token the surrounding gap belongs to. `ProofWidgets.Jsx.jsxText` is the case
this was measured on: `<div> <strong …>⊢ </strong> …` spells four of them, three pure whitespace, and
the adapter's boundary in front of each is a layout decision that reparses *into* the token. This was
caught by the `tokens` gate as `token 451 (ProofWidgets.Jsx.jsxText) changed spelling`.

Protecting the leaf alone does not fix it, which is why this returns `pendingEnvelope` rather than an
island: an island keeps the boundary in *front* of it, which is exactly the gap in question. The
enclosing node has to be the island — the escalation an interpolated string already uses.

A leaf whose whitespace is interior only — `<div>hello world</div>` — is not covered, because nothing
in its bytes distinguishes it from a string literal, which is common and must not escalate. Lean
publishes no protocol for whitespace-significant syntax (there is no attribute, and the kind is a
downstream library's), so this is what can be decided from the leaf itself. -/
private def whitespaceEnvelope (text : String) : Bool :=
  match text.front?, text.back? with
  | some first, some last => first.isWhitespace || last.isWhitespace
  | _, _ => false

private partial def protectSourceDataFrom (categories : Lean.Parser.ParserCategories)
    (source : String) : Lean.Syntax → ProtectedSyntax
  | .missing => { stx := .missing }
  | .atom info spelling =>
    let stx := Lean.Syntax.atom info spelling
    match sourceRange? stx with
    | some range =>
      let text := slice source range
      if text.contains '\n' then exactPlaceholder source stx info
      else if whitespaceEnvelope text then { stx, pendingEnvelope := true } else { stx }
    | none => { stx }
  | .ident info raw value preresolved =>
    let stx := Lean.Syntax.ident info raw value preresolved
    match sourceRange? stx with
    | some range =>
      let text := slice source range
      if text.contains '\n' then exactPlaceholder source stx info
      else if whitespaceEnvelope text then { stx, pendingEnvelope := true } else { stx }
    | none => { stx }
  | .node info kind children =>
    let stx := Lean.Syntax.node info kind children
    if let some body := docSyntaxBody? stx then
      match sourceRange? stx with
      | some range =>
        let marker := markerFor range
        { stx := .node info kind (children.set! 1 (.atom body.getHeadInfo marker))
          islands := #[{ marker, range, text := slice source range, comment := true }] }
      | none => { stx }
    else
      if sourceDataKind kind then { stx, pendingEnvelope := true }
      else
        if antiquotationKind categories kind then exactPlaceholder source stx info
        else
          if dynamicQuotationKind kind then
            -- Protected here, not escalated: the quotation is a complete term, so a marker leaf standing in
            -- for it keeps the grammar around it intact and the island as small as the defect.
            exactPlaceholder source stx info
          else
            if
                kind == Lean.choiceKind &&
                  (children.any (·.isOfKind `«term{_}») &&
                    children.any (·.isOfKind ``Lean.Parser.Term.structInst)) then
              -- A `{a.1.2}` brace ties between the anonymous constructor and the structure instance, and
              -- the formatter spells only the LAST alternative of a `choice` (`Formatter.lean:217,292`,
              -- whose own TODO admits the elaborator's answer is the one it needs). With `structInst`
              -- last, the spelling is the structure instance's: `{ a.1 .2 }`, a space inside the numeric
              -- projection -- which does not parse at all ("unsupported structure instance field
              -- abbreviation, expecting identifier", `AbstractEmbedding.lean`'s diagnostics refusal).
              -- The elaboration that accepted the file picked the other side, so there is no spelling
              -- this formatter can produce from the node: the island spells the source's bytes, whose
              -- reparse ties the same way the original's did.
              exactPlaceholder source stx info
            else
              let (rewrittenChildren, islands, pending) :=
                children.foldl (init := (#[], #[], false))
                  fun (rewritten, islands, pending) child =>
                  let child := protectSourceDataFrom categories source child
                  (rewritten.push child.stx, islands ++ child.islands,
                    pending || child.pendingEnvelope)
              let rewritten := Lean.Syntax.node info kind rewrittenChildren
              if pending then
                -- Every range here is read off `stx`, the node as the source wrote it, never off `rewritten`.
                -- A placeholder is a leaf built from its node's own `SourceInfo`, which for an interior node is
                -- `.none`, so a subtree that already escalated contributes no position at all:
                -- `Syntax.getRange?` on `rewritten` then stops at the last leaf the rewrite left intact.
                -- `` `($(_) fun $x:ident ↦ $b) `` escalated its `basicFun` first, so the enclosing application
                -- measured 112:120 — `$(_) fun` — while the marker it produced stood for all of 112:136. The
                -- island was then too small to cover the terminals its own marker replaced, and the transform
                -- refused with `exact island 112:120 cuts terminal ...`. Escalation must be able to run twice.
                match sourceRange? stx with
                | some range =>
                  let pendingRanges := children.filterMap sourceRange?
                  let strictlyEncloses :=
                    pendingRanges.any fun child =>
                      range.start < child.start || child.stop < range.stop
                  let transparentEnvelope :=
                    kind == `null || kind == Lean.choiceKind || interpolationKind kind
                  -- `stx` and `rewritten` are both nodes, so they pick the same placeholder constructor; only
                  -- the range differs, and the island's bytes are the original node's.
                  if strictlyEncloses && !transparentEnvelope then exactPlaceholder source stx info
                  else { stx := rewritten, islands, pendingEnvelope := true }
                | none => { stx := rewritten, islands, pendingEnvelope := true }
              else { stx := rewritten, islands }

private def protectSourceData (categories : Lean.Parser.ParserCategories) (source : String)
    (stx : Lean.Syntax) : Lean.Syntax × Array ExactIsland :=
  let result := protectSourceDataFrom categories source stx
  if result.pendingEnvelope then
    -- The original node again, for the reason spelled at the escalation site above: `result.stx` may
    -- have lost the positions a nested placeholder replaced, and the island covers what the marker
    -- stands for, not what survived the rewrite.
    let result := exactPlaceholder source stx stx.getHeadInfo
    (result.stx, result.islands)
  else (result.stx, result.islands)

private partial def guardedSequenceRanges (stx : Lean.Syntax) (ranges : Array SourceRange := #[]) :
    Array SourceRange :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqIndent then
    match sourceRange? stx with
    | some range => ranges.push range
    | none => ranges
  else stx.getArgs.foldl (init := ranges) fun ranges child => guardedSequenceRanges child ranges

private partial def guardedPipeRanges (stx : Lean.Syntax) (ranges : Array SourceRange := #[]) :
    Array SourceRange :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqIndent then ranges
  else
    match stx with
    | .atom _ "|" =>
      match sourceRange? stx with
      | some range => ranges.push range
      | none => ranges
    | .node _ _ children =>
      children.foldl (init := ranges) fun ranges child => guardedPipeRanges child ranges
    | _ => ranges

private partial def selectedLeafRanges (stx : Lean.Syntax) (ranges : Array SourceRange := #[]) :
    Array SourceRange :=
  match stx with
  | .atom .. | .ident .. =>
    match sourceRange? stx with
    | some range => ranges.push range
    | none => ranges
  | .node _ kind children =>
    if kind == Lean.choiceKind then
      match children[0]? with
      | some selected => selectedLeafRanges selected ranges
      | none => ranges
    else children.foldl (init := ranges) fun ranges child => selectedLeafRanges child ranges
  | .missing => ranges

private partial def collectReturnTermStarts (stx : Lean.Syntax) (starts : Array Nat := #[]) :
    Array Nat :=
  let starts :=
    if stx.isOfKind ``Lean.Parser.Term.doReturn then
      match (selectedLeafRanges stx)[1]? with
      | some range => starts.push range.start
      | none => starts
    else starts
  stx.getArgs.foldl (init := starts) fun starts child => collectReturnTermStarts child starts

/- Every `sepByIndent` list whose separators are written out begins on its own line.

`sepByIndent` (`Lean/Parser/Extra.lean:202-204`) is `withPosition (sepBy (checkColGe >> p) …)`, so the
column it measures every later item against is the column of the *first* item. Its formatter
(`:211-223`) spells that in one of two ways, and which one it picks is a property of the source:

- `hasNewlineSep` — some separator slot is an empty null node, meaning the source separated two items
  by a line break rather than by the written separator. The formatter then emits `pushWhitespace "\n"`
  for each such slot and one `pushAlign (force := true)` before the list. The align pads to the current
  indent and every `"\n"` lands on it, so the first item and every later one share one column and the
  parser's reference column is satisfied by construction. Nothing to correct.
- otherwise — every separator is written (`,` or `;`), the formatter emits none of that, and the list
  is laid out by the soft `line`s the enclosing document already has. Those `line`s break to the
  enclosing `nest`, which has no reason to equal the column the *first* item happens to land on. Break
  one and not the one before the first item, and a later item is dedented below the reference column.

The correction for the second case is one boundary: break before the first item, so the first item
lands on the same `nest` every later break lands on. `hard` is what makes this sound rather than
merely likely — it cannot lengthen a line, so unlike a `flat` join it cannot push a break somewhere
else and needs no accompanying flatten. Everything inside the list still lays itself out.

But "has no reason to equal" is not "does not equal", and forcing the boundary where the two already
coincide is a gratuitous break. They coincide exactly when the first item's unbroken column *is* the
`nest` the separators break to, and only two shapes of carrier can pull them apart:

- A carrier that opens with a delimiter and wraps its list in that delimiter's own group. `structInst`
  is the one: `{ ` is `format.indent` columns wide, and `fill` breaks the line *before* a group it
  cannot fit rather than inside it, so `{` reaches the current indent before any comma breaks and the
  first field sits exactly on the `nest`. Verified by rendering an inline record at widths 100, 90, 80
  and 70 — the fields stay aligned at every one. Content between the delimiter and the first item is
  what breaks it: `{ base with ` is wider than the indent, so the fields sit right of the `nest` and a
  later comma dedents below them. The test is therefore *whether a terminal intervenes*, not whether
  the intervening terminal is `with`.
- A carrier `ppAllowUngrouped` left outside any group of its own. `Term.byTactic` (`Term.lean:108`) is
  the only one that carries a `sepByIndent` list — `categoryParser.formatter`
  (`Formatter.lean:302-310`) skips its `fill` wrapping, so `by` and its tactics are direct children of
  whatever `nest` encloses the declaration. The separators then break to *that* indent, which is
  unrelated to the column `by` happens to sit at, so the two never reliably coincide and the boundary
  is always needed. This is the same mechanism `collectUngroupedBodyStarts` turns to the other
  purpose; the two are the joined `:= by` and the broken `by`-to-first-tactic halves of one line.

Being ungrouped is a property of the *carrier*, not of the sequence's own kind, and the two come apart
because `tacticSeq1Indented` is what `tacticSeq` reduces to everywhere — under `by`, and equally under
`(`, `·`, `case`, `try`. `ppAllowUngrouped` is `skip` (`Extra.lean:268`), so it leaves no node to test
for; what stands in for it is the parent, and the four core parsers that carry it (`Do.lean:326`,
`Term.lean:108,387`, `Extra.lean:262`) put a `sepByIndent` list under exactly one of them. Every other
parent wraps the sequence in its own `fill`, which makes it the delimited case and `delimiterIntervenes`
the right question — `(` alone does not intervene and needs no boundary, `case h => ` does and gets
one. Reading the kind as ungrouped wherever it appeared forced a break into `constructor <;> (skip; rfl)`
that the document had nowhere to put: one `nest` past the separators rather than on them, leaving `rfl`
to reparse outside the parentheses. `Archive/Arithcc.lean` refused for it.

`whereDecls` and the two bracketed sequences are the delimited case; no terminal can intervene in any
of them, so the test says no and they are walked anyway rather than assumed. The one carrier not
walked is `structInstFields` spelled after `where` (`Command.lean:174`) instead of inside `{ }`:
`where` is its delimiter and the list is the very next thing, so nothing can come between them and
there is no shape for the test to find.

Which nodes carry such a list is a fact about Lean's grammar, not a list of shapes observed to fail.
These are the `sepByIndent`/`sepBy1Indent` call sites reachable from a Lean source file:
`structInstFields` (`Term.lean:354`, `Command.lean:174`, `Elab/StructInst.lean:42,58`),
`tacticSeq1Indented` and `tacticSeqBracketed` (`Term/Basic.lean:75,79`), `convSeq1Indented` and
`convSeqBracketed` (`Init/Conv.lean:25-26`), and `whereDecls` (`Term.lean:741-742`). In each the list
is the first `null` child, because every other child is an atom or follows it.

This replaces a rule that fired on `{ base with … }` alone and fired unconditionally. Both halves were
wrong. `with` was a proxy for the intervening terminal, and it missed the tactic sequence entirely;
firing unconditionally added a second break to lists the `align` had already positioned, which is how
a record update whose fields the source spelled on their own lines acquired a blank line above the
first field and left it indented one level past its siblings. -/
private def ungroupedSequenceKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Tactic.tacticSeq1Indented ||
    kind == ``Lean.Parser.Tactic.Conv.convSeq1Indented

private def delimitedSequenceKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Tactic.tacticSeqBracketed ||
    kind == ``Lean.Parser.Tactic.Conv.convSeqBracketed ||
    kind == ``Lean.Parser.Term.whereDecls

/- `sepByIndent.formatter`'s own test, transcribed: an odd slot holding an empty null node is a
separator the source spelled as a line break. The final slot is excluded there because a trailing
separator is skipped rather than emitted, and it is excluded here for the same reason. -/
private def hasNewlineSeparator (list : Lean.Syntax) : Bool :=
  let args := list.getArgs
  args.size != 0 &&
    (List.range args.size).any fun index =>
      index % 2 == 1 && args[index]!.matchesNull 0 && index != args.size - 1

/- The mirror: a separator the source *wrote*, `sepByIndent`'s `"; "` rather than a row break.
`hasNewlineSeparator` is not its negation -- a one-item list satisfies neither, having no
separator slot at all. -/
private def hasWrittenSeparator (list : Lean.Syntax) : Bool :=
  let args := list.getArgs
  (List.range args.size).any fun index =>
    index % 2 == 1 && !args[index]!.matchesNull 0 && index != args.size - 1

/- `structInstFields` is the list's own wrapper, so the delimiter and anything between it and the list
belong to the *parent*. Every other delimited carrier holds its own delimiter, and this walk sees the
node that holds the list either way — so the terminals to count are the ones under `owner` that start
before the list does, and "more than the delimiter itself" is more than one of them. -/
private def delimiterIntervenes (owner list : Lean.Syntax) : Bool :=
  match (selectedLeafRanges list)[0]? with
  | some first => ((selectedLeafRanges owner).filter (·.start < first.start)).size > 1
  | none => false

/- The nodes that can sit between a `sepByIndent` list and the parser that decides how it is laid out.
`Tactic.tacticSeq` and `Conv.convSeq` are the choice between the bracketed and the indented spelling, a
`null` node is a parser's own bookkeeping, and `Term.byTactic'` (`Term.lean:117`) is `byTactic` with
the `ppAllowUngrouped` removed and a different kind, which Lean's own comment says exists only so
`show` and `suffices` can be find-replaced safely. None of the four is registered in a parser category,
so `categoryParser.formatter` never wraps one in a `fill` and none of them owns a group: the group
belongs to whatever encloses them, and that is the node the walk carries. Confirmed against the live
parser environment — `Term.byTactic` and `Term.show` are in a category's `kinds`, `Term.byTactic'` and
`Tactic.tacticSeq` are not. -/
private def sequenceWrapperKind (kind : Lean.Name) : Bool :=
  kind == ``Lean.Parser.Tactic.tacticSeq || kind == ``Lean.Parser.Tactic.Conv.convSeq ||
    kind == ``Lean.Parser.Term.byTactic' ||
    kind == Lean.nullKind

/- Whether a token opens its source row (only whitespace before it on the row). -/
private def opensSourceRow (source : String) (start : Nat) : Bool :=
  let lineStart :=
    (slice source ⟨0, start⟩).revFind? (· == '\n') |>.map (·.offset.byteIdx + 1) |>.getD 0
  (slice source ⟨lineStart, start⟩).trimAscii.copy.isEmpty

/- LAY-ALIGN-COMPENSATION -- the three collectors below, and what to delete when the toolchain moves.

`Std.Format.spaceUptoLine`'s `align` case (`Init/Data/Format/Basic.lean`) measures in *budget*
coordinates -- `w = width - column`, `m = width - indent` -- while `be` renders in *column*
coordinates, so the one case that has to reason about position asks the inverse question: it charges
`column - indent` phantom columns and keeps measuring where the renderer would break. Every group
that runs on into a `sepByIndent`'s `align(true)` therefore flattens as a function of the margin
rather than of the row being laid out -- shattering at roughly half the margin whatever the content
costs. That is the whole reason the collectors below force boundaries the document should have
chosen for itself, and it is why none of them is a style rule.

Filed as leanprover/lean4#14692 (the stranded space and the blank row) and #14715 (the measure),
fixed together by leanprover/lean4#14693. This tree pins `leanprover/lean4:v4.33.0-rc2`; the fix
lands in 4.34. After that bump the document answers correctly on its own, and a boundary forced here
stops being conservative and starts over-breaking. So each of these is a *deletion* on the bump, not
a re-tuning.

The removal test, one clause at a time rather than one collector at a time:

    lake test -- --suites declaration-formatter native-layout command-formatter term-formatter
    lake lint

A pass means the document now decides it, and the clause was the compensation. A failure means it
was answering something the measure never entered, and it stays. Two clauses are known to be in the
second group and must not be deleted with their collector:

- `collectUngroupedBodyStarts`' `declaration-body = "same-line"` half. That is a user-configured
  preference answered by `joinedBodyFits`, not a repair. Only the unconditional `:= by` join goes.
- `collectIndentedSequenceStarts`' delimited clause, `!hasNewlineSeparator && delimiterIntervenes`.
  It positions a written-separator list whose first item follows the opening delimiter, a column
  question the fit measure never entered. Only the `ungrouped` clause is the compensation, and it
  goes together with the `:= by` join that provoked it.

`collectWhereStarts` is undecided and the test has to settle it, in two parts. Its `.flat` at the
`where` is plainly the compensation, and `whereJoinFits` exists only to bound it -- but the bound is
not itself compensation, because `where` genuinely cannot always be given a row (this suite's
`unbreakableReturnRow`), so a corrected document still needs some form of it. Its `.hard` at the
first field substitutes a real `text "\n"` for the `align` so the measurement stops at the row's
real end; under the corrected measure the `align` reports the break itself, which would make the
substitution redundant, but that has not been verified against this tree's corpus.

`declaration-where = "next-line"` and `declaration-body` are preferences and outlive all of it. -/
private partial def collectIndentedSequenceStarts (source : String) (stx : Lean.Syntax)
    (carrier? : Option Lean.Syntax := none) (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    -- `(owner, holder)`: the node whose terminals include the opening delimiter, and the node that
    -- holds the list. They differ for `structInst`, whose `{` is a sibling of the field list, and for
    -- an indented sequence, whose delimiter belongs to whatever carries it. The `whereStructInst`
    -- carve-out this collector used to carry is retired (LAY-INDENTED-SEQUENCES): its `.hard`
    -- forced the fields off the `where` row because a first field joining that row set the
    -- reference column there and a later `;` broke to the fields' nest below it -- exactly the
    -- positioning the anchor interval now owns, so the delimited exemption reads the same for
    -- both spellings of `structInstFields` and the fourth tuple slot is gone with it. The
    -- `singletonMulHom` motivation survives in git history.
    let target? : Option (Lean.Syntax × Lean.Syntax × Bool) :=
      if kind == ``Lean.Parser.Term.structInst || kind == ``Lean.Parser.Command.whereStructInst then
        (children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields)).map fun fields =>
          (stx, fields, false)
      else
        if delimitedSequenceKind kind then some (stx, stx, false)
        else
          if ungroupedSequenceKind kind then
            carrier?.map fun carrier => (carrier, stx, carrier.isOfKind ``Lean.Parser.Term.byTactic)
          else none
    let starts :=
      match target? with
      | some (owner, holder, ungrouped) =>
        match holder.getArgs.find? (·.isOfKind Lean.nullKind) with
        -- One item has no separator to break at the wrong column, so it needs no boundary; two do.
        | some list =>
          -- The ungrouped (`by`) case fires whatever the source spelled. A newline-separated
          -- sequence needs the boundary just as much: what stands before its first item is
          -- `sepByIndent`'s `align(true)`, and an `align(true)` is not a line to the enclosing
          -- fill groups' fit measurement -- its `spaceUptoLine` case (`Init/Data/Format/Basic.lean`)
          -- charges `column - indent` phantom columns and keeps measuring. Once the `:= by` join
          -- removes the soft `line` that used to stop that measurement, every signature group
          -- measures straight through `by` into the phantom and shatters, however short the
          -- signature: `theorem multiline (n m : ℕ) (h : n = m) : n = m ∧ n = m := by` broke at
          -- the `:` under a three-line proof. Replacing the align with the `hard` boundary's real
          -- `text "\n"` spells the same bytes the align would have (its render case is
          -- `pushNewline indent` whenever the column is already past the indent, which `by `
          -- guarantees) and stops the measurement where the row actually ends. The delimited case
          -- keeps the exemption: its first item follows the opening delimiter on the same row, so
          -- a written-separator list there is already positioned.
          if
              list.getArgs.size >= 3 &&
                (ungrouped ||
                  (!hasNewlineSeparator list &&
                    match (selectedLeafRanges list)[0]? with
                    | _ => delimiterIntervenes owner list)) then
            match (selectedLeafRanges list)[0]? with
            | some range => if starts.contains range.start then starts else starts.push range.start
            | none => starts
          else starts
        | none => starts
      | none => starts
    let carrier? := if sequenceWrapperKind kind then carrier? else some stx
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectIndentedSequenceStarts source child carrier? starts
  | _ => starts

/- A focusing `·` keeps its first tactic on its own line.

`syntax (name := cdot) cdotTk tacticSeqIndentGt : tactic` (`Init/NotationExtra.lean:322`) has no
formatter annotation of its own, so the derived one spells `·`, a soft `line`, and the sequence's
fill. A sequence that cannot stay flat -- any `calc`, any `exact` whose term breaks -- fires that
line and the `·` is left alone on its row. Mathlib's cdot linter flags exactly that shape: a
`cdotTk` whose trailing whitespace holds a newline, with the instruction to merge the dot with the
next line. `collectIndentedSequenceStarts` cannot help: it forces breaks at sequence starts, and
this boundary needs the opposite.

Joining only the *first* terminal is always safe. A tactic sequence opens with a keyword or
identifier atom, so the joined line gains a handful of columns over the `·` itself and cannot
overflow; everything after it keeps its own breaks and nests (`· exact` still lets a long term
break below). The continuation items are untouched: they were already emitted one nest level past
the `·`, which is where mathlib puts them, and `tacticSeqIndentGt` reparses them against the dot's
column. The term-level `·` (`Term.cdot`, `(· + ·)`) is a different kind and is not matched. -/
private partial def collectCdotStarts (stx : Lean.Syntax) (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.cdot then
        match children[1]? with
        | some sequence =>
          match (selectedLeafRanges sequence)[0]? with
          | some range => if starts.contains range.start then starts else starts.push range.start
          | none => starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectCdotStarts child starts
  | _ => starts

/- `:= by` keeps the `by` on the `:=` line.

`Term.byTactic` (`Term.lean:108`) is `ppAllowUngrouped >> "by " >> Tactic.tacticSeqIndentGt`, and that
mechanism works: `categoryParser.formatter` (`Formatter.lean:302-310`) skips its `fill` wrapping when
`isUngrouped`, so `ppHardLineUnlessUngrouped` (`Extra.lean:304-308`) emits a soft `line` rather than a
hard `"\n"`. The document holds `text" :=" line text"by"`.

What breaks it is one layer below, in `Std.Format` itself. `pushGroup`
(`Init/Data/Format/Basic.lean:243-249`) measures the group *and the enclosing remainder*, and a
multi-step tactic sequence carries an `align(true)` whose `spaceUptoLine` case (`:165-170`) contributes
padding at narrow widths instead of stopping the measurement. So the soft line breaks as a function of
the width rather than of the line being laid out: measured threshold 136 for a line that occupies 50
columns through `by`. `LeanFmt/Doc.lean` hands registered documents to `Std.Format.prettyM` on purpose,
so this adapter does not own that decision and must not reimplement the renderer to take it back. A
flat boundary at the `by` terminal is the whole repair.

Only `by`, not the other two parsers that declare `ppAllowUngrouped`. Measured: `fun` and a bare `do`
are already correct, so there is nothing to force. `by` is also the only one safe to force — its
tactic sequence begins its own line, so joining `by` to `:=` adds exactly three columns and cannot
overflow, where forcing `fun` flat would pull an arbitrarily long body onto the `:=` line. The one cost
is `:= by rfl` at a width narrow enough that Lean would have broken it; that stays joined, three
columns over a soft target the source spellings can already exceed.

`:= Id.run do` is deliberately not matched. Its body's head is an application, so `ppAllowUngrouped`
never applied and the hard line is correct.

`declaration-body = "same-line" asks for the other answer at the same boundary, for every body:
keep the body on the `:=` line when the joined spelling fits `line-width`, joining an
already-broken body that fits. `joinedBodyFits` is that fit question, answered on the source
spelling because a flat body's rendered bytes are the source's bytes. -/
private def layoutWhitespace (char : Char) : Bool :=
  char == ' ' || char == '\t' || char == '\n' || char == '\r'

private def flattenWhitespace (value : String) : String :=
  let step (acc : Bool × String) (character : Char) : Bool × String :=
    let (blank?, out) := acc
    if layoutWhitespace character then (true, out)
    else
      if blank? then
        (false, if out.isEmpty then out.push character else (out.push ' ').push character)
      else (false, out.push character)
  (value.foldl step (true, "")).2

/-- Would the line the `:=` sits on, joined through the body's end, fit `line-width`? The measure
is the source from that line's first column with every whitespace run collapsed to one space —
the same bytes the renderer spells for a flat body. Over-measurement (a nested `let`'s line
carries its whole command prefix) only ever declines a join, never accepts one that overflows.

The line's own indentation is counted separately because `flattenWhitespace` drops a *leading*
run rather than collapsing it — it has no column to collapse toward. Dropping it here instead
under-measured every joined line by its indent, the one direction that wrongly accepts: a
`declVal` at column 4 whose joined line ran 101 columns measured 97 and joined, and the renderer
then bought that back by breaking the signature it had already fitted. -/
private def joinedBodyFits (source : String) (width : Nat) (declVal body : Lean.Syntax) : Bool :=
  match sourceRange? declVal, sourceRange? body with
  | some valRange, some bodyRange =>
    let before := slice source ⟨0, valRange.start⟩
    let lineStart :=
      match before.revFind? (· == '\n') with
      | some position => position.offset.byteIdx + 1
      | none => 0
    let joined := slice source ⟨lineStart, bodyRange.stop⟩
    let indent := (joined.toList.takeWhile layoutWhitespace).length
    indent + (flattenWhitespace joined).length <= width
  | _, _ => false

private partial def collectUngroupedBodyStarts (declarationBody : DeclarationBody) (source : String)
    (width : Nat) (stx : Lean.Syntax) (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Command.declValSimple then
        -- `declBody` (`Command.lean:137-161`) is `lookahead … >> termParser`, and `lookahead` pushes
        -- nothing, so the body term is this node's second child with no wrapper in between.
        match children[1]? with
        | some body =>
          let join :=
            if body.isOfKind ``Lean.Parser.Term.byTactic then true
            else
              match declarationBody with
              | .nextLine => false
              | .sameLine => joinedBodyFits source width stx body
          if join then
            match (selectedLeafRanges body)[0]? with
            | some range => starts.push range.start
            | none => starts
          else starts
        | none => starts
      else
        if kind == ``Lean.Parser.Term.letIdDecl then
          -- The tactic-level `have`/`let`/`suffices` family spells its `:= body` through
          -- `Term.letIdDecl` (`tacticHave__` reduces to it), not `Command.declValSimple`, so the
          -- rule above never reaches it and the same over-measured soft `line` breaks
          -- `have h : T :=` / `by` however short the line. `letIdDecl` is
          -- `[letId, binders, type, :=, body]`, so the body is the last child; the join question
          -- is the same one.
          match children.back? with
          | some body =>
            if body.isOfKind ``Lean.Parser.Term.byTactic then
              match (selectedLeafRanges body)[0]? with
              | some range => starts.push range.start
              | none => starts
            else starts
          | none => starts
        else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectUngroupedBodyStarts declarationBody source width child starts
  | _ => starts

/- Can this declaration's `where` be joined to its signature at all? Unlike the rest of this section
the question is a safety valve, not a repair: a return type that fills its own continuation row
leaves no columns for `" where"` under any break placement, so some form of this measure survives
the upstream fix.

The measure is the whole header flattened -- the declaration's own first terminal through the
`where`, every whitespace run collapsed to one space -- and deliberately not the row the `where`
would land on, which is the tighter question and the one that cannot be asked from here. A
row-shaped measure is not invariant under its own output: `instance [Inhabited α] : Inhabited
(α × α) where` at `line-width` 20 declines, the renderer breaks the signature, the row carrying the
last token is then `      (α × α)`, which fits, so the second pass joins and
`ValidationGate.idempotence` refuses the file. A flattened header holds the same token sequence
however those tokens are currently broken, so its answer cannot move between passes.

`declModifiers` is what the header starts *after*, not at: a doc comment is syntax rather than
trivia, so a header taken from the command's first terminal carries the whole docstring into the
measure and every documented declaration declines. Attributes sit in the same node and are skipped
with it -- they occupy their own row ahead of the keyword, so they are not on the row being measured
either.

The cost is over-measurement, and it is real rather than theoretical: a header that overflows the
margin declines even where its final row had room, so `ProcessedModule.ofInitial` in
`LeanFmt/Analysis.lean` -- 103 columns flattened, 25 on the row the `where` would have joined --
spends three rows (`… :` / `ProcessedModule` / `where`) where two would do. Measuring the return
type instead buys that row back and was tried; it bounds the final row from *below*, so it also
accepts a join that overflows, which is `declaration-formatter`'s `unbreakableReturnRow`. Between a
spare row and a row over the margin, the margin is the contract and the row is a preference, so the
over-measuring direction stays. Declining forces nothing -- it leaves the boundary to the native
document. Declarations start at column zero, so the header carries no indent to add back. -/
private def whereJoinFits (source : String) (width : Nat) (headerStart whereStart : Nat) : Bool :=
  (flattenWhitespace (slice source ⟨headerStart, whereStart⟩)).length + " where".length <= width

/- Each `whereStructInst`'s `where`, paired with the first field that has to stop the measurement,
and whether `whereJoinFits` lets the two be joined.

`Command.whereStructInst` (`Command.lean:173`) is `ppIndent ppSpace >> "where" >> structInstFields
(sepByIndent …)`, so the only break in front of `where` is that `ppSpace`'s soft `line` -- and the
group holding it runs on into `sepByIndent`'s `align(true)`, the same phantom-`column - indent`
measurement `collectIndentedSequenceStarts` documents for `:= by`. The group shatters at roughly
half the margin whatever the signature costs: measured at `line-width` 100 a signature of 49
columns stayed joined and 50 broke, and at 60 the pair was 32 and 33. A rule that fires at half a
margin it was handed is not answering a width question, so this boundary replaces that
measurement rather than repairing the align -- which `collectIndentedSequenceStarts` already says
cannot be repaired from inside the document.

Joining removes the soft `line` that used to terminate the group's fit measurement, so on its own
the join only moves the shatter one boundary out: the signature then breaks at the `:` instead,
however short it is. That is the knock-on `collectIndentedSequenceStarts` records for `:= by`, and
it takes the same answer -- a real `text "\n"` at the sequence's first item, which spells the bytes
the `align` would have (its render case is `pushNewline indent` whenever the column is already past
the indent, which a `where ` ahead of it guarantees) and ends the measurement where the row really
ends.

The pairing fires exactly when the first field is going to open its own row, which is when the
source opens it there and no written `;` drags it back up. Both halves are load-bearing. What the
retired `whereForm` carve-out got wrong was firing on `;`-separated fields: there the first field
belongs on the `where` row -- the anchor puts it there and the later `;` breaks to its column --
and a `.hard` drives it off, which is `Offside.lean`'s `semiOps`, whose source opens the field's
row and whose output still hugs it. The source half is what `hasNewlineSeparator` cannot answer:
a one-field list has no separator to read, and without the boundary a `where` joined onto a long
signature pulls its only field up with it or breaks the signature at the `:` instead.

The field's row is the same question whether or not the `where` joined, so the caller applies that
half of the pairing under both answers. Beyond it the fields are untouched: they are
newline-separated and `collectStructInstFieldAnchors` re-bases their rows to the first field's
column, the `where` row included. -/
private partial def collectWhereStarts (source : String) (width : Nat) (stx : Lean.Syntax)
    (headerStart : Nat := 0) (starts : Array (Nat × Option Nat × Bool) := #[]) :
    Array (Nat × Option Nat × Bool) :=
  match stx with
  | .node _ kind children =>
    -- `declaration` is `declModifiers >> (definition <|> theorem <|> …)`, so the header the fit is
    -- measured from opens at the first terminal past the modifiers. A `whereStructInst` under no
    -- declaration at all keeps whatever header its ancestors set.
    let headerStart :=
      if kind == ``Lean.Parser.Command.declaration then
        match
          children.findSome? fun child =>
            if child.isOfKind ``Lean.Parser.Command.declModifiers then none
            else (selectedLeafRanges child)[0]?.map (·.start) with
        | some start => start
        | none => headerStart
      else headerStart
    let starts :=
      if kind == ``Lean.Parser.Command.whereStructInst then
        -- `ppSpace` pushes no syntax, so the node's first terminal is the `where` atom. Checked
        -- rather than assumed: this walk is the fifth to take a node's head, and the entry-point
        -- gate covers `choice` alternatives, not what a head spells.
        match (selectedLeafRanges stx)[0]? with
        | some range =>
          if slice source range != "where" then starts
          else
            let fieldStart? := do
              let fields ← children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields)
              let list ← fields.getArgs.find? (·.isOfKind Lean.nullKind)
              guard !(hasWrittenSeparator list)
              let first ← (selectedLeafRanges list)[0]?
              guard (opensSourceRow source first.start)
              some first.start
            starts.push
              (range.start, fieldStart?, whereJoinFits source width headerStart range.start)
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectWhereStarts source width child headerStart starts
  | _ => starts

/- Where a command nested inside another command begins.

A command starts at column zero. That is not a style preference this module chose: Lean's `command`
category is the module's top level, mathlib's whitespace linter reports any command that starts
elsewhere, and this module's acceptance bar says top-level declarations must remain at column zero.
A command written as a child of another command is still a command.

Lean's own document usually agrees, because the parser that embeds a command wraps the embedded one in
`ppDedent` — `open Nat in` spells `nest -2 [text" in" text"\n" <command>]`, which cancels the enclosing
node's `nest` exactly. `guardMsgsCmd` (`Init/Notation.lean:938`) does not: it spells
`" in" ppLine command`, and `categoryParser`'s formatter puts the embedded command inside the node's
`nest`, so `#guard_msgs in` indents the command after it by `format.indent`. The candidate then trips
mathlib's own `linter.style.whitespace` on `Mathlib/Tactic/Linter/ValidatePRTitle.lean`, which is a
`#guard_msgs` test, so the added warning also breaks the message the test asserts.

Rather than name the parsers that forgot, ask the *category*: `commandKinds` is the live parser
environment's `command` category, so a node is a command exactly when the parser that could produce it
is registered in it. Nothing here is keyed on a shape observed to fail, and a `dedented` boundary is
idempotent — it sets a column rather than adjusting one, so where Lean already dedented, as
`open … in` does, the correction spells the same newline the document did.

`rootStart` is what keeps this a *boundary* correction. `open Nat in def f := 0` is one node whose
first child is the `open` command itself, so the category test matches at the command's own first
terminal, where there is no boundary to correct — only the leading padding that separates this command
from the previous one. Constraining that spelled an extra blank line above every such command. A nested
command that begins where its root begins has nothing in front of it to move.

The whole range is collected, not only the start, because the boundary is half the correction. See
`interiorDedent` for the other half: the boundary sets the column of the row it opens, and every later
row of the same nested command is laid out from the embedding's `nest` until something cancels that
too. The range is the first selected leaf's start and the last one's stop, which is the span the walk
matches terminal indices against. -/
private partial def collectNestedCommandRanges (commandKinds : Lean.Parser.SyntaxNodeKindSet)
    (rootStart : Nat) (stx : Lean.Syntax) (root : Bool := true)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    let ranges :=
      if !root && commandKinds.contains kind then
        let leaves := selectedLeafRanges stx
        match leaves[0]?, leaves.back? with
        | some first, some last =>
          if first.start == rootStart || ranges.any (·.start == first.start) then ranges
          else ranges.push ⟨first.start, last.stop⟩
        | _, _ => ranges
      else ranges
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := ranges) fun ranges child =>
      collectNestedCommandRanges commandKinds rootStart child false ranges
  | _ => ranges

/- A guarded `let`'s bail-out, when the source already spells it on one line.

Lean's document spells this boundary as a literal `text" |" text"\n"`, a hard newline no width can
flatten, so `let some current := value | return 0` always breaks after the bar. The bar and its
bail-out are one construct: the bar reads as a guard only with the bail-out beside it.

`doLetElse` (`Lean/Parser/Do.lean:79-81`) spells two `doSeqIndent`s —
`(checkColGe >> " | " >> doSeqIndent) >> optional (checkColGe >> doSeqIndent)` — the guard body and
the rest of the enclosing block, which is why `collectOffsideConstraints` finds two sequences past the
bar and takes the *last* for its constraint. The bail-out is the first. The guard's own bar is a
direct child of the node: a pattern's alternative bars are inside the declaration child, and a `|`
deeper in the value is a match arm's.

Joining alone is width-unsound and was reverted once (`7e838a1`). `.text " "` cannot break, so the
renderer re-measures and breaks at the next soft line, which is now *inside* the bail-out at an
indentation the enclosing `nest` chose rather than the bar's column — and `many1Indent` saved the
bail-out's first token as the column every later item is measured against, so the continuation
reparsed as a sibling of the outer `do`. `Std.Format` has no shape that fixes this: `nest` is relative
to the current indent and `align` pads to it, so nothing in the algebra means "indent this subtree's
continuations to the column where it starts". The repair is instead to leave no soft line to break —
the boundary joins, and `flattenNative` removes every break inside the bail-out.

Only a bail-out the *source* already spells on one line is collected, and that one condition buys both
halves. It is what makes the flatten free of newline-emitting leaves: `sepByIndent.formatter`
(`Lean/Parser/Extra.lean:212-224`) is the sole producer of both `pushWhitespace "\n"` and
`pushAlign (force := true)` in the tree, and emits them only on its `hasNewlineSep` path, which is a
property of the source argument list. And it bounds the cost — a line the source already fit on is a
line, not a paragraph. Measured 2026-07-24 over this repository's own `LeanFmt/`: 102 guarded `let`s
already sit on one line, median 60 columns and widest 99, every body a short bail-out
(`return false`, `none`, `continue`, `.error "unknown directive scope"`); 10 more spell the bail-out
on the next line and are not collected. The idiom bounds it: a guarded `let` exists to leave, and
leaving is short. -/
/- The first `doSeqIndent` at or after `offset`, in traversal order -- the sequence a guard's own
bar introduces, when the guard has one. -/
private partial def firstDoSeqIndentAfter (offset : Nat) (stx : Lean.Syntax) : Option Lean.Syntax :=
  if stx.isOfKind ``Lean.Parser.Term.doSeqIndent then
    match sourceRange? stx with
    | some range => if offset <= range.start then some stx else none
    | none => none
  else
    stx.getArgs.foldl (init := none) fun found child =>
      match found with
      | some _ => found
      | none => firstDoSeqIndentAfter offset child

/- The statements a `doSeqIndent` holds -- the wrappers, not the separators. -/
private def doSeqItemCount (stx : Lean.Syntax) : Nat :=
  match stx.getArgs[0]? with
  | some wrapper => wrapper.getArgs.countP (·.isOfKind ``Lean.Parser.Term.doSeqItem)
  | none => 0

/- The guard's own `|`, wherever the declaration shape put it.

For `doLetElse` the bar is a direct child (the seventh). An arrow guard parses through `doPatDecl`
or `doIdDecl`, which wraps its `| bail-out` one `null` deeper (`let some x ← v | b` is
`doLetArrow[let, doPatDecl[…, ←, doExpr, null[|, doSeqIndent], null[doSeqIndent]]]`). Only that
wrapper counts: descending further reaches the value's own bars — `let r ← match … with | none => …`
wraps its match in `doMatch`, not `doExpr`, and joining a one-line match arm onto its bar is not
this rule (measured: `LeanFmt/Cli.lean`'s `match command.range? with` joined `| none => pure none`
under a descendant search that excluded only `doExpr`). -/
private def guardedPipe? (stx : Lean.Syntax) : Option Lean.Syntax :=
  match stx with
  | .node _ _ children =>
    match children.find? (· matches .atom _ "|") with
    | some pipe => some pipe
    | none =>
      match
        children.find? fun child =>
          child.isOfKind ``Lean.Parser.Term.doPatDecl ||
            child.isOfKind ``Lean.Parser.Term.doIdDecl with
      | some decl =>
        decl.getArgs.findSome? fun arg =>
          match arg with
          | .node _ _ args =>
            match args[0]? with
            | some first => if first matches .atom _ "|" then some first else none
            | _ => none
          | _ => none
      | none => none
  | _ => none

private partial def collectGuardBailouts (source : String) (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    let ranges :=
      if
          kind == ``Lean.Parser.Term.doLetElse || kind == ``Lean.Parser.Term.doLetExpr ||
            kind == ``Lean.Parser.Term.doLetMetaExpr ||
            kind == ``Lean.Parser.Term.doLetArrow then
        match guardedPipe? stx with
        | some pipe =>
          match sourceRange? pipe with
          | some pipeRange =>
            match firstDoSeqIndentAfter pipeRange.stop stx with
            | some sequence =>
              match sourceRange? sequence with
              | some range =>
                -- A two-statement bail-out (`| IO.eprintln "…"; return 2`) falsifies the
                -- one-line precondition above: `doSeqIndent`'s own formatter emits the
                -- inter-item break as a leaf flattening cannot remove, one line of source
                -- notwithstanding. Those keep the upstream break after the bar.
                if doSeqItemCount sequence != 1 || (slice source range).contains '\n' then ranges
                else ranges.push range
              | none => ranges
            | none => ranges
          | none => ranges
        | none => ranges
      else ranges
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := ranges) fun ranges child => collectGuardBailouts source child ranges
  | _ => ranges

/- An application argument spelled `{ … }` keeps the head's row.

`«term{_}»` is what an anonymous-constructor brace spells, and it is never the only way to read
`{a, b}`: `Lean.Parser.Term.structInst` reads it too. Which one the parser commits to depends on
where the brace starts. Hugged to the application head, mathlib's environment commits `«term{_}»`;
on its own line the two tie and the parser emits an uncommitted `choice` (probes, 2026-07-30: same
bytes, both environments, both layouts). A candidate that breaks between the head and such an
argument re-parses to a different syntax tree than the source spelled -- the structure gate
refused `EllipticCurve/Projective/Smooth.lean` for it, node count 3755 -> 3757, the one
divergence `«term{_}» -> choice` -- and even where the reparse agrees, the break belongs inside
the braces: that is the shape mathlib writes.

The correction is the `.flat` boundary in front of the `{`, the same spelling
`collectUnbreakableRuns` gives its runs: the head and the brace keep one row and the overflow
breaks after a comma, inside, where both parses still agree. The source precondition is the hug,
carried by the `brokenBefore` filter at the assembly site: a source that already started the
brace's row parsed to the `choice`, and joining it would change that tree the same way. Only the
`«term{_}»` shape is collected -- `{ a := 1 }` and `{ x | p x }` commit from either row
(probes, same day), so they need no rule. -/
private partial def collectBraceAppArgStarts (stx : Lean.Syntax) (starts : Array Nat := #[]) :
    Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Term.app then
        match children[1]? with
        | some args =>
          args.getArgs.foldl (init := starts) fun starts arg =>
            if arg.isOfKind `«term{_}» then
              match (selectedLeafRanges arg)[0]? with
              | some range =>
                if starts.contains range.start then starts else starts.push range.start
              | none => starts
            else starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectBraceAppArgStarts child starts
  | _ => starts

/- A committed anonymous-constructor brace keeps a newline inside.

`collectBraceAppArgStarts` above covers the boundary in front of the brace. This is the interior
half, and it exists because the parser's commitment between `«term{_}»` and `structInst` is
column-sensitive: the two tie on `{a, b, c}` whenever every field sits where `structInst`'s
`sepByIndent` can read it as a field -- flat, or on a continuation at or right of the first
field's column -- and `«term{_}»` wins exactly when a continuation starts *left* of that column
(probes, 2026-07-30, mathlib env: `inside-dedent` commits, `inside-align` and flat tie). A source
whose brace spells such a dedented break therefore holds a *committed* `«term{_}»` node, and a
candidate that joins the fields -- which is what the native document does the moment the
surrounding groups break and the brace's own group fits on its fresh row -- re-parses to an
uncommitted `choice` and the structure gate refuses. `Smooth.lean`'s `have hgen` was exactly
this: the type genuinely does not fit at width 100, the enclosing groups broke (Lean's own
formatter shatters the same way, probe-verified), the brace flattened, and the node kind moved.

The correction is one `columned` boundary at the first source-broken separator: an interior
newline spelled at the column the source spelled it at. The source's column is what made
`structInst`'s `checkColGe` fail there -- the continuation starts left of the first field, or the
source would hold a `choice` instead -- and spelling it again puts the candidate's continuation
left of the candidate's first field wherever the surrounding groups moved the brace (they move it
right, never left of its source row's own column). A plain `hard` newline is not enough: it lands
at the enclosing `nest`, and a shattered signature's `nest` can sit *right* of the first field's
column -- measured on `Smooth.lean`'s `have hgen`, where the `nest` spelled 12 against a first
field at 10 and the tie survived. Columns are counted in bytes, the parser's own arithmetic
(`String.Pos`); a non-ASCII field name could split that from the renderer's count, and the
structure gate is what refuses the rare miss rather than publishing a changed tree. A brace under
a `choice` node is the reverse case (the source already tied); it is not collected: joining or
breaking its interior both preserve the `choice`, so no rule is needed there, and a `hard`
newline could commit it the other way. -/
private partial def collectBraceInteriorBreaks (source : String) (stx : Lean.Syntax)
    (inChoice : Bool := false) (starts : Array (Nat × Nat) := #[]) : Array (Nat × Nat) :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == `«term{_}» && !inChoice then
        match children[1]? with
        | some list =>
          let args := list.getArgs
          -- Even slots are fields, odd slots separators; find the first separator the source
          -- spelled as a line break and hold the boundary in front of the field that follows it.
          let broken? :=
            (List.range args.size).findSome? fun index =>
              -- The gap that can hold the line break runs from one field's end over the separator
              -- to the next field's start, so even slots step by two.
              if index % 2 == 1 || index + 2 >= args.size then none
              else
                match (selectedLeafRanges args[index]!).back?,
                  (selectedLeafRanges args[index + 2]!)[0]? with
                | some itemEnd, some nextStart =>
                  if (slice source ⟨itemEnd.stop, nextStart.start⟩).contains '\n' then
                    -- The continuation's source column: bytes back to its line's start, the same
                    -- arithmetic the parser's `checkColGe` compares.
                    let before := slice source ⟨0, nextStart.start⟩
                    let lineStart :=
                      match before.revFind? (· == '\n') with
                      | some position => position.offset.byteIdx + 1
                      | none => 0
                    some (nextStart.start, nextStart.start - lineStart)
                  else none
                | _, _ => none
          match broken? with
          | some (start, col) =>
            if starts.any (·.1 == start) then starts else starts.push (start, col)
          | none => starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectBraceInteriorBreaks source child (kind == Lean.choiceKind) starts
  | _ => starts

/- The column of one source offset, in the parser's own byte arithmetic (`String.Pos`): the
offset less the start of its row, answered from the row-start table in logarithmic time. The
table replaces a per-call slice of the whole prefix, which made every boundary collector here
quadratic in the file's size. -/
private def sourceColumn (rowStarts : Array Nat) (offset : Nat) : Nat :=
  offset - rowStarts[Comments.rowOf rowStarts offset]!

/- A guarded `let`'s bail-out bar keeps its own row when the source gave it one.

The bar's native boundary sits in a group with the value, and once the value's interior breaks — a
multi-arm `match`, say — the group re-measures and the bar slides onto the value's last row. There it
reads as one more match arm (`| fail "…"` is a pattern-shaped as anything else), and the reparse
fails on the next statement with the bar's real owner nowhere in the message. The source always
spells the bar on its own row in this case, so the correction is a `hard` boundary at the bar: the
row the enclosing nest gives it sits at the guard's own column, left of any arm column, which is
exactly the relationship the source spelled. A bar the source spelled mid-row — the one-line guard
the join owns — opens no row and is not collected. -/
private partial def collectGuardBarBreaks (source : String) (stx : Lean.Syntax)
    (starts : Array Nat := #[]) : Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if
          kind == ``Lean.Parser.Term.doLetElse || kind == ``Lean.Parser.Term.doLetExpr ||
            kind == ``Lean.Parser.Term.doLetMetaExpr ||
            kind == ``Lean.Parser.Term.doLetArrow then
        match children.find? (· matches .atom _ "|") with
        | some pipe =>
          match sourceRange? pipe with
          | some pipeRange =>
            if opensSourceRow source pipeRange.start && !starts.contains pipeRange.start then
              starts.push pipeRange.start
            else starts
          | none => starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectGuardBarBreaks source child starts
  | _ => starts

private partial def structInstFieldsInOrder (stx : Lean.Syntax)
    (fields : Array Lean.Syntax := #[]) : Array Lean.Syntax :=
  match stx with
  | .node _ kind children =>
    if kind == ``Lean.Parser.Term.structInstField then fields.push stx
    else
      let children := if kind == Lean.choiceKind then children[0]?.toArray else children
      children.foldl (init := fields) fun fields child => structInstFieldsInOrder child fields
  | _ => fields

/- The anchor interval for a multi-field `structInstFields` list (LAY-STRUCT-INST): exactly the
fields, first to last. The renderer re-bases every break inside the interval to the column the
first field lands at, wherever the document places it -- mid-row after a `{` the source wrote
there included -- which is the invariant `structInstFields`'s `sepByIndent` grammar needs
(`Term.lean:354`). One structural fact says what the per-field `fieldRow` pins and the row-spread
explosion approximated row by row; their retirement is this prompt's checklist, and what keeps the
first field on a mid-row brace's row is that the interval *starts* there. -/
private partial def collectStructInstFieldAnchors (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    -- No anchor intervals inside a quotation. The quotation's template formats as ordinary
    -- syntax, but the template's own layout bakes its offside positions into the item groups
    -- (`Mathlib/Data/UInt.lean`'s `rw [...] rfl` ends its last item's group with a dedent-wrapped
    -- hard newline whose arithmetic assumes the ambient indent), so the interval has no
    -- break-free core to claim and the claim refuses. The pre-anchor offside machinery lays out
    -- quotation interiors; the island filter at resolve covers the whole-quotation case.
    if stx.isQuot then ranges
    else
      -- `Term.structInst` spells its fields inside `{ }`; `Command.whereStructInst` spells the same
      -- `structInstFields` list after `where` (`Command.lean:174`). The anchor is the same fact for
      -- both: every field row breaks at the first field's column, wherever the document places it --
      -- on the `where` row included, which is what the retired `whereForm` carve-out approximated.
      let ranges :=
        if
            kind == ``Lean.Parser.Term.structInst ||
              kind == ``Lean.Parser.Command.whereStructInst then
          match children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields) with
          | some fieldsNode =>
            let fields := structInstFieldsInOrder fieldsNode
            if fields.size < 2 then ranges
            else
              match (selectedLeafRanges fields[0]!)[0]?,
                (selectedLeafRanges fields.back!).back? with
              | some first, some last => ranges.push ⟨first.start, last.stop⟩
              | _, _ => ranges
          | none => ranges
        else ranges
      let children := if kind == Lean.choiceKind then children[0]?.toArray else children
      children.foldl (init := ranges) fun ranges child => collectStructInstFieldAnchors child ranges
  | _ => ranges

/- The anchor interval for a multi-item indented tactic sequence (LAY-INDENTED-SEQUENCES):
exactly the items, first to last. `tacticSeq1Indented` is `sepByIndentSemicolon(tactic)`
(`Lean/Parser/Tactic.lean`), so every item row -- a written `;` or a bare line break -- must land
at the first item's column or the reparse ends the sequence; the anchor states that where the
`.hard` break after `by` cannot: the break decision stays, and the anchor owns the column. The
`.hard` boundary in front of the first item is outside the interval, so the two compose the way
the struct-instance brace and fields did. -/
private partial def collectTacticSequenceAnchors (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    -- Quotation interiors are skipped for the reason `collectStructInstFieldAnchors` states.
    if stx.isQuot then ranges
    else
      -- The conv half (`Conv.convSeq1Indented`) is the same `sepByIndentSemicolon` family one
      -- grammar over, and the bracketed halves (`tacticSeqBracketed`, `convSeqBracketed`) hold the
      -- same list between their braces: items land at the first item's column or the sequence ends
      -- early, and the anchor states it identically. For the bracketed families it is also the
      -- structural fix for a refusal: a sequence hugging `{` on its row broke its `;` at the row's
      -- nest, left of the first item, and the reparse ended the sequence -- the anchor re-bases
      -- those breaks to the first item's column wherever the hug lands it.
      let ranges :=
        if
            kind == ``Lean.Parser.Tactic.tacticSeq1Indented ||
              kind == ``Lean.Parser.Tactic.Conv.convSeq1Indented ||
              kind == ``Lean.Parser.Tactic.tacticSeqBracketed ||
              kind == ``Lean.Parser.Tactic.Conv.convSeqBracketed then
          match children.find? (·.isOfKind Lean.nullKind) with
          | some list =>
            let items := (list.getArgs.zipIdx.filter fun (_, index) => index % 2 == 0).map (·.1)
            if items.size < 2 then ranges
            else
              match (selectedLeafRanges items[0]!)[0]?, (selectedLeafRanges items.back!).back? with
              | some first, some last => ranges.push ⟨first.start, last.stop⟩
              | _, _ => ranges
          | none => ranges
        else ranges
      let children := if kind == Lean.choiceKind then children[0]?.toArray else children
      children.foldl (init := ranges) fun ranges child => collectTacticSequenceAnchors child ranges
  | _ => ranges

/- A brace collection's continuation rows stay left of its first element.

`{a, b, c}` is two parsers: the collection literal `«term{_}»` and a `structInst` whose fields are
all `structInstFieldAbbrev`s. Which of them applies is decided by a column -- `structInstFields` is
`sepByIndent`, so the structure reading needs every later element at or right of the first one --
and a source that spells a continuation left of its first element has already excluded it. Indent
that row right and both parsers succeed: the reparse is a `choice` where the source had a literal,
which the structure gate reports as one node too many. `Proofs/.../Projective/Smooth.lean` and
`Proofs/.../Formula/Relation.lean` are that failure, at `3755 -> 3756` and `11443 -> 11444`.

Elaboration would still pick the literal, so this is not a wrong candidate -- but a formatter that
turns an unambiguous parse into an ambiguous one has changed the tree it promised to preserve. The
correction holds each such row at its source column, which is the column that made the source
unambiguous. Only rows the source put left of the first element are held: one already at or right
of it is inside the window whatever the layout does, so its `choice` is the source's own.

The column is absolute and so it goes stale, which is a known refusal rather than a fixed one:
`Analysis/Calculus/ContDiff/FaaDiBruno.lean` shifts a `have` by two, the pinned row stays, and the
second pass reads the column the first pass wrote. `columned`, which would follow the shift, is not
the answer -- this pin is a cap on how far right the row may go and `max` is a floor, so it hands
back the ambiguity the pin exists to prevent (`Offside.lean`, node count 1664 -> 1665). The
relationship that would survive both is "left of wherever the first element lands", and an output
column is what `Std.Format` has no way to name; see `Formatter/AGENTS.md`. -/
private partial def collectBraceLiteralRows (source : String) (rowStarts : Array Nat)
    (stx : Lean.Syntax) (starts : Array (Nat × BoundaryLayout) := #[]) :
    Array (Nat × BoundaryLayout) :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == `«term{_}» then
        -- `"{" >> term,* >> "}"`: the elements sit at the even indices of the separated list,
        -- with the commas between them.
        match children[1]? with
        | some list =>
          let items :=
            (list.getArgs.toList.zipIdx.filter fun (_, index) => index % 2 == 0).map (·.1)
          match items.head?.bind fun item => (selectedLeafRanges item)[0]? with
          | some firstRange =>
            let firstColumn := sourceColumn rowStarts firstRange.start
            items.foldl (init := starts) fun starts item =>
              match (selectedLeafRanges item)[0]? with
              | some range =>
                if
                    opensSourceRow source range.start &&
                      sourceColumn rowStarts range.start < firstColumn then
                  starts.push (range.start, .anchored (sourceColumn rowStarts range.start))
                else starts
              | none => starts
          | none => starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectBraceLiteralRows source rowStarts child starts
  | _ => starts

/- The `structInst` field-row pins this collector used to emit are retired (LAY-STRUCT-INST): one
anchor interval per multi-field `structInstFields` list states the same invariant structurally --
every field row breaks at the column the first field lands at, wherever the document places it --
without a source column that goes stale when canonical layout moves the brace, and without the
mid-row test that read brace positions off the first pass's output. The held-brace `columned`
variant is retired with it: a held brace holds the *first* field's row, and the anchor captures
that field's column wherever it is held to. What the pins were for is recorded in git history
alongside the `Proofs/RingTheory/Regular/ProjectiveDimension.lean` and `tests/Test/Runner.lean`
cases that motivated them; what replaces them is `collectStructInstFieldAnchors`. -/

/- The last leaf of a node, atom or ident. The alternatives of a `choice` spell the same bytes
(verified at `command`'s entry), so the selected one answers for all of them. -/
private partial def lastLeaf? (stx : Lean.Syntax) : Option Lean.Syntax :=
  match stx with
  | .atom .. | .ident .. => some stx
  | .node _ kind children =>
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.reverse.findSome? lastLeaf?
  | .missing => none

/- The item-list `null` node of a collection the magic trailing comma can explode, or none.

The collections are the comma-`sepBy` term literals: `«term#[_,]»` and `«term[_]»`
(`Init/Data/Array/Basic.lean:29`, `Lean/Parser/Term.lean`), `Term.tuple`,
`Term.anonymousCtor`, and `Term.structInst`'s fields. In each the list is between the opening
bracket and the closing one: the second child for the bracketed four, the `structInstFields`
node's own list for a structure instance. A structure whose fields the source already separated
by rows keeps them through the `sepByIndent` machinery (the structural anchor interval of
`collectStructInstFieldAnchors`), so a trailing comma there is inert; only the flat spelling
explodes. Other `sepByIndent`-family lists are not here at all: they already keep the source's
row layout, so a trailing separator changes nothing a width decision has not already made. -/
private def explodedCollectionList? (stx : Lean.Syntax) : Option Lean.Syntax :=
  match stx with
  | .node _ kind children =>
    if
        kind == `«term#[_,]» || kind == `«term[_]» || kind == ``Lean.Parser.Term.anonymousCtor ||
          kind == ``Lean.Parser.Term.tuple then
      match children[1]? with
      | some list => if list.isOfKind Lean.nullKind then some list else none
      | none => none
    else
      if kind == ``Lean.Parser.Term.structInst then
        -- An ellipsis (`{ …, .. }`) is excluded: the comma before `..` separates the last field
        -- from the ellipsis rather than closing the list, so it is never the signal this rule
        -- reads, and exploding every spread struct would surprise.
        match children.find? (·.isOfKind ``Lean.Parser.Term.optEllipsis) with
        | some ellipsis =>
          if ellipsis.getArgs.all (·.matchesNull 0) then
            match children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields) with
            | some fields =>
              match fields.getArgs[0]? with
              | some list =>
                if list.isOfKind Lean.nullKind && !hasNewlineSeparator list then some list else none
              | none => none
            | none => none
          else none
        | none => none
      else none
  | _ => none

/- A trailing `,` explodes the collection it closes (the `magic-trailing-comma` setting).

Ruff's and black's magic trailing comma, keyed on the source bytes rather than on width: a
collection literal whose item list ends in a written `,` spells one element per row, keeps the
trailing comma, and puts the closing bracket on its own row. The layout is self-perpetuating --
the exploded spelling retains the comma -- so it is idempotent for free, and removing the comma
is what re-admits the flat layout when the collection fits. A single-element `#[a,]` explodes
too, as black's does.

Which slot holds the trailing comma differs by parser: `#[a, b,]` keeps it an odd separator slot
of the list, while `(a, b,)` nests the tail of the list one `null` deeper. The test is therefore
the *last leaf* of the item list, which both shapes spell the same way, and the elements are the
even slots' first leaves, descending a nested list (`explodedElementStarts`).

The element boundaries are `.hard`: unconditional, so the group's fit measurement cannot rejoin
two elements, and cannot lengthen a row either -- exactly what a self-perpetuating layout needs.
The closing bracket's is `.explodedClose`, whose dedent the walk spells; see `BoundaryLayout`.

Returns the exploded collections' ranges beside the boundaries: the walk's `.nest` rewrite reads
them to learn which nest is a collection's own (`TransformState.explodedSpans`). -/
/-- First-leaf range of every element in a comma-`sepBy` list: the even slots. A tuple's list
nests its tail -- `` `(a, b, c) `` parses as `(null a "," (null b "," c))` -- so an even slot
can itself be a list; the recursion descends one whose direct children hold separator atoms (a
`null`-wrapped *item* never does, so it is not mistaken for a list). -/
private partial def explodedElementStarts (list : Lean.Syntax) : Array SourceRange :=
  list.getArgs.zipIdx.foldl (init := #[]) fun starts (arg, index) =>
    if index % 2 == 1 then starts
    else
      if
          arg.isOfKind Lean.nullKind &&
            arg.getArgs.any fun child => child.isAtom && child.getAtomVal == "," then
        starts ++ explodedElementStarts arg
      else
        match (selectedLeafRanges arg)[0]? with
        | some range => starts.push range
        | none => starts

/- The row-spread explosion is retired (LAY-STRUCT-INST): the anchor interval on the fields list
keeps the first field on a mid-row `{`'s row and lands every later row at that field's column, so
there is no stranded row to explode away and no stale source column to drop. The fixed-point
argument the explosion needed -- a trigger keyed on the source's rows, not the brace the first
pass placed -- is the anchor's own fit invisibility: the anchor re-bases breaks wherever the
document put the first field, so the second pass reads the same fact. -/

private partial def collectTrailingCommaExplosions (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) (starts : Array (Nat × BoundaryLayout) := #[]) :
    Array SourceRange × Array (Nat × BoundaryLayout) :=
  match stx with
  | .node _ kind children =>
    let (ranges, starts) :=
      match explodedCollectionList? stx with
      | some list =>
        match lastLeaf? list with
        | some (.atom _ ",") =>
          let starts :=
            (explodedElementStarts list).foldl (init := starts) fun starts range =>
              if starts.any (·.1 == range.start) then starts
              else starts.push (range.start, BoundaryLayout.hard)
          match lastLeaf? stx with
          | some bracket =>
            match sourceRange? bracket, sourceRange? stx with
            | some bracketRange, some collectionRange =>
              let starts :=
                if starts.any (·.1 == bracketRange.start) then starts
                else starts.push (bracketRange.start, BoundaryLayout.explodedClose)
              (ranges.push collectionRange, starts)
            | _, _ => (ranges, starts)
          | none => (ranges, starts)
        | _ => (ranges, starts)
      | none => (ranges, starts)
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := (ranges, starts)) fun (ranges, starts) child =>
      collectTrailingCommaExplosions child ranges starts
  | _ => (ranges, starts)

/- The brace argument of a `return` keeps the keyword's row.

`doReturn`'s argument does not cross rows: spelled `return` then a brace on the next row, the
reparse reads an empty `return ()` and the brace as the start of something else — "unexpected token
'{'; expected command". The native document breaks there the moment the fields reflow, so a brace
the source hugged to `return` is joined to it: the same `.flat` the application-head rule spells,
and for the same reason — the break, when one is needed, belongs inside the braces. The
`brokenBefore` filter at the assembly site carries the hug: a brace that already opened its own
row is the source's choice, and joining it back would only fight it. -/
private partial def collectReturnBraceStarts (stx : Lean.Syntax) (starts : Array Nat := #[]) :
    Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Term.doReturn || kind == ``Lean.Parser.Term.termReturn then
        -- The argument is wrapped: `termReturn` is `"return" >> optional termParser`, so the
        -- brace sits under the optional's null node rather than as a direct child.
        let braceOf := fun (node : Lean.Syntax) =>
          if node.isOfKind ``Lean.Parser.Term.structInst || node.isOfKind `«term{_}» then some node
          else
            match node with
            | .node _ _ grandchildren =>
              grandchildren.findSome? fun grandchild =>
                if
                    grandchild.isOfKind ``Lean.Parser.Term.structInst ||
                      grandchild.isOfKind `«term{_}» then
                  some grandchild
                else none
            | _ => none
        match children.findSome? braceOf with
        | some brace =>
          match (selectedLeafRanges brace)[0]? with
          | some range => if starts.contains range.start then starts else starts.push range.start
          | none => starts
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectReturnBraceStarts child starts
  | _ => starts

/- A `letI`-family body keeps the keyword's column.

`«letI»` and its siblings -- `«let»`, `«have»`, `«let_fun»`, `«let_delayed»`, `«let_tmp»`,
`«haveI»`, `«suffices»` (`Lean/Parser/Term.lean:227,552-582`) -- are all
`withPosition (kw >> decl) >> optSemicolon termParser`: the keyword's column is saved, and every
application argument inside the value must clear it (`argument` is
`checkColGt >> …`, `Term.lean:890-893`). The body that follows on its own row is therefore
parseable only at or *left* of the keyword's column: one column right and it is read as the
value's next argument, which is how `GlobalMinimalModel.lean`'s `(letI : IsDiscreteValuationRing
… := …` re-parse died with "expected ';' or line break". The native document spells the body's
row at the enclosing `nest` with no regard for the keyword's column, and a signature shatter
moves the keyword's own row left while the body stays -- the relationship inverts and the
candidate stops parsing.

The source always spells the relationship that parses, so the correction spells its columns: one
`columned` boundary at the keyword's row -- at the parenthesized `(` when there is one, else at
the keyword itself -- holding the row at or right of its source column, and one at the body's
first terminal. The body's must be able to dedent, because a document that indents the value's
continuations past the keyword indents the body with them, which is the failing direction here;
which spelling gives it that depends on the shape, and the comment on `bodyPin` says how. The row
pin is collected only when the source shows the same shape (the row broken, the body broken onto
its own row): a keyword spelled mid-line needs none, because any `nest` the body's row can take is
already left of it. -/
private partial def collectLetFamilyAlignments (source : String) (rowStarts : Array Nat)
    (stx : Lean.Syntax) (paren? : Option Lean.Syntax := none) (bracket : Bool := false)
    (starts : Array (Nat × BoundaryLayout) := #[]) : Array (Nat × BoundaryLayout) :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if
          kind == ``Lean.Parser.Term.letI || kind == ``Lean.Parser.Term.let ||
            kind == ``Lean.Parser.Term.haveI ||
            kind == ``Lean.Parser.Term.have ||
            kind == ``Lean.Parser.Term.let_fun ||
            kind == ``Lean.Parser.Term.let_delayed ||
            kind == ``Lean.Parser.Term.let_tmp ||
            kind == ``Lean.Parser.Term.suffices then
        match children[0]?, children.back? with
        | some kw, some body =>
          match sourceRange? kw, sourceRange? body with
          | some kwRange, some bodyRange =>
            -- The body's own row in the source, or there is no constraint to preserve.
            if !(slice source ⟨kwRange.stop, bodyRange.start⟩).contains '\n' then starts
            else
              let bodyCol := sourceColumn rowStarts bodyRange.start
              -- Whether a token opens its source row (only whitespace before it on the row).
              let opensRow (start : Nat) : Bool :=
                let lineStart :=
                  (slice source ⟨0, start⟩).revFind? (· == '\n') |>.map
                      (·.offset.byteIdx + 1) |>.getD
                    0
                (slice source ⟨lineStart, start⟩).trimAscii.copy.isEmpty
              -- The keyword's row: pin the `(` when the node is the paren's payload, else the
              -- keyword. A parenthesized keyword whose body sits at or left of it is pinned only
              -- as far right as the constraint needs, at `bodyCol - 1`: the pair with the body's
              -- pin (below) holds the keyword at or right of its body however the signature
              -- shatters, and the keyword at the body's own column still parses, so pinning the
              -- source's column would only keep narrow widths from shattering the declaration
              -- safely (`GlobalMinimalModel.lean`'s `change (letI …`). Every other case pins
              -- only when the source opened a row there: a keyword spelled mid-row needs no
              -- pin, since any `nest` the body's row can take is left of it.
              let rowPin : Array (Nat × BoundaryLayout) :=
                match paren?.bind sourceRange? with
                | some parenRange =>
                  if bodyCol <= sourceColumn rowStarts kwRange.start && !bracket then
                    #[(parenRange.start, .columned (bodyCol - 1))]
                  else
                    if opensRow parenRange.start then
                      #[(parenRange.start, .columned (sourceColumn rowStarts parenRange.start))]
                    else #[]
                | none =>
                  if opensRow kwRange.start then
                    #[(kwRange.start, .columned (sourceColumn rowStarts kwRange.start))]
                  else #[]
              -- The body's pin needs different spellings for the shapes the source can have,
              -- told apart by where the body sits against the keyword and what encloses it.
              --
              -- A parenthesized keyword, body at or left of it: `anchored`, paired with the row
              -- pin above. The paren's payload nest can spell the body's row one column right
              -- of the keyword -- it does whenever the declaration spans rows -- so `columned`,
              -- whose `max` follows the nest, cannot hold the body at the keyword's column at
              -- all (`GlobalMinimalModel.lean`'s re-parse died `expected ';' or line break` on
              -- exactly that). The pair holds the relationship by construction: `anchored`
              -- keeps the body at its source column in both directions, and the row pinned at
              -- `bodyCol - 1` keeps the keyword at or right of the body however the signature
              -- shatters, since the keyword always follows the `(` by one column. The
              -- five-module non-idempotence the absolute pin once caused does not recur: the
              -- second pass reads back a body at or left of its keyword and collects the same
              -- pair. Pinning the keyword's *source* column instead would keep narrow widths
              -- from shattering the declaration at all; the keyword at the body's own column
              -- still parses, so `bodyCol - 1` is all the constraint needs.
              --
              -- A keyword that is itself an element of an anonymous constructor -- `⟨have : … :=`,
              -- `⟨fun n ↦ let f := …` -- holds the body left of the bracket's own nest, which is
              -- exactly where `max` would push it back to, and `Computability/Primrec/Basic.lean`
              -- answers with `expected ';' or line break`. Only the source column will do there.
              -- An unparenthesized keyword with its body under it keeps `columned`: the two are
              -- one column the document moves together. Left of it needs no pin at all: the
              -- keyword's own formatter dedents the body break two columns under the keyword,
              -- which is parse-safe however far the keyword moves -- the body must sit at or
              -- left of the keyword's column -- and self-stable across passes. The absolute pin
              -- only invented a crossing there: a keyword the document moved *left* of the
              -- pinned body, inverting that order (`Logic/Function/Basic.lean`'s `IsPartialInv`).
              let bodyPin :=
                if bracket || paren?.isSome then some (.anchored bodyCol)
                else
                  if bodyCol == sourceColumn rowStarts kwRange.start then
                    some (BoundaryLayout.columned bodyCol)
                  else
                    if bodyCol < sourceColumn rowStarts kwRange.start then none
                    else some (.anchored bodyCol)
              starts ++ rowPin ++ (bodyPin.toArray.map fun pin => (bodyRange.start, pin))
          | _, _ => starts
        | _, _ => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child =>
      collectLetFamilyAlignments source rowStarts child
        (if kind == ``Lean.Parser.Term.paren then some stx else none)
        (kind == ``Lean.Parser.Term.anonymousCtor || (bracket && kind == Lean.nullKind)) starts
  | _ => starts

/- The other runs that must not break, for the same reason and with the same source precondition.

`collectGuardBailouts` above joins a bail-out because a break inside it lands at a column
`many1Indent` reads as a sibling of the enclosing block. These two are that failure again, in lists
whose items are `colGt` against a position the *item's own* start fixes -- which `nest`, relative to
the ambient indent, cannot reach. Both are upstream shapes, not adapter ones: Lean's own
`formatCommand` renders each the same way when asked directly (probe, 2026-07-25).

- `Term.structInstField`'s binder list. `structInstLVal` is followed by `many (ppSpace >> binder)`,
  and the group deciding those `ppSpace`s also holds the field's body, so a field whose body is
  multi-line breaks its *binders* however short they are -- width never enters it.
  `Mathlib/CategoryTheory/Sites/CoverLifting.lean`'s `cover_lift {U} S hS := by …` is 26 columns and
  renders as `cover_lift {U} S` / `hS := by`, where `hS` sits at the field column and is read as a
  second field. Lean reports the reparse as `Fields missing: Y, f`.
- `Tactic.induction`/`Tactic.funInduction`'s `generalizing` list, `(ppSpace colGt term:max)+`
  (`Init/Tactics.lean:1009,1079`). A break between two terms puts the next one at a column the
  enclosing `tacticSeq`'s `checkColGe` accepts as a new tactic, and a bare identifier there is
  `Lean/Parser/Tactic.lean:33`'s `unknown tactic` -- which is what
  `Mathlib/Algebra/MonoidAlgebra/NoZeroDivisors.lean` reported. Indenting the continuation one column
  further is enough to make it parse, measured both ways, and that column is exactly the one no
  `Format` constructor names.

The precondition is the one that collector states: only a run the source already spells on one line is
collected. It bounds the cost — a line the source fit on is a line — and it keeps the correction from
having to remove a newline-emitting leaf, since `sepByIndent`'s `hasNewlineSep` path is their sole
producer and neither run is a `sepByIndent`.

The correction is a `.flat` boundary in front of each *item* of the run, not a flatten of its span.
A flatten is keyed by span and taken by the deepest node spelling exactly it, and no node spells
exactly these: `many.formatter` concatenates `ppSpace >> binder` straight into its parent's `fill`,
so the binder run has no document node of its own and a collected span of it goes unapplied
(`joined 0/1`, measured before this took the boundary route). A boundary is keyed by terminal, which
the walk visits whatever the document's shape, and `.flat` is already `.text " "` — the same leaf a
flatten would have left.

The gap the source spells with a space, and only those. `.flat` *spells* a space rather than removing
a break, so a boundary at every terminal the run covers writes one into gaps the source left empty and
`coverLift {u} s hs` comes back as `coverLift { u } s hs` (measured). Taking only the item starts is
the other wrong answer: `{g₁ g₂}` is one item and the break moves *inside* it, which parses but is not
what the source spells — and the next run over that output no longer sees a one-line run, so the
correction stops firing and the candidate is not idempotent (measured, `NoZeroDivisors.lean`). Every
single-space gap inside the run, including the one in front of it, is exactly the set that is both
safe and stable. -/
private partial def collectUnbreakableRuns (source : String) (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    -- `structInstField` is `structInstLVal >> null(binders, optType, fieldDef)`, so the binder list is
    -- one level down; `induction` spells `generalizing` as `null(atom, null(terms))` in its fourth
    -- slot. Both are the `null` node covering the run and nothing else.
    let run? : Option Lean.Syntax :=
      if kind == ``Lean.Parser.Term.structInstField then children[1]?.bind (·.getArgs[0]?)
      else
        if kind == ``Lean.Parser.Tactic.induction || kind == ``Lean.Parser.Tactic.funInduction then
          children[3]?.bind (·.getArgs[1]?)
        else none
    let ranges :=
      match run?.bind sourceRange? with
      | some range => if (slice source range).contains '\n' then ranges else ranges.push range
      | none => ranges
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := ranges) fun ranges child => collectUnbreakableRuns source child ranges
  | _ => ranges

/- The boundaries an unbreakable run asks for: one `.flat` per gap the source spells with spaces alone.

A gap holding a comment is not one of them -- the comment machinery owns that gap and a `.flat` there
would spell a space where a comment has to go. -/
private def unbreakableRunBoundaries (source : String) (terminals : Array Terminal)
    (runs : Array SourceRange) : Array (Nat × BoundaryLayout) :=
  runs.flatMap fun run =>
    (terminals.zipIdx.filterMap fun (terminal, index) => do
      guard (run.start <= terminal.range.start && terminal.range.stop <= run.stop)
      let previous ←
        if index == 0 then
          none
        else
          terminals[index - 1]?
      let gap := slice source ⟨previous.range.stop, terminal.range.start⟩
      guard (!gap.isEmpty && gap.all fun character => character == ' ' || character == '\t')
      some (terminal.range.start, BoundaryLayout.flat))

/- A structure instance's `..`, when the source spells it on its own line.

`..` is not only the structure-instance ellipsis: it is also the suffix of an application filled with
placeholders, so `f ..` is a term and joining `..` onto the line in front of it can move it from one
parser to the other. `Mathlib/CategoryTheory/Sites/CoverLifting.lean` is that move --

    r.w := by simpa using G.congr_map w =≫ f
    .. }

joins to `r.w := by simpa using G.congr_map w =≫ f .. }`, where the `by` block's `tacticSeq` reaches
one token further and takes the `..` as part of its own last tactic. The structure instance then has
no ellipsis, and Lean reports the five fields it was standing in for as `Fields missing: Y, f`.

The source decides, the way it decides a doc comment's side of a break: a `..` the source put on its
own line gets a `hard` boundary and one the source spelled inline is left to the document. This asks
nothing of a `..` whose parse was never in question. -/
private partial def collectStructInstEllipses (stx : Lean.Syntax) (starts : Array Nat := #[]) :
    Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      if kind == ``Lean.Parser.Term.optEllipsis then
        match children[0]?.bind sourceRange? with
        | some range => starts.push range.start
        | none => starts
      else starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectStructInstEllipses child starts
  | _ => starts

/- A struct instance's closing brace is parse-significant on its own row.

`structInstFields` is a `sepByIndent`, and its indent check fires at exactly the first field's
column: a `}` that begins a row there is read as a continuation of the field list, which leaves
the list one empty slot wider than any other `}` position produces. Hugging the brace, or ending
its row left or right of the field column, all parse to the narrower list. So the brace's row
position is not layout; it decides the list's arity, and the candidate must reproduce whichever
the source wrote. (Both directions fail closed today: `MathlibTest/Spread.lean` -- "optEllipsis
before and null after" -- and `Algebra/Category/AlgCat/Limits.lean` -- "null before and
optEllipsis after" -- are this brace at opposite ends of the same rule.)

The native document always hugs the brace (`text " }"`). That loses the wide list for a source
that spelled `}` alone at the field column, and a trailing comment on the last field pushes the
hugged brace onto the next row at the fields' nest -- exactly the field column -- which *creates*
the wide list for a source that never had it.

The source decides. A source brace alone at the field column gets two `.hard` boundaries: the
first field breaks off the brace's row and the brace breaks onto its own. Both land at the fields'
nest, so the candidate's field column and brace column are equal by construction and the wide list
survives. A source brace elsewhere on its own row, separated from its field by a comment, gets
`.explodedClose`: the brace dedents to the collection's own row, off the field column, so the
comment-forced break cannot invent the slot. (Without the comment the document hugs, which is
already safe.) A collection the trailing-comma rule already owns is left to it. The returned
ranges join `explodedRanges` for the nest cancellation only -- the pin filter has already run --
so registering one drops no interior source-column pins. -/
private partial def collectStructInstCloseBraces (source : String) (rowStarts : Array Nat)
    (comments : Array InteriorComment) (stx : Lean.Syntax)
    (starts : Array (Nat × BoundaryLayout) := #[]) (ranges : Array SourceRange := #[]) :
    Array (Nat × BoundaryLayout) × Array SourceRange :=
  match stx with
  | .node _ kind children =>
    let (starts, ranges) :=
      if kind == ``Lean.Parser.Term.structInst then
        match children.find? (·.isOfKind ``Lean.Parser.Term.structInstFields) with
        | some fieldsNode =>
          match structInstFieldsInOrder fieldsNode with
          | #[] => (starts, ranges)
          | fields =>
            match lastLeaf? fieldsNode, lastLeaf? stx, fields[0]?.bind sourceRange?,
              sourceRange? stx with
            | some fieldsEnd, some brace, some fieldRange, some collectionRange =>
              match sourceRange? fieldsEnd, sourceRange? brace with
              | some fieldsEndRange, some braceRange =>
                let gap := slice source ⟨fieldsEndRange.stop, braceRange.start⟩
                if fieldsEnd matches .atom _ "," then (starts, ranges)
                else
                  if !gap.contains '\n' then (starts, ranges)
                  else
                    if
                        sourceColumn rowStarts braceRange.start ==
                          sourceColumn rowStarts fieldRange.start then
                      let starts :=
                        if starts.any (·.1 == fieldRange.start) then starts
                        else starts.push (fieldRange.start, BoundaryLayout.hard)
                      if starts.any (·.1 == braceRange.start) then (starts, ranges)
                      else (starts.push (braceRange.start, BoundaryLayout.hard), ranges)
                    else
                      if
                          comments.any fun comment =>
                            fieldsEndRange.stop <= comment.range.start &&
                              comment.range.stop <= braceRange.start then
                        if starts.any (·.1 == braceRange.start) then (starts, ranges)
                        else
                          (starts.push (braceRange.start, BoundaryLayout.explodedClose),
                            ranges.push collectionRange)
                      else (starts, ranges)
              | _, _ => (starts, ranges)
            | _, _, _, _ => (starts, ranges)
        | none => (starts, ranges)
      else (starts, ranges)
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := (starts, ranges)) fun (starts, ranges) child =>
      collectStructInstCloseBraces source rowStarts comments child starts ranges
  | _ => (starts, ranges)

/- The docstring of a constructor that has one.

`ctor` (`Command.lean:210-212`) is `atomic (optional docComment >> "\n| ") >> ppGroup …`, so the
docstring is the first child -- a `null` node, empty when the constructor has none -- and the `|` is
the second. The newline the constructor needs sits *inside* the `"\n| "` atom, after the docstring
that was supposed to follow it, which is the whole of it: Lean emits the docstring where a separator
should be and the separator after it. -/
private def ctorDocComment? (stx : Lean.Syntax) : Option Lean.Syntax := do
  guard (stx.isOfKind ``Lean.Parser.Command.ctor)
  let doc ← stx.getArgs[0]?.bind fun optional => optional.getArgs[0]?
  guard (doc.isOfKind ``Lean.Parser.Command.docComment)
  return doc

/- A constructor docstring keeps its constructor's indentation, and one blank line goes away.

Lean's document is `text" where" nest-2[text"/--" line text"…-/" text"\n"] text"\n|" …`, which spells
the boundary between the docstring and its constructor twice and dedents the docstring by one level.
Rendered, that is a docstring at column zero followed by a blank line — and reparsed, a docstring
that no longer sits on its constructor.

The `elided` boundary at the `|` removes the first of the two newlines, leaving the one inside the
`"\n| "` atom, which carries the constructor's own indentation. The constraint cancels the `nest -2`
over exactly the docstring's range, so the line the island opens lands at the same column as the `|`
below it.

Eliding rather than flattening matters: `.text " "` here would leave a space at the end of the
docstring's line, and the `elided` spelling exists because a doubled separator is a different defect
from a badly placed one.

This half is the boundary; `collectOffsideConstraints` carries the other. The offset is the
docstring's own end, which `boundaryTable` resolves to the `|` — the first terminal at or after it. -/
private partial def collectCtorDocStarts (stx : Lean.Syntax) (starts : Array Nat := #[]) :
    Array Nat :=
  match stx with
  | .node _ kind children =>
    let starts :=
      match ctorDocComment? stx with
      | some doc =>
        match sourceRange? doc with
        | some range => starts.push range.stop
        | none => starts
      | none => starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectCtorDocStarts child starts
  | _ => starts

/- Every doc comment in the command, in source order.

A doc comment is a comment, and a comment keeps the side of the line break the source put it on. For
trivia comments the adapter enforces that by construction -- it decides where to place them. A doc
comment is syntax, so it flows through the native document as an exact island and the document decides
which side of a break it lands on, using a soft `line` that flattens whenever the two fit together.

`let rec` is where that shows: `letRecDecl` is `optional docComment >> letDecl`, and Lean spells
`text"let" line text"rec" line nest-2[text"/--" line text"…-/" text"\n"] line text"helper"`. At any
width where `let rec /-- … -/` fits, the leading `line` flattens and a docstring the source wrote on
its own line becomes the trailing comment of `rec` -- which the comment contract reports as an
ownership change, because `leading` and `trailing` are exactly the question of which side of the break
a comment is on. `Mathlib/Util/Superscript.lean` writes both spellings, one `let rec` with the
docstring inline and one with it on the next line, so no fixed choice preserves both.

The constructor docstring is excluded here because a different pair of
corrections already owns it: `ctor`'s separator lives *inside* the `"\n| "` atom, so that one elides rather than
breaks. A command's own leading docstring is excluded because there is no boundary in front of the
command's first terminal. -/
private partial def collectDocCommentRanges (stx : Lean.Syntax)
    (ranges : Array SourceRange := #[]) : Array SourceRange :=
  match stx with
  | .node _ kind children =>
    let ranges :=
      if kind == ``Lean.Parser.Command.docComment then
        match sourceRange? stx with
        | some range => ranges.push range
        | none => ranges
      else ranges
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := ranges) fun ranges child => collectDocCommentRanges child ranges
  | _ => ranges

/- Doc comments owned by an attribute instance, paired with the closing `]` of their attribute list.

An attribute argument can be a doc comment (`to_additive (docComment)?` is the mathlib shape). The
payload is fixed -- the comment contract forbids reflowing it -- and its first line was authored to
fit at the column the source wrote it at. Native layout's broken attribute form nests the entry
(and dedents the `]` less far), so a payload line written to reach column 100 at the attribute's own
column comes back over the limit, and no layout decision of the formatter's can shrink it. The only
width-safe placement is the shallowest legal one: the attribute list's own column, entry and `]`
alike. That is also the form the sources already write by hand.

The bracket is collected here, with the doc, because the two must agree: a doc that stays hugged
against its attribute keeps the `]` hugged too, and only a doc the source wrote on its own line
pulls both down to the owner's column. Pairing them in one walk is what makes the two boundaries
two spellings of one decision rather than two rules that could disagree. -/
private partial def collectAttrDocComments (stx : Lean.Syntax)
    (entries : Array (SourceRange × SourceRange) := #[]) : Array (SourceRange × SourceRange) :=
  match stx with
  | .node _ kind children =>
    let entries :=
      if kind == ``Lean.Parser.Term.attributes then
        match children.back?.bind sourceRange? with
        | some bracket =>
          (collectDocCommentRanges stx).foldl (init := entries) fun entries doc =>
            entries.push (doc, bracket)
        | none => entries
      else entries
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := entries) fun entries child => collectAttrDocComments child entries
  | _ => entries

/-! ### LAY-CHAIN-COMPENSATION — one indent level per link of an operator chain

Lean's generated formatters wrap **every** category node in `group (nest format.indent …)`, including
a bare literal: `"a0"` alone formats to `grp[nest2[T"\"a0\""]]`. That wrapper covers the node's own
operands, so a chain of one operator — which parses as nested applications of that operator, once per
link — stacks one `nest` per link, and each link's `line` renders one level further in than the
link outside it. `"a0" ++ … ++ "a09"` at width 100 rendered a staircase from column 16 back down to
4, and the deepest indent grows without bound: measured `2 × operands − 6` on chains of 4, 8, 16, 32
and 64, reaching column 122 and rows 145 characters wide.

Nothing in the document says "these operands are a chain", so `Std.Format` cannot recover the shape;
the accumulation is in what the formatter emits, not in how the engine renders it. A printer never
paid for it — an error message rarely holds a long chain, and nobody diffs a re-print — so it is
unreported upstream. Fixing it there means changing what the generic category formatter wraps, which
moves the layout of every construct in the language; that is a change to propose on its own evidence,
not a rider on this one.

So the adapter cancels the accumulation: one `nest (-format.indent)` on each operand that continues
its parent's chain, which leaves every link's break at exactly one level in. `binaryInfixOperands?`
is structural — three children with the operator as the middle atom — rather than a list of kinds,
because every `infixl`/`infixr` notation in every project produces that shape and a kind list would
cover only the ones someone remembered.

The price of a shape test is that some shapes match and are not chains, and the shape cannot tell
which: `a.1.2` is `proj` inside `proj`, the same node kind on the same side, and dot projection has
no break and so no `nest` to cancel. These constraints are therefore `required := false`. A shape
test over a grammar nobody controls will keep meeting nodes like that one, and the honest reading is
that an unapplied compensation is a row that stayed as wide as it already was. Making it refuse
instead cost one module of the verification corpus a hard failure before this was found.

**When upstream fixes the wrapper**, delete `chainedOperandRanges` and its call in
`collectOffsideConstraints`, then run:

    lake test -- --suites term-formatter native-layout declaration-formatter command-formatter
    lake lint

Those suites hold the chain rows this produces. If they still pass with the collector gone, the
compensation is no longer doing anything and should be gone with it. -/

/- The two operands of a binary infix node, with the operator atom between them.

`null` and `choice` are excluded, and the exclusion is the whole reason this is not just a shape
test. A `sepBy`'s separated items are a `null` node, so `(_, _, state)` holds `[hole, ",", [hole,
",", state]]` — three children, an atom between them, and the inner one carries the *same* kind,
because every `null` node does. It reads as a chain and is not one: a `null` node is a grouping
artifact with no formatter of its own and no `nest` to cancel, so a constraint written on it never
matches a document node. It was a refusal that found this, back when these constraints were required;
they are not, so keeping the exclusion is now about not asking a question whose answer is known. -/
private def binaryInfixOperands? (stx : Lean.Syntax) :
    Option (Lean.SyntaxNodeKind × Lean.Syntax × Lean.Syntax) :=
  match stx with
  | .node _ kind children =>
    if kind == Lean.nullKind || kind == Lean.choiceKind || kind.isAnonymous then none
    else
      match children[0]?, children[1]?, children[2]?, children[3]? with
      | some left, some (Lean.Syntax.atom _ _), some right, none => some (kind, left, right)
      | _, _, _, _ => none
  | _ => none

/- The operands of `stx` that are themselves applications of `stx`'s own operator, and so continue
one chain rather than opening a nested expression.

Both sides are checked. `++` is `infixl`, so its chain nests left and the leftmost operand ends
deepest; `::` is `infixr` and nests right, which stacks the same `nest` per link in the other
direction. Parentheses interpose a node of a different kind, so a parenthesized sub-chain is not a
continuation and keeps its own indentation — which is the reading the parentheses ask for.

`columnPinStarts` are the rows the evidential caps hold at a source column. An operand with one
*strictly inside* it is declined, because the two corrections contradict each other there: the cap
reproduces the column the source proved parseable, and this constraint moves that row without moving
the cap's evidence, so each pass writes a column the next one reads back and shifts again.
`(xs.filterMap fun start => let broken := …)` inside an `xs ++ … ++ xs` chain walked two columns left
per pass and never converged. Correcting the caps to see the constraint instead — `rowIndent` is the
one line — is measured there and costs 13 modules their reparse; declining is the answer that keeps
both corrections true.

Strictly inside, and not *at* the operand's first byte, which is the whole difference between this
reaching ordinary code and not. A pin at that byte is the row the operand begins on, and the break
that places that row is the one *before* the operand, outside the subtree this constraint wraps —
so there is no contradiction to avoid. The leftmost operand of a chain always starts where the chain
does, so testing `<=` declined every chain written as the body of a `let`, a brace literal, or a
brace-interior row. That is ordinary Lean, and `catalogSchemaJson` in `LeanFmt/Rules.lean` was
rendering at 152 columns of indent and 254 characters wide because of it. -/
private def chainedOperandRanges (columnPinStarts : Array Nat) (stx : Lean.Syntax) :
    Array SourceRange :=
  match binaryInfixOperands? stx with
  | none => #[]
  | some (kind, left, right) =>
    #[left, right].filterMap fun operand => do
      let (operandKind, _, _) ← binaryInfixOperands? operand
      guard (operandKind == kind)
      let range ← sourceRange? operand
      guard (!columnPinStarts.any fun start => range.start < start && start < range.stop)
      return range

/- `indent` is `Std.Format.getIndent`, the `format.indent` option Lean's own `ppIndent`/`ppDedent`
read. A constraint here cancels one level of the indentation native layout introduced, so it is that
same quantity negated — not the literal `-2` this used to spell. The default happens to be 2, which is
why the constant went unnoticed; a project setting `format.indent` would have silently drifted.

The constructor-docstring branch cancels a `nest -2` rather than introducing one, so its adjustment is
that same quantity un-negated. Both are one level; nothing here knows how to ask for two. -/
private partial def collectOffsideConstraints (indent : Nat) (columnPinStarts : Array Nat)
    (stx : Lean.Syntax) (constraints : Array OffsideConstraint := #[]) : Array OffsideConstraint :=
  match stx with
  | .node _ kind children =>
    let constraints :=
      if
          kind == ``Lean.Parser.Term.doLetElse || kind == ``Lean.Parser.Term.doLetExpr ||
            kind == ``Lean.Parser.Term.doLetMetaExpr ||
            kind == ``Lean.Parser.Term.doLetArrow then
        let pipes := guardedPipeRanges stx
        let sequences := guardedSequenceRanges stx
        match pipes.back? with
        | some pipe =>
          let continuations := sequences.filter (pipe.stop <= ·.start)
          if 2 <= continuations.size then
            match continuations.back? with
            | some range =>
              constraints.push { range, indentAdjustment := -(indent : Int), carrier := .boundary }
            | none => constraints
          else constraints
        | none => constraints
      else
        match ctorDocComment? stx with
        | some doc =>
          match sourceRange? doc with
          | some range =>
            constraints.push { range, indentAdjustment := (indent : Int), carrier := .nest }
          | none => constraints
        | none => constraints
    -- LAY-CHAIN-COMPENSATION: cancel the level this link's operand inherited from the link outside
    -- it, so every break in one operator chain lands at the same column.
    let constraints :=
      (chainedOperandRanges columnPinStarts stx).foldl (init := constraints)
        fun constraints range =>
        constraints.push
          { range, indentAdjustment := -(indent : Int), carrier := .nest, required := false }
    -- As in the boundary collectors: one alternative of a `choice` spells the bytes, and collecting
    -- from all of them would name the same range once per alternative. A constraint is applied once,
    -- so the duplicate would leave the applied count short and refuse the command.
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := constraints) fun constraints child =>
      collectOffsideConstraints indent columnPinStarts child constraints
  | _ => constraints

private def commentText (value : String) : Bool :=
  let trimmed := value.trimAscii.copy
  trimmed.startsWith "--" || trimmed.startsWith "/-"

private def splitPadding (value : String) : String × String :=
  let chars := value.toList
  let leading := chars.takeWhile layoutWhitespace
  let remainder := chars.drop leading.length
  let trailing := remainder.reverse.takeWhile layoutWhitespace |>.reverse
  (String.ofList leading, String.ofList trailing)

/- Which markers the formatter kept. A marker replaces the syntax it protects, so a formatter that
drops or restructures that syntax drops the marker with it; the island then has to be placed at the
terminal it covers instead of at a leaf that never arrives. -/
private partial def spelledMarkers (format : Std.Format) (found : Array String := #[]) :
    Array String :=
  match format with
  | .text value =>
    let payload := value.trimAscii.copy
    if payload.isEmpty then found else found.push payload
  | .nest _ inner | .group inner _ | .tag _ inner => spelledMarkers inner found
  | .append left right => spelledMarkers right (spelledMarkers left found)
  | .nil | .line | .align _ => found

private def mergeSpan : Option TokenSpan → Option TokenSpan → Option TokenSpan
  | none, right => right
  | left, none => left
  | some left, some right => some ⟨min left.start right.start, max left.stop right.stop⟩

private structure TransformState where
  source : String
  terminals : Array Terminal
  comments : Array InteriorComment
  trailing : Array (TokenSpan × InteriorComment)
  islands : Array ExactIsland
  droppedIslands : Array String
  constraints : Array (OffsideConstraint × TokenSpan)
  boundaries : Array (Nat × BoundaryLayout)
  flattened : Array TokenSpan
  /- Every nested command's terminal span. The `dedented` boundary in front of one is collected as a
  boundary like any other; this is the same command's *extent*, which is what says how far that
  boundary's column reaches. -/
  nestedCommands : Array TokenSpan
  /- The terminal spans of collections a trailing comma exploded. A `.nest` whose content spans one
  exactly is the collection's own private nest, and the `explodedClose` marker inside it cancels
  exactly that amount; see `dedentExplodedClose`. -/
  explodedSpans : Array TokenSpan
  /- For each terminal that begins a syntax node, the terminal span of the smallest such node: the
  construct a boundary at that terminal heads. The `.nest` hoist test compares its own span
  against it (`Transformed.hoist?`). -/
  headSpans : Array (Nat × TokenSpan)
  /-- The fill-words blocks registered at comment insertion, in order; `fillTagBase + index`
  tags ride the document to the lowering, which maps them back to these. -/
  fillBlocks : Array (Array FillLine) := #[]
  baseIndent : Nat
  terminalIndex : Nat := 0
  commentIndex : Nat := 0
  ambientNest : Int := 0
  appliedIslands : Array String := #[]
  appliedConstraints : Array Nat := #[]
  appliedBoundaries : Array Nat := #[]
  appliedTrailing : Array Nat := #[]
  appliedFlattened : Array Nat := #[]
  anchors : Array TokenSpan := #[]
  appliedAnchors : Array Nat := #[]
  /- The outermost finished node starting (resp. ending) exactly at an anchor interval's edge, by
  interval index. Overwritten as the walk ascends, so the entry always names the outermost
  candidate; the append case drops the interval's spine marker where the chain leaves it. -/
  anchorOpens : Array (Nat × TokenSpan) := #[]
  anchorCloses : Array (Nat × TokenSpan) := #[]
  /- Whether the document emitted since the previous terminal is known to render as something other
  than the empty string. A command starts separated because its first terminal has no predecessor to
  merge with. -/
  separated : Bool := true
  /- The document's own nest depth at the first boundary leaf in front of each terminal, which is the
  indent that terminal's line was laid out at. `finishTrailing` is the only reader: it places a comment
  a block owns from past its own last token, and the column it needs is the one the block's items got.
  A boundary is where the walk can see that column, and it passes there long before the node that will
  claim the comment finishes. -/
  boundaryNest : Array (Nat × Int) := #[]
  /- Each nested command whose `dedented` boundary has fired, with the columns that boundary cancelled.
  Recorded during the walk rather than collected before it, because the amount is not a property of the
  syntax: it is `ambientNest` where the boundary lands, which says whether the embedding node nested
  this command at all. `open … in` records zero and its body is left where the document put it. -/
  dedents : Array (TokenSpan × Int) := #[]
  /- Islands whose interior the formatter has started to spell. See `insideIsland`. -/
  enteredIslands : Array String := #[]
  recentNativeLeaves : Array String := #[]
  metrics : Metrics := { }

private structure Transformed where
  format : Std.Format
  span? : Option TokenSpan := none
  /- A comment-insertion prefix the enclosing `nest`/`group` rebuild may hoist, as
  `(prefix, rest, head)` with `format ≡ .append prefix rest` and `head` the terminal span of the
  smallest syntax node the boundary's terminal heads (`TransformState.headSpans`).

  A leading comment is inserted at the first boundary leaf in front of its terminal, wherever the
  native document put that leaf. When the terminal is the first element of a comma-separated
  collection, the document offers no separator leaf between the opening bracket and the element, so
  the insertion lands inside the element's own private `grp (nest …)` wrapper -- and `text "\n"`
  re-indents to that nest, putting the comment and the element one level deeper than the siblings
  the separator `line`s position. This is the defect the `.align` boundary case documents, one
  grammar family over: there is no boundary leaf to claim, so the insertion itself has to move.

  Moving the prefix out of a `nest` re-parents its rows from the nest's indent to the ambient one.
  That is sound iff the sibling rows live at the ambient one, which holds exactly when the nest
  wraps *only* the construct the boundary heads -- the sibling separators then live outside it.
  The test is tree structure, not printer convention: a nest whose span lies inside `head` is that
  construct's private wrapper and is climbed; a nest that reaches past it wraps siblings too -- a
  `match`'s alternatives sit under one `nest -2` -- and stops the climb. A negative nest is never
  climbed either way: it positions its rows *below* the ambient (`ppDedent`), and the comment's
  rows are among them. A spanless nest wraps the boundary alone and belongs to it. The `.nest`
  case spells the test; groups pass the prefix through (they move no columns), and the climb stops
  at the first `append` with real content to its left.

  Only single-line, relative-indent insertions are hoistable (see `constrainBoundary`): a
  multi-line payload, an absolute column pin, or a nested-command dedent carries columns computed
  against the insertion point's ambient nest, which hoisting would invalidate. -/
  hoist? : Option (Std.Format × Std.Format × TokenSpan) := none

private def nearbyTerminals (state : TransformState) : String :=
  let start := state.terminalIndex - min state.terminalIndex 2
  let stop := min state.terminals.size (state.terminalIndex + 3)
  String.intercalate ", " <|
    (state.terminals.extract start stop).toList.map fun terminal =>
      s!"{terminal.range.start}:{repr terminal.sourceSpelling}"

private def rememberNativeLeaf (leaves : Array String) (value : String) : Array String :=
  let leaves := leaves.push value
  if leaves.size <= 8 then leaves else leaves.extract (leaves.size - 8) leaves.size

/- Whether a document renders as the empty string at every width. `nil` and an empty `text` are the
only leaves that emit nothing; `line` renders as a space or a newline, and `align` is a layout node
whose output the width decides, so neither is provably empty. -/
private partial def provablyEmpty : Std.Format → Bool
  | .nil => true
  | .text value => value.isEmpty
  | .nest _ inner | .group inner _ | .tag _ inner => provablyEmpty inner
  | .append left right => provablyEmpty left && provablyEmpty right
  | .line | .align _ => false

/- A comment's own bytes, with the columns the source gave them.

`Format.text` re-indents every newline it contains, so a block comment spanning lines would have its
continuations pushed right by the ambient indentation while its opening moved with the layout -- and
the payload the contract compares is the whole slice, so that is a changed comment and a refusal.
`dedent` is the same cancelling `nest` an exact island gets, and for the same reason: a payload
carrying absolute source columns has to reach column zero. A single-line payload has no interior
newline for the indentation to reach, so it is left alone. -/
private def commentPayload (dedent : Int) (comment : InteriorComment) : Std.Format :=
  if comment.payload.contains '\n' then .nest dedent (.text comment.payload)
  else .text comment.payload

/- `rowBreak` is every newline this insertion emits, and the caller spells it because a boundary can
carry a *column* rather than a separator.

Three of the four `BoundaryLayout`s say only whether the next token is on this row or the next, and a
comment that ends the row has already answered that -- which is why `atLineStart` drops `suffix`
below. `dedented` is the fourth, and it says which *column* the next row starts at: `boundaryFormat`
spells it as the cancelling `nest` around the newline. Dropping that alongside the separators is a defect --
`#guard_msgs in`, a line comment, then the nested command, and the command comes back at
`format.indent` with the comment beside it, exactly the layout a dedent exists to prevent. The
boundary was marked applied before the format was discarded, so `applied n/m` stayed level and nothing
refused. Both breaks take it: the one before the comment and the one after, because the source wrote
the comment at the command's own column too. -/

/-- The tag base a fill-words block rides from this walk to the lowering: `fillTagBase + index`
names `fillBlocks[index]`, and the tag's body is the block's verbatim spelling, so every
document-walking predicate sees exactly what the spliced comments showed before. Native tags have
no producer over parsed source (the anchor markers' argument), and the base sits past their
reserved range, so neither collides. -/
private def fillTagBase : Nat :=
  0x6C65616E00 + 8192

/- Decode a fill-words tag as its block index, or none for any other tag. -/
private def fillTag? (tag : Nat) : Option Nat :=
  if fillTagBase <= tag && tag < fillTagBase + 8192 then some (tag - fillTagBase) else none

/-- One comment-run insertion item: a single comment spelled as its payload, or a maximal block
of fill-eligible comments on consecutive rows at one column, carried as fill lines the lowering
maps to one `Doc.fillWords` leaf. The pack decision is the renderer's, made at the block's true
column; this walk only locates blocks. -/
private inductive CommentItem where
  | single (comment : InteriorComment)
  | block (lines : Array FillLine)

/-- The extraction facts one interior comment carries, as the `Comments` classifiers read them. -/
private def commentFact (comment : InteriorComment) : Comment :=
  { kind := comment.kind, range := comment.range, row := comment.row, column := comment.column,
    startsRow := comment.startsRow }

/-- Group one boundary's comments into singles and fill blocks. A block's members are
fill-eligible by construction -- only an eligible comment opens or continues one -- so the
`filterMap` over them is total. -/
private def groupFillBlocks (comments : Array InteriorComment) : Array CommentItem :=
  let eligible (comment : InteriorComment) : Bool :=
    (Comments.fillLine? (commentFact comment) comment.placement comment.payload).isSome
  let flush (items : Array CommentItem) (block : Array InteriorComment) : Array CommentItem :=
    if block.isEmpty then items
    else
      items.push
        (.block
          (block.filterMap fun comment =>
            Comments.fillLine? (commentFact comment) comment.placement comment.payload))
  let (items, block) :=
    comments.foldl (init := ((#[], #[]) : Array CommentItem × Array InteriorComment))
      fun (items, block) comment =>
        let continues :=
        match block.back? with
        | some prev =>
          eligible comment && Comments.sameBlock (commentFact prev) (commentFact comment)
        | none => false
        if continues then (items, block.push comment)
      else
        if eligible comment then (flush items block, #[comment])
        else (flush items block |>.push (.single comment), #[])
  flush items block

private def insertComments (dedent : Int) (rowBreak : Std.Format) (comments : Array InteriorComment)
    (suffix : Std.Format) : StateT TransformState (Except String) Std.Format := do
  let (document, atLineStart) ←
    (groupFillBlocks comments).foldlM (init := (.nil, false)) fun (document, atLineStart) item =>
        match item with
        | .block lines => do
          let index := (← get).fillBlocks.size
          modify fun state => { state with fillBlocks := state.fillBlocks.push lines }
          let boundary := if atLineStart then .nil else rowBreak
          let body :=
            match lines.toList with
            | [] => .nil
            | first :: rest =>
              rest.foldl (init := Std.Format.text first.payload) fun doc line =>
                .append doc (.append rowBreak (.text line.payload))
          -- The tag's body is the block's verbatim spelling, so the tree keeps the shape every
          -- predicate read before; the lowering replaces the whole node with one fill-words leaf.
          let tagged := .tag (fillTagBase + index) body
          return (.append document <| .append boundary <| .append tagged rowBreak, true)
        | .single comment => do
          let payload := commentPayload dedent comment
          match comment.placement with
          | .trailing =>
            let boundary := if atLineStart then .nil else .text " "
            let document := .append document (.append boundary payload)
            -- A line comment ends its row by construction. So does a block comment the source wrote
            -- over more than one row: its closing `-/` sits at whatever column the payload's last row
            -- reached, which is a column no layout decision here chose. Letting the next token follow
            -- it there puts code on the comment's closing row -- `-/ intro h` -- and the token lands
            -- offside of the block it belongs to, which ends the block and leaves the rest of it to
            -- reparse as sibling commands. 17 mathlib modules refused to format for it. Only a
            -- single-row block comment leaves the row in a state the surrounding layout still owns.
            if comment.kind == .line || comment.payload.contains '\n' then
              return (.append document rowBreak, true)
            else
              return (document, false)
          | .leading | .dangling =>
            let boundary := if atLineStart then .nil else rowBreak
            return (.append document <| .append boundary <| .append payload rowBreak, true)
  if atLineStart then
    return document
  -- The adapter owns *both* sides of a comment, not just the side facing the token behind it. `suffix`
  -- is the native boundary between the two tokens the comment sits between, and the native document
  -- holds no decision about a leaf it never emitted -- so where the grammar spells those tokens
  -- adjacent, as `[` and `5` in a list, `suffix` is empty and a block comment would close directly
  -- against the next token: `-/5`. That reparses as one token or not at all.
  --
  -- A line comment needs nothing here; it already ended the row and set `atLineStart`. Only the block
  -- case can end mid-row with nothing after it, and one space is enough -- `pushToken`'s discretionary
  -- space is the tokenizer's own answer to the same question, and this is the case it never sees.
  else if provablyEmpty suffix then
    return .append document (.text " ")
  else
    return .append document suffix

private partial def hasLineBoundary : Std.Format → Bool
  | .line | .align _ => true
  | .text value => value.contains '\n'
  | .nest _ inner | .group inner _ | .tag _ inner => hasLineBoundary inner
  | .append left right => hasLineBoundary left || hasLineBoundary right
  | .nil => false

/- Whether a document's own bytes start with a newline. Only a `text` carries one; `line` and `align`
are decisions, not bytes, which is the whole point of asking. A provably empty side is skipped rather
than answered for, so a `nest` holding nothing does not hide the leaf behind it. -/
private partial def opensWithNewline : Std.Format → Bool
  | .text value => value.startsWith "\n"
  | .nest _ inner | .group inner _ | .tag _ inner => opensWithNewline inner
  | .append left right =>
    if provablyEmpty left then opensWithNewline right else opensWithNewline left
  | _ => false

/- The separator between two commands belongs to the adapter: it renders each command and then spells
the blank lines the source wrote between them. One command's document carries that separator inside
itself: `moduleDoc` (`Command.lean:60-61`) ends with `ppLine`, whose formatter is
`pushWhitespace "\n"`. Every module docstring therefore contributed a newline the assembly was about to
add again and gained a blank line below it. Stated over any command that ends in a hard newline rather
than for `moduleDoc`, because the ownership is what makes it wrong: nothing else a command's document
ends with is whitespace, and if another parser acquires the same tail it is wrong there for the same
reason.

This is `dropTrailingBreak`'s question one level out. That one removes a *discretionary* break the
renderer would turn into a trailing space; this removes a hard newline that duplicates a separator the
adapter owns. -/
private partial def dropTrailingHardLine : Std.Format → Option Std.Format
  | .text value => if value == "\n" then some .nil else none
  | .nest indent inner => (dropTrailingHardLine inner).map (.nest indent ·)
  | .group inner behavior => (dropTrailingHardLine inner).map (.group · behavior)
  | .tag tag inner => (dropTrailingHardLine inner).map (.tag tag ·)
  | .append left right =>
    if provablyEmpty right then (dropTrailingHardLine left).map (.append · right)
    else (dropTrailingHardLine right).map (.append left ·)
  | _ => none

/- The same document without its last discretionary break, or `none` where the outermost thing on that
side is not one.

`Std.Format.line` renders as a space when its group flattens and as a newline when it does not. Sitting
directly in front of a `text` that carries its own newline it is redundant either way: flattened it is a
space at the end of a line, which is trailing whitespace no formatter may emit, and broken it is a blank
line the source never had. Lean's `doIf` spells exactly this — `ppSpace` before a `doSeq` that begins
with its own hard newline — so before this every `if c then` with an indented body ended its line with a
space, five of them in `Mathlib/Util/Superscript.lean`. A printer has no reason to care: a trailing space
is invisible in an error message and a re-print is never diffed against source.

The mirror rule, removing a break that *follows* a hard newline, looks equally sound and is not here. It
is not safe: `sepByIndent` spells its first item after an `align` and every later item after a
`text "\n"`, so the mirror fires on the later items only and leaves the first one a column to their
right — which is `checkColGe`'s reference column, so the second `where` binding parses outside the
block. Measured on the `where` block of `Mathlib/Util/Superscript.lean:312`. A break before a newline
cannot move a column because nothing follows it on that line; a break after one always can.

The walk stops at the first leaf that emits anything: it descends through `nest`, `group`, `tag`, and a
provably empty sibling, and gives up at a `text` or an `align`. So the break it removes is the one
*adjacent* to the newline that asked, never a break further in with content between. -/
private partial def dropTrailingBreak : Std.Format → Option Std.Format
  | .line => some .nil
  | .nest indent inner => (dropTrailingBreak inner).map (.nest indent ·)
  | .group inner behavior => (dropTrailingBreak inner).map (.group · behavior)
  | .tag tag inner => (dropTrailingBreak inner).map (.tag tag ·)
  | .append left right =>
    if provablyEmpty right then (dropTrailingBreak left).map (.append · right)
    else (dropTrailingBreak right).map (.append left ·)
  | _ => none

/- The same document with every break removed, or the leaf that made that impossible.

This is `Std.Format`'s own flattening, spelled out because the renderer's lives inside `be` and is not
callable: `line` becomes `text " "`, an unforced `align` becomes nothing, and a `group` is only a
decision about breaks the subtree no longer has.

Two leaves survive flattening -- a forced `align`, which pads or breaks to the indent either way, and a
`text` carrying a newline, which `Format.text` re-indents rather than removes. Both are reported rather
than silently kept: a caller flattens because it is about to join this subtree onto a line, and a
subtree that still breaks after joining produces exactly the reparse the join was meant to prevent.

`nest` is kept. It is inert in a subtree that emits no newline, and dropping it would have to be
justified against exact islands, whose cancelling nests are computed against `ambientNest`. -/
private partial def flattenNative : Std.Format → Except String Std.Format
  | .nil => return .nil
  | .line => return .text " "
  | .align force => if force then throw "a forced alignment" else return .nil
  | .text value =>
    if value.contains '\n' then throw s!"the multi-line leaf {repr value}" else return .text value
  | .nest indent inner => return .nest indent (← flattenNative inner)
  | .append left right => return .append (← flattenNative left) (← flattenNative right)
  | .group inner _ => flattenNative inner
  | .tag tag inner => return .tag tag (← flattenNative inner)

private def finishConstraint (result : Transformed) (carrier? : Option ConstraintCarrier := none) :
    StateT TransformState (Except String) Transformed := do
  let some carrier := carrier? | return result
  let state ← get
  match result.span? with
  | none =>
    return result
  | some span =>
    match
      state.constraints.findIdx? fun (constraint, expected) =>
        expected == span && constraint.carrier == carrier with
    | some index =>
      if state.appliedConstraints.contains index then
        return result
      let (constraint, _) := state.constraints[index]!
      set
          { state with
            appliedConstraints := state.appliedConstraints.push index
            metrics :=
              { state.metrics with offsideConstraints := state.metrics.offsideConstraints + 1 } }
      return { result with
          format := .nest constraint.indentAdjustment result.format, hoist? := none }
    | none =>
      return result

/- Remove every break inside a span the facts marked as joinable.

Keyed by span and taken by the *deepest* node whose span matches, because the walk is post-order. That
is not incidental. An `append` of the span and the layout leaf after it carries the same span -- a
pure-layout leaf contributes none -- and flattening *that* would eat the separator the next sibling
needs. The deeper node claims the span first and every enclosing one declines.

No metric of its own. The boundary that joins the bail-out onto the bar's line already counted this
correction, and counting the second half again would report two rules where one fired. -/
private def finishFlatten (result : Transformed) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  let some span := result.span? | return result
  match state.flattened.findIdx? (· == span) with
  | none =>
    return result
  | some index =>
    if state.appliedFlattened.contains index then
      return result
    match flattenNative result.format with
    | .error leaf =>
      throw
          s!"native formatter cannot join a guarded bail-out onto the bar's line: its document \
holds {leaf}, which flattening cannot remove"
    | .ok format =>
      set { state with appliedFlattened := state.appliedFlattened.push index }
      return { result with
          format, hoist? := none }

/- Put a block's dangling comment back at the end of that block.

`finishConstraint`'s `.boundary` carrier already names the shape this needs: an `append` whose left is
the break before a span and whose right spells exactly that span. Here the span is the block's last
statement, so appending a break and the payload after the right side puts the comment one break
further along the same item list the statement is in — at the statement's own column, and outside the
group that decides the statement's own layout.

The break is a `text "\n"`, the same leaf the document's own item separator is, and not a `line`. A
`line` is discretionary and the enclosing group is a `fill`, which flattens item by item: a comment
short enough to fit rendered as a *space* after the statement, and reparsed as its trailing trivia
rather than the block's dangling trivia. `text "\n"` re-indents to the current level, which at this
point is the level the sibling separators were emitted at.

Nothing follows the payload. This runs only for a comment past the command's last token, so nothing in
the command's document follows it and the module boundary supplies the break.

There is no fallback. A block whose document holds no such break is a block this cannot place a
comment in, and the alternative to refusing is emitting the comment at some other column — where
reparsing hands it to a different owner and the comment gate refuses anyway, later and with a worse
message. -/
private def finishTrailing (left right : Transformed) :
    StateT TransformState (Except String) (Option Std.Format) := do
  let state ← get
  let some span := right.span? | return none
  unless left.span?.isNone && hasLineBoundary left.format do
    return none
  -- Every comment this block still owns, not the first: a block can end in more than one dangling
  -- comment, and `Mathlib/Tactic/Linter/ValidatePRTitle.lean` ends one in two. They have to leave
  -- together, because the site is chosen by span and the *next* site with this span is an enclosing
  -- node, one nest level out -- which is the column the whole mechanism exists to avoid.
  let pending :=
    (List.range state.trailing.size).filter fun index =>
      state.trailing[index]!.1 == span && !state.appliedTrailing.contains index
  if pending.isEmpty then
    return none
  let comments := pending.map fun index => state.trailing[index]!.2
  -- `Format.text` re-indents its newline to the *current* indent, and the node that claims a span is
  -- not always at the indent that span's line was laid out at: post-order reaches the deepest such node
  -- first, and an `if`/`else` chain as a block's last item puts one more `nest` between the two. So the
  -- difference is cancelled rather than assumed away, against the depth the boundary in front of the
  -- block recorded. Without it a comment closing a nested block came out one level too deep and
  -- reparsed as dangling on the inner block instead of the one that owns it.
  let target := (state.boundaryNest.find? (·.1 == span.start)).map (·.2) |>.getD state.ambientNest
  set
      { state with
        appliedTrailing := state.appliedTrailing ++ pending.toArray
        metrics :=
          { state.metrics with
            commentLeaves := state.metrics.commentLeaves + comments.length
            commentConstraints := state.metrics.commentConstraints + comments.length } }
  return some
      (comments.foldl (init := right.format) fun document comment =>
        .append document
          (.nest (target - state.ambientNest) (.append (.text "\n") (.text comment.payload))))

/- Every span-keyed correction a finished node can carry, in the order they compose, so that adding a
node kind to the walk cannot silently skip one. A constraint's `nest` is inert inside a subtree that no
longer breaks, so the order matters only in that it is fixed. -/
/- The reserved tag marking a plan-owned structural anchor interval (LAY-ANCHOR-ENGINE), applied by
`finishAnchors` around the deepest node spelling exactly the interval's terminals and lowered to
`Doc.anchor` by `lowerNative`. Distinct from `explodedCloseTag`; no native document carries either,
so a collision is impossible by the same argument `markerCollision?` makes for island markers. -/
private def anchorTag : Nat :=
  0x6C65616E466D75

/- The open/close spine markers for an anchor interval that is a *sub-sequence* of an append chain
rather than one of its subtrees -- the shape every `sepByIndent` list takes, where items and
separators splice in one right-leaning chain and no node spans exactly the items. `finishAnchors`
tracks the outermost finished node starting (resp. ending) exactly at the interval's edge; the
append case drops the marker where the chain next leaves the interval; `isolateAnchors` pairs them
after the walk and re-associates the chain, which the renderer's append-associativity makes
sound. The index rides in the tag so the ledger can name an interval the walk could not claim;
the block sits far below `anchorTag`, and native tags have no producer over parsed source (the
native-layout suite's docstring records that audit), so neither collides. -/
private def anchorOpenMarker (index : Nat) : Nat :=
  0x6C65616E00 + 2 * index

private def anchorCloseMarker (index : Nat) : Nat :=
  0x6C65616E01 + 2 * index

/- Decode an open/close marker as `(interval index, isOpen)`, or none for any other tag. -/
private def anchorMarker? (tag : Nat) : Option (Nat × Bool) :=
  if 0x6C65616E00 <= tag && tag < 0x6C65616E00 + 8192 then
    some ((tag - 0x6C65616E00) / 2, (tag - 0x6C65616E00) % 2 == 0)
  else none

/- Whether this native document's first emission is a break. An anchor wrapped around such a
document would capture the column of no token -- `Doc.anchor`'s development-error case -- so
`finishAnchors` refuses on it instead of lowering a document that fails `Doc.wellFormed`. An
`align` leaf is a break here because it renders as one once the line has broken. -/
private partial def nativeBeginsWithBreak : Std.Format → Bool
  | .nil => false
  | .text s => s.startsWith "\n"
  | .line | .align _ => true
  | .group f _ => nativeBeginsWithBreak f
  | .nest _ f => nativeBeginsWithBreak f
  | .tag _ f => nativeBeginsWithBreak f
  | .append f₁ f₂ => if provablyEmpty f₁ then nativeBeginsWithBreak f₂ else nativeBeginsWithBreak f₁

/- The items of an append spine, in order. Appends are associative in the renderer's machine, so
flattening and rebuilding the spine spells the same bytes with the same decisions. -/
private partial def spineItems : Std.Format → Array Std.Format
  | .append left right => spineItems left ++ spineItems right
  | other => #[other]

/- Whether this native document's last emission is a break: an anchor scope closing after one
would swallow the separator the *following* terminal's row belongs to. -/
private partial def nativeEndsWithBreak : Std.Format → Bool
  | .nil => false
  | .text s => s.endsWith "\n"
  | .line | .align _ => true
  | .group f _ => nativeEndsWithBreak f
  | .nest _ f => nativeEndsWithBreak f
  | .tag _ f => nativeEndsWithBreak f
  | .append f₁ f₂ => if provablyEmpty f₂ then nativeEndsWithBreak f₁ else nativeEndsWithBreak f₂

/- A spine item that is nothing but a break: a `line`, an `align`, or a text of only newlines.
Leading and trailing items of this shape belong to the ambient layout, not to an anchor's body. -/
private def pureBreakItem : Std.Format → Bool
  | .line | .align _ => true
  | .text s => !s.isEmpty && s.all (· == '\n')
  | _ => false

/- Wrap the break-free core of a claimed node in the anchor tag, keeping the break items on
either edge -- and any `group`/`nest`/`tag` wrappers around them -- exactly where the ambient
layout put them. Edge items are spine items that are nothing but a break (`line`, `align`, a
text of only newlines) or provably empty; they belong to the ambient layout: the separator in
front of the first terminal positions the row the anchor captures, and the one behind the last
positions the next construct. The breaks are not hoisted out of a wrapper: `group (line ++ rest)`
becomes `group (line ++ tag rest)`, so the group's flattening decision is unchanged and the
anchor captures its first token's column wherever the break landed it. Descent is only sound
through a *single* wrapped core item -- a break-led first item beside siblings would put the tag
inside it and leave the siblings outside the scope -- so anything else with no break-free core
(a glued `\nfoo` text leaf is the reachable shape) is `none`, which the caller refuses on. -/
private partial def wrapAnchorCore (anchorTag : Nat) (format : Std.Format) : Option Std.Format :=
  let items := spineItems format
  let edge (item : Std.Format) : Bool := pureBreakItem item || provablyEmpty item
  let lead := items.takeWhile edge
  let rest := items.drop lead.size
  let trail := rest.reverse.takeWhile edge
  let core := rest.take (rest.size - trail.size)
  let chain (parts : Array Std.Format) : Std.Format := parts.foldl (init := .nil) Std.Format.append
  if core.isEmpty then none
  else
    let attach (inner : Std.Format) : Std.Format := chain (lead ++ #[inner] ++ trail)
    if nativeBeginsWithBreak (chain core) || nativeEndsWithBreak (chain core) then
      if core.size == 1 then
        match core[0]! with
        | .group f behavior =>
          (wrapAnchorCore anchorTag f).map fun wrapped => attach (.group wrapped behavior)
        | .nest k f => (wrapAnchorCore anchorTag f).map fun wrapped => attach (.nest k wrapped)
        | .tag t f => (wrapAnchorCore anchorTag f).map fun wrapped => attach (.tag t wrapped)
        | _ => none
      else none
    else attach (.tag anchorTag (chain core))

/- Claim a plan-owned structural anchor interval. Two shapes, both grammar-independent:

- *Exact*: the interval is one node's terminal span. The deepest such node wraps in
  `.tag anchorTag` directly -- an `append` beside pure layout carries the same span, and the
  deeper node claims it first, so the scope opens at the interval's first terminal rather than
  swallowing the separator in front of it.
- *Sub-sequence*: the interval is a run of items inside a `sepByIndent`-shaped append chain, so
  no node spans it. The outermost finished node starting (resp. ending) exactly at the interval's
  edge is recorded as the open (resp. close) candidate -- post-order ascent means each overwrite
  names a strictly outer node -- and the append case drops the spine markers.

A body that would begin with a break is refused rather than lowered into `Doc.anchor`'s
development-error case; `hoist?` is cleared like `finishConstraint` does. -/
private def finishAnchors (result : Transformed) :
    StateT TransformState (Except String) Transformed := do
  let some span := result.span? | return result
  let mut result := result
  for index in [0:(← get).anchors.size]do
    let state ← get
    let interval := state.anchors[index]!
    if state.appliedAnchors.contains index then
      continue
    if interval == span then
      -- The scope opens at the interval's first terminal and closes after its last: break items
      -- on either edge belong to the ambient layout, so the claim wraps the break-free core in
      -- place (`wrapAnchorCore`). A node with no break-free core captures nothing and refuses
      -- here, before `Doc.wellFormed` would have to.
      match wrapAnchorCore anchorTag result.format with
      | some claimed =>
        set
            { state with
              appliedAnchors := state.appliedAnchors.push index
              anchorOpens := state.anchorOpens.filter (·.1 != index)
              anchorCloses := state.anchorCloses.filter (·.1 != index) }
        result :=
          { result with
            format := claimed, hoist? := none }
      | none =>
        let range? := state.terminals[span.start]?.map (·.range)
        let fullSource := (← get).source
        let slice :=
          match range? with
          | some r =>
            (fullSource.toRawSubstring.drop r.start).take (min 100 (r.stop - r.start)) |>.toString
          | none => "<none>"
        throw
            s!"structural anchor interval {span.start}:{span.stop} has no break-free core; the \
scope must open at the interval's first terminal; near '{slice}'"
    else if interval.start <= span.start && span.stop <= interval.stop then
      let opens :=
        if span.start == interval.start && !nativeBeginsWithBreak result.format then
          (state.anchorOpens.filter (·.1 != index)).push (index, span)
        else state.anchorOpens
      let closes :=
        if span.stop == interval.stop && !nativeEndsWithBreak result.format then
          (state.anchorCloses.filter (·.1 != index)).push (index, span)
        else state.anchorCloses
      modify fun s =>
          { s with
            anchorOpens := opens, anchorCloses := closes }
  return result

private def finishNode (result : Transformed) (carrier? : Option ConstraintCarrier := none) :
    StateT TransformState (Except String) Transformed := do
  finishFlatten (← finishConstraint (← finishAnchors result) carrier?)

/- The unapplied island covering the terminal the transform is waiting for, if any. An island consumes
every terminal it covers at once, so this stays fixed at the island's first covered terminal for as
long as the formatter is still spelling that island's leaves. -/
private def islandAt (state : TransformState) : Option ExactIsland :=
  match state.terminals[state.terminalIndex]? with
  | none => none
  | some terminal =>
    state.islands.find? fun island =>
      !state.appliedIslands.contains island.marker && island.range.start <= terminal.range.start &&
        terminal.range.stop <= island.range.stop

/- An exact island's bytes are its whole rendering, so native layout emitted *between* the terminals it
covers is inside a region the source owns and must not be emitted.

The boundary *before* the island is not: it separates the island from the token ahead of it, and is the
adapter's to keep. The terminal index alone cannot tell those two cases apart, because it does not
advance until the island is applied. `enteredIslands` is what separates them -- an island is entered by
the first native leaf that spells one of its covered terminals, so a boundary is suppressed only once
the formatter has started spelling that island's interior. Suppressing the boundary ahead of an island
instead is what ran `=>` into the quotation after it. -/
private def insideIsland (state : TransformState) : Bool :=
  match islandAt state with
  | none => false
  | some island => state.enteredIslands.contains island.marker

/- Whether the source began a line with the terminal at `index`.

A comment is the previous token's trailing trivia exactly when it sits on that token's line, and the
next token's leading trivia otherwise; Lean's tokenizer ends trailing trivia at the newline. So a
comment that the source put on its own line has to keep starting one, or reparsing the output hands it
to a different owner with a different placement -- which is what the `comments` validation gate
compares. A comment that shared its owner's line has no such constraint: staying adjacent is what
keeps it trailing.

This is only consulted where the document native layout produced since the previous terminal is
provably empty — the one case where the output is certainly on the previous token's line. -/
private def beganLine (state : TransformState) (index : Nat) : Bool :=
  if index == 0 then false
  else
    match state.terminals[index - 1]?, state.terminals[index]? with
    | some previous, some next =>
      (slice state.source ⟨previous.range.stop, next.range.start⟩).contains '\n'
    | _, _ => false

/- How far the constraints that will wrap this span move it, in columns.

`ambientNest` is the native document's own nest depth, which is what the walk carries. A constraint
introduces a `nest` the native document never had, at an ancestor -- and post-order finishes that
ancestor *after* this subtree is built, so the walk cannot have seen it yet. The spans are known
before the walk starts, so a node can ask for them by containment instead of waiting.

Every collected constraint is applied or `transform` refuses the command, so a constraint whose span
contains this one is indentation this subtree will certainly sit inside.

Only exact islands need this, and only because their bytes carry absolute source columns that a
cancelling `nest` has to reach. Without it a constructor docstring spanning more than one line came
out with its first line moved and its continuations left behind. -/
private def containingConstraintNest (state : TransformState) (span : TokenSpan) : Int :=
  state.constraints.foldl (init := 0) fun total (constraint, expected) =>
    if expected.start <= span.start && span.stop <= expected.stop then
      total + constraint.indentAdjustment
    else total

/- Every column between the enclosing command's own and the one a row opened here would start at:
`baseIndent`, the document's own `nest` depth, and every constraint that will wrap this terminal. A
`dedented` boundary cancels exactly this, and so does every row inside the command that boundary
opens. -/
private def dedentColumns (state : TransformState) : Int :=
  let span : TokenSpan := ⟨state.terminalIndex, state.terminalIndex⟩
  state.baseIndent + state.ambientNest + containingConstraintNest state span

/- The same count where the `dedented` boundary spells it, floored at zero.

A dedent cancels columns that are there; it never adds columns that are not. `dedentColumns` reads
negative exactly where the document has already dedented *past* the enclosing command's own column,
and `-(dedentColumns)` is then a positive `nest`: the boundary indents the row it was collected to
straighten. A chain of command embeddings drives it. `open Nat in` spells `nest -2` around its
embedded command and `categoryParser` spells `nest 2` inside it, and the two cancel at that
command's own terminals -- but a second embedding's boundary leaf sits between them, inside the
outer dedent and outside the inner nest, and reads -2. The row it opened landed at column 2, the
next embedding at 4, one level per embedding past the first. `open A in open B in theorem`
reproduces it and a single embedding does not, which is why a corpus full of the one-deep form
never showed it.

The floor is for the row the boundary *opens*, not for the rows it contains. `interiorDedent` reads
the recorded amount, and inside such a chain the interior rows really do sit two columns left of
where the enclosing command puts them, so they need the signed value -- flooring it there strands
a declaration body at column zero. The boundary asks where this row starts and the interior asks
how far its rows drifted; the sign only makes sense for the second.

Flooring rather than declining keeps the boundary idempotent, which is what the correction is built
on: where the document already sits at the command's column there is nothing to cancel, and `nest 0`
spells the same newline the document did. -/
private def dedentCancellation (state : TransformState) : Int :=
  max 0 (dedentColumns state)

/- The cancellation a row opened at this terminal inherits from a nested command it is *inside*.
Nothing for a row that opens one -- `dedented` already sets that row's column, absolutely -- and
nothing for a row past the command's last terminal, which the enclosing command lays out.

A command nested inside another takes the innermost, not the sum. Each recorded amount is the whole
distance to column zero from where its own boundary landed, so two of them do not compose; the inner
one was measured inside the outer and already carries it. -/
private def interiorDedent (state : TransformState) : Option Int :=
  let containing :=
    state.dedents.filter fun (span, _) =>
      span.start < state.terminalIndex && state.terminalIndex < span.stop
  (containing.foldl (init := none) fun best entry =>
        match best with
        | some (bestSpan, _) => if entry.1.start > bestSpan.start then some entry else best
        | none => some entry).map
    (·.2)

/- The marker an `explodedClose` boundary carries until the `.nest` rewrite cancels it. A reserved
value rather than a native one: `formatCategory` emits no such tag, and the rewrite consumes the
leaf before rendering, so no renderer ever interprets it. -/
private def explodedCloseTag : Nat :=
  0x6C65616E466D74

/- The column a row opened at this terminal actually starts at, which is the document's own nest less
the cancellation a nested command's rows inherit (`interiorDedent`).

`constrainBoundary` wraps everything this terminal emits in that cancellation, *outside* whatever
`boundaryFormat` returns, so a spelling that computes a column has to account for it or the
cancellation is applied to the column twice. Both absolute pins do compute one; the three fixed-text
spellings do not and are unaffected. A `let` body pinned to source column 2 inside a `#guard_msgs in`
command -- the one embedding parser with no `ppDedent` of its own, so the only one whose rows carry a
cancellation -- came out at column 0, and since the pin is collected only for a body the source
already broke onto its own row, the first pass created exactly the condition the second pass then
mis-pinned. 13 mathlib modules refused as non-idempotent for it.

`containingConstraintNest` is deliberately *not* here, though `dedentColumns` carries it and the
same staleness argument applies: a constraint wrapping this subtree is a `nest` the post-order walk
has not finished, so `ambientNest` reports the column this row would have had without it. Adding it
is a one-line change and it was measured: 13 modules in this repository stopped reparsing, because
`columned`'s "only ever move right" is calibrated against a `rowIndent` that excludes it and a
smaller `rowIndent` lets the `max` push rows past the offside column their siblings sit at. The
staleness is real and is instead avoided at the source -- `chainedOperandRanges` declines any
operand a pin sits inside, so no constraint ever wraps a `columned` row. -/
private def rowIndent (state : TransformState) : Int :=
  state.ambientNest - (interiorDedent state).getD 0

/- What the adapter spells at a boundary it corrects. Four are fixed text; the rest compute a
`nest` against the document's own: `dedented` cancels every column between the enclosing command's
and this one, and the two column pins hold a row where their constructor says. -/
private def boundaryFormat (state : TransformState) : BoundaryLayout → Std.Format
  | .flat => .text " "
  | .hard => .text "\n"
  | .elided => .nil
  | .dedented => .nest (-(dedentCancellation state)) (.text "\n")
  -- A pin holds a row the document left *behind*: the collectors exist because the document
  -- moved a sibling and stranded this row at a column that no longer parses. When the document
  -- instead re-indented the whole construct past the pin's column, the pin's column is stale —
  -- holding it would move the row *left* of where every sibling just went, which is how an arm
  -- body ends up left of its own `|`. So this pin only ever moves a row right, and `anchored`
  -- below is the one whose row must move either way.
  | .columned col => .nest ((max (col : Int) (rowIndent state)) - rowIndent state) (.text "\n")
  -- `dedentColumns`, not `ambientNest`: an exact column has to be measured against every column
  -- in front of this row, and the document's own nest is one of three. The pin above survives
  -- the difference because `max` only ever discards it; this one renders it directly.
  | .anchored col =>
    .nest ((col : Int) - dedentColumns state + (interiorDedent state).getD 0) (.text "\n")
  | .explodedClose => .tag explodedCloseTag (.text "\n")

/- Replace every `explodedClose` marker in `format` with a `nest (-indent)`, reporting whether any
was found.

The closing bracket of an exploded collection sits inside the collection's own `nest`, so a plain
hard break there lands at the elements' indent. Black's layout dedents the bracket to the
collection's line, and the amount is the nest itself -- unknowable at `constrainBoundary` time,
where the boundary is spelled. The `.nest` case is where both halves meet: the node's span says
whether it wraps the collection, and `indent` is the amount to cancel. Nested exploded collections
compose: the inner collection's nest is rebuilt first (post-order) and consumes its own marker,
so each rewrite finds exactly the marker it owns. A collection whose document carries no matching
nest keeps its marker, which renders as a plain break at the elements' indent -- a fallback, not
a refusal. -/
private partial def dedentExplodedClose (indent : Int) (format : Std.Format) : Std.Format × Bool :=
  match format with
  | .tag tag inner =>
    if tag == explodedCloseTag then (.nest (-indent) inner, true)
    else
      let (inner, found) := dedentExplodedClose indent inner
      (.tag tag inner, found)
  | .nest amount inner =>
    let (inner, found) := dedentExplodedClose indent inner
    (.nest amount inner, found)
  | .group inner behavior =>
    let (inner, found) := dedentExplodedClose indent inner
    (.group inner behavior, found)
  | .append left right =>
    let (left, foundLeft) := dedentExplodedClose indent left
    let (right, foundRight) := dedentExplodedClose indent right
    (.append left right, foundLeft || foundRight)
  | leaf => (leaf, false)

/- The boundary format, and whether it is a hoistable comment insertion (`Transformed.hoist?`).

Hoistable means the whole boundary can be re-parented under fewer `nest`s without invalidating any
column in it: comments were inserted here, every payload is single-line (a multi-line payload's
cancelling `nest` is computed against this point's ambient nest), no nested-command dedent applies
(`interior`), and the collected layout applied here -- if any -- is one of the relative spellings
(`flat`/`hard`/`elided`). A `columned` pin and a `dedented` cancellation are spelled against the
ambient nest at this point, so hoisting them would move rows they exist to hold. -/
private def constrainBoundary (format : Std.Format) :
    StateT TransformState (Except String) (Std.Format × Bool) := do
  let state ← get
  unless state.boundaryNest.any (·.1 == state.terminalIndex) do
    -- The column this row is laid out at, which inside a nested command is not `ambientNest`: every
    -- row there is cancelled back by the amount its command's boundary cancelled. `finishTrailing`
    -- reads this to place a dangling comment at its block's own column, so it has to be the column the
    -- block's items really got rather than the one the native document chose for them.
    modify fun state =>
        { state with
          boundaryNest :=
            state.boundaryNest.push
              (state.terminalIndex, state.ambientNest - (interiorDedent state).getD 0) }
  let state ← get
  if insideIsland state then
    return (.nil, false)
  -- Whether the native document spelled anything at all between the previous terminal and this
  -- one. A collected boundary that fires on empty padding *replaces nothing*: it stands where the
  -- grammar put no separator leaf, inside whatever private wrapper the following item carries, so
  -- it is hoistable on the same terms as a comment insertion (`Transformed.hoist?`). A separator
  -- `line` never satisfies this, so boundaries that correct an existing leaf are untouched.
  let nativeEmpty := provablyEmpty format
  let mut format := format
  -- A boundary that carries more than a plain break -- a dedent, a column pin, the exploded
  -- close's marker -- governs every row the comment insertion below opens, not only the one the
  -- native document spelled: a row-ending comment replaces the boundary leaf itself (`insertComments`
  -- drops the suffix once a line comment has ended the row), so the row break after the comment *is*
  -- the boundary and must spell the collected layout's format. A `flat`/`hard`/`elided`
  -- boundary spells nothing a plain `"\n"` does not -- or is a join the comment's own newline already
  -- overruled -- and keeps the default. See `insertComments`.
  let mut rowBreak : Std.Format := .text "\n"
  -- Set false when a boundary whose spelling is keyed to this point's ambient nest is applied.
  let mut layoutHoistable := true
  -- Whether a collected boundary was applied here. Only read with `nativeEmpty`.
  let mut boundaryApplied := false
  -- The first boundary leaf at this terminal, and only the first: the document can lay out more than
  -- one leaf between two terminals, and a correction that fired at each of them would spell itself
  -- twice. Eliding a doubled newline depends on exactly this -- it removes the first of the two.
  if let some (_, layout) :=
      state.boundaries.find? fun (index, _) => index == state.terminalIndex then
    unless layout matches .flat | .hard | .elided do
      layoutHoistable := false
    if layout matches .dedented | .columned _ | .anchored _ | .explodedClose then
      rowBreak := boundaryFormat state layout
    unless state.appliedBoundaries.contains state.terminalIndex do
      set
          { state with
            appliedBoundaries := state.appliedBoundaries.push state.terminalIndex
            -- The command this boundary opens, and how far its rows are from the column the boundary just
            -- set. Recorded here because this is where the amount is known: it is the ambient nest the
            -- boundary cancelled, and a collector reading the syntax cannot tell whether the embedding
            -- node nested the command or spelled `ppDedent` and did not.
            dedents :=
              if layout matches .dedented then
                match
                  state.nestedCommands.find? fun span : TokenSpan =>
                    span.start == state.terminalIndex with
                | some span => state.dedents.push (span, dedentColumns state)
                | none => state.dedents
              else state.dedents
            metrics :=
              { state.metrics with offsideConstraints := state.metrics.offsideConstraints + 1 } }
      format := boundaryFormat state layout
      boundaryApplied := true
  let state ← get
  -- Every row this boundary opens inside a nested command is cancelled the way that command's own
  -- boundary was. `dedented` sets the column of one row and leaves the rest carrying the `nest` the
  -- embedding node introduced -- one level in for the command's whole body. The
  -- correction is spelled here rather than around the command's subtree because the boundary in front
  -- of that subtree is a sibling leaf, not part of it, and one `nest` covering both would cancel twice.
  let interior := (interiorDedent state).getD 0
  let start := state.commentIndex
  let mut stop := start
  while h : stop < state.comments.size do
    if state.comments[stop].boundary == state.terminalIndex then
      stop := stop + 1
    else
      break
  -- Whether comments were inserted here and every one of them keeps its columns when the insertion
  -- moves out of the enclosing nests: single-line payloads only, and no absolute cancellation in
  -- the rows. A multi-line payload's dedent is `interior - dedentColumns state`, spelled against
  -- this point's ambient nest -- the same reason `layoutHoistable` exists.
  let mut commentsHoistable := false
  if start < stop then
    let comments := state.comments.extract start stop
    commentsHoistable := comments.all fun comment => !comment.payload.contains '\n'
    set
        { state with
          commentIndex := stop
          metrics :=
            { state.metrics with
              commentLeaves := state.metrics.commentLeaves + comments.size
              commentConstraints := state.metrics.commentConstraints + comments.size } }
    -- A comment payload carries absolute source columns and has to reach column zero whatever row it
    -- lands on, so the `interior` cancellation applied below is subtracted back out here rather than
    -- left to compose with it.
    format ← insertComments (interior - dedentColumns state) rowBreak comments format
  -- ...unless the boundary lies strictly inside a structural anchor interval: the anchor re-bases
  -- every break in its body to the first item's column, which already *includes* this correction's
  -- effect -- the first item's row kept it, being outside the interval -- so cancelling again here
  -- would land the separator rows the correction's amount below the first item. The boundary at
  -- the interval's own first terminal keeps the wrap: it opens the row the anchor captures.
  let anchored :=
    state.anchors.any fun span =>
      span.start < state.terminalIndex && state.terminalIndex < span.stop
  if interior != 0 && !anchored then
    format := .nest (-interior) format
  modify fun state => { state with separated := state.separated || !provablyEmpty format }
  return (format,
      (commentsHoistable || (boundaryApplied && nativeEmpty)) && layoutHoistable && interior == 0)

/-- The hoist payload for a hoistable boundary at `state.terminalIndex`, or none when the terminal
heads no recorded construct: without the construct's span the `.nest` privacy test cannot be
made, and not hoisting is the behavior the walk had before `hoist?` existed. -/
private def hoistPayload? (state : TransformState) (hoistable : Bool) (boundary rest : Std.Format) :
    Option (Std.Format × Std.Format × TokenSpan) :=
  if hoistable then
    (state.headSpans.find? (·.1 == state.terminalIndex)).map fun (_, span) => (boundary, rest, span)
  else none

private def consumeIsland (value : String) (island : ExactIsland) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  let start := state.terminalIndex
  let mut stop := start
  while stop < state.terminals.size && state.terminals[stop]!.range.start < island.range.stop do
    let terminal := state.terminals[stop]!
    unless island.range.start <= terminal.range.start && terminal.range.stop <= island.range.stop do
      throw
          s!"exact island {island.range.start}:{island.range.stop} cuts terminal \
{terminal.range.start}:{terminal.range.stop}"
    stop := stop + 1
  if start == stop then
    throw
        s!"exact island {island.range.start}:{island.range.stop} contains no terminal at index \
{start}/{state.terminals.size}; nearby: {nearbyTerminals state}; recent native leaves: \
{repr state.recentNativeLeaves}"
  let (leading, trailing) := splitPadding value
  -- The boundary in front of the island, asked for at the island's own first terminal and asked here
  -- because this is one of the two places that terminal is ever visited. `transform` keeps a boundary
  -- collected at an island's first terminal on purpose — it separates the island from the token
  -- before it, and that separator is the adapter's — but this consumed `start`..`stop` in one step
  -- and never called `constrainBoundary`, so the boundary stayed collected and unapplied and the
  -- command was refused.
  let (boundary, _) ← constrainBoundary (.text leading)
  -- `startsLine` is the fallback for a comment island whose break the document did not spell. An
  -- applied boundary is the same decision made by a rule that read the grammar, so it wins outright
  -- rather than composing -- both spell `\n`, and both would spell a blank line.
  let state ← get
  let startsLine :=
    island.comment && !state.separated && leading.isEmpty && beganLine state start &&
      provablyEmpty boundary
  set
      { state with
        terminalIndex := stop
        separated := false
        appliedIslands := state.appliedIslands.push island.marker
        metrics :=
          { state.metrics with
            nativeNodes := state.metrics.nativeNodes + 1
            tokenLeaves := state.metrics.tokenLeaves + 1
            exactIslands := state.metrics.exactIslands + 1
            exactIslandBytes := state.metrics.exactIslandBytes + island.text.utf8ByteSize } }
  let state ← get
  -- The leading padding is `boundary`'s now, not the payload's: `constrainBoundary` returns it
  -- unchanged when no rule claims this terminal, and replaces it when one does.
  let payload := Std.Format.text (island.text ++ trailing)
  -- A single-line payload has no interior newline for the ambient indentation to reach.
  let payload :=
    if island.text.contains '\n' then
      .nest (-(state.baseIndent + state.ambientNest + containingConstraintNest state ⟨start, stop⟩))
        payload
    else payload
  let payload := if startsLine then .append (.text "\n") payload else payload
  finishNode { format := .append boundary payload, span? := some ⟨start, stop⟩ }

/- Place every island the formatter dropped that starts exactly at the next terminal, glued to
the terminal just consumed rather than to the next leaf the document happens to spell.

A dropped marker leaves no leaf between the terminal before the island and the terminal after it,
so either neighbor can carry the island. The *previous* terminal is the right owner: the document
nodes are assembled around the leaves that exist, and an island appended to the following sibling
merges its span into that sibling's. Every span-keyed correction naming the sibling's own span then
misses -- `Mathlib/Tactic/Simproc/VecPerm.lean` reported `applied 0/2 offside constraints` because a
dropped `m!"…"` island, placed ahead of the continuation's leaf, left the break before the
continuation with a span of its own and the `.boundary` carrier unmatched; the guarded-let bail-out
the island belonged to likewise no longer had a node spanning it, so its flatten was next. Glued to
the previous terminal, the island lands inside the bail-out's own node, the flatten joins
`throwError m!"…"` back onto the guard's line, and the continuation's break stays pure layout.

The separator evidence is the same as `transformText`'s pending path: the source gap between the
previous terminal and the island, as a boolean, spelled `.line` so the renderer owns the break. -/
private partial def placeDroppedIslandsAfter (result : Transformed) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  let pending? :=
    state.terminals[state.terminalIndex]?.bind fun terminal =>
      state.islands.find? fun island =>
        state.droppedIslands.contains island.marker &&
          !state.appliedIslands.contains island.marker &&
          island.range.start == terminal.range.start
  match pending? with
  | none =>
    return result
  | some exact =>
    let sourceGap :=
      if state.terminalIndex == 0 then ""
      else
        match state.terminals[state.terminalIndex - 1]? with
        | some previous => slice state.source ⟨previous.range.stop, exact.range.start⟩
        | none => ""
    let separate := !state.separated && !sourceGap.isEmpty
    let island ← consumeIsland exact.marker exact
    let island := if separate then { island with format := .append .line island.format } else island
    placeDroppedIslandsAfter
        { result with
          format := .append result.format island.format
          span? := mergeSpan result.span? island.span?
          -- The island inserted itself between the boundary and the payload the hoist split
          -- describes, so the split no longer tracks the format.
          hoist? := none }

private def transformOrdinaryText (value : String) :
    StateT TransformState (Except String) Transformed := do
  let state ← get
  if value.trimAscii.isEmpty then
    set
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let (boundary, hoistable) ← constrainBoundary (.text value)
    let state ← get
    finishNode
        { format := boundary
          hoist? := hoistPayload? state hoistable boundary .nil }
  else if let some island := islandAt state then
    -- This leaf spells a terminal the island covers, so the island's own bytes already carry it.
    -- Recording the entry is what lets `insideIsland` suppress the boundaries that follow it.
    --
    -- The boundary in *front* of the island is not one of those, and it is claimed here because this
    -- leaf is where the island's first terminal is reached whenever the document spells one of its
    -- tokens before the marker. `docSyntaxBody?` protects a doc comment by replacing its body and
    -- leaving `/--` a leaf of its own, so a docstring on an interior declaration always arrives this
    -- way: the entry was recorded, `insideIsland` then held, and the boundary the doc rule collected
    -- at that terminal could never be applied by anyone. `Mathlib/Tactic/CasesM.lean`'s `where` binding
    -- reported this as `applied 4/5 boundaries`.
    let (boundary, _) ←
      if state.enteredIslands.contains island.marker then
        pure (.nil, false)
      else
        constrainBoundary (.text (splitPadding value).1)
    modify fun state =>
        { state with
          enteredIslands :=
            if state.enteredIslands.contains island.marker then state.enteredIslands
            else state.enteredIslands.push island.marker
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    return { format := boundary }
  else
    let some terminal := state.terminals[state.terminalIndex]? |
      if commentText value then
        throw s!"comment-free native syntax emitted an interior comment leaf {repr value}"
      else
        throw
            s!"native formatter emitted extra text leaf {repr value} after \
{state.terminalIndex} terminals; nearby: {nearbyTerminals state}"
    -- `withoutTrivia` removes every comment the formatter could re-emit from `SourceInfo`, so a
    -- comment leaf is admissible only where the source spells a doc comment as syntax.
    if commentText value && !commentText terminal.sourceSpelling then
      throw s!"comment-free native syntax emitted an interior comment leaf {repr value}"
    let nativePayload := value.trimAscii.copy
    let normalized :=
      nativePayload != terminal.syntaxSpelling && nativePayload != terminal.sourceSpelling
    let (leading, trailing) := splitPadding value
    let (boundary, hoistable) ← constrainBoundary (.text leading)
    let state ← get
    set
        { state with
          terminalIndex := state.terminalIndex + 1
          separated := !trailing.isEmpty
          metrics :=
            { state.metrics with
              nativeNodes := state.metrics.nativeNodes + 1
              tokenLeaves := state.metrics.tokenLeaves + 1
              normalizedTokens := state.metrics.normalizedTokens + if normalized then 1 else 0 } }
    finishNode
        (←
          placeDroppedIslandsAfter
              { format :=
                  .append boundary (.append (.text terminal.sourceSpelling) (.text trailing))
                span? := some ⟨state.terminalIndex, state.terminalIndex + 1⟩
                hoist? :=
                  hoistPayload? state hoistable boundary
                    (.append (.text terminal.sourceSpelling) (.text trailing)) })

private def transformText (value : String) : StateT TransformState (Except String) Transformed := do
  let state ← get
  set { state with recentNativeLeaves := rememberNativeLeaf state.recentNativeLeaves value }
  let state ← get
  match state.islands.find? fun island => value.trimAscii.copy == island.marker with
  | some island =>
    consumeIsland value island
  | none =>
    -- Only an island the formatter dropped is placed ahead of its own marker. Placing an island the
    -- formatter *will* spell consumes the terminals that marker is still about to claim, which then
    -- reports the island as containing no terminal.
    let pending? :=
      state.terminals[state.terminalIndex]?.bind fun terminal =>
        state.islands.find? fun island =>
          state.droppedIslands.contains island.marker &&
            !state.appliedIslands.contains island.marker &&
            island.range.start == terminal.range.start
    match pending? with
    | some exact =>
      -- The formatter emitted no leaf for this island, so the native document also holds no decision
      -- about what precedes it -- not even whether anything separates it from the previous token.
      -- `dbg_trace s!"flag: {flag}"` formats to `grp[nest2[T"dbg_trace"]]` with no marker and no
      -- `line`, because `pushToken` sees an empty `leadWord` and drops the token's own trailing space.
      -- Re-inserting the bytes without a separator spells `dbg_traces!"flag: {flag}"`.
      --
      -- The source answers it at byte level: whitespace between the previous terminal and the island
      -- start means the two tokens were separated, and nothing else about that whitespace is layout
      -- this adapter may keep. So the evidence is a boolean and the output is a `Format.line`, whose
      -- width the renderer owns exactly as it owns every other break.
      let sourceGap :=
        if state.terminalIndex == 0 then ""
        else
          match state.terminals[state.terminalIndex - 1]? with
          | some previous => slice state.source ⟨previous.range.stop, exact.range.start⟩
          | none => ""
      let separate := !state.separated && !sourceGap.isEmpty
      let island ← consumeIsland exact.marker exact
      let island :=
        if separate then { island with format := .append .line island.format } else island
      let current ← transformOrdinaryText value
      finishNode
          { format := .append island.format current.format
            span? := mergeSpan island.span? current.span? }
    | none =>
      transformOrdinaryText value

private partial def transformNative : Std.Format → StateT TransformState (Except String) Transformed
  | .nil => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    finishNode { format := .nil }
  | .line => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let (boundary, hoistable) ← constrainBoundary .line
    let state ← get
    finishNode
        { format := boundary
          hoist? := hoistPayload? state hoistable boundary .nil }
  -- An `align` is a boundary: it is layout the document put between two terminals, and a comment that
  -- belongs in that gap belongs *here*. It used to be the one boundary leaf that did not go through
  -- `constrainBoundary`, so a comment landing in this gap was carried to the next leaf that did --
  -- the following terminal's own leading padding, which is inside that terminal's `nest`. The comment
  -- then rendered one level too deep and took the terminal with it, while the sibling items stayed on
  -- the align's column, which is `sepByIndent`'s reference column: the block ended at the first
  -- sibling. `constrainBoundary` subsumes the island and `separated` handling this case used to spell.
  | .align force => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    -- An `align` pads to the ambient indent at its own point, so it is never hoistable: moving it
    -- out of a `nest` would change what it pads to.
    let (boundary, _) ← constrainBoundary (.align force)
    finishNode { format := boundary }
  | .text value => transformText value
  | .nest indent inner => do
    modify fun state =>
        { state with
          ambientNest := state.ambientNest + indent
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    modify fun state => { state with ambientNest := state.ambientNest - indent }
    -- A hoistable comment prefix climbs out of the nest when -- and only when -- the nest is the
    -- private wrapper of the construct the boundary heads: the sibling separators then live
    -- outside it at the ambient indent, which is where the prefix's rows belong
    -- (`Transformed.hoist?` states the soundness argument). The test is containment of the nest's
    -- own terminal span in the headed construct's, plus two structural exclusions: a negative
    -- nest positions its rows *below* the ambient (`ppDedent`'s `nest -2` over a `match`'s arms,
    -- which the climb misaligned in `LeanFmt/Application.lean`), and a spanless nest wraps the
    -- boundary alone and belongs to it (`first | …`'s separator `nest -2 T"\n"`, the
    -- `tacticComment` fixture). Blocked, the prefix stays inside and stops: a nest it cannot
    -- leave is one its siblings cannot leave either.
    -- A nest whose content spans an exploded collection exactly is the collection's own private
    -- wrapper: the `explodedClose` marker inside cancels this amount, dedenting the closing
    -- bracket to the collection's line. Ancestors can share the span (a body wrapper around the
    -- whole collection), but post-order reaches the innermost first, and it consumes the marker.
    --
    -- The rewrite runs on `inner`, *before* the hoist below: a comment insertion hoisted through
    -- here carries the content in its payload (`Transformed.hoist?`), and rewriting only the
    -- format would leave the payload holding the un-rewritten rest, which the next wrapper up
    -- re-emits -- the `},` of an exploded struct commented as a collection's first element kept
    -- the elements' indent from exactly that.
    let state ← get
    let inner :=
      match inner.span? with
      | some span =>
        if state.explodedSpans.contains span then
          { inner with
            format := (dedentExplodedClose indent inner.format).1
            hoist? :=
              inner.hoist?.map fun (pre, rest, head) =>
                (pre, (dedentExplodedClose indent rest).1, head) }
        else inner
      | none => inner
    let rebuilt :=
      match inner.hoist? with
      | some (pre, rest, head) =>
        match inner.span? with
        | some span =>
          if 0 <= indent && head.start <= span.start && span.stop <= head.stop then
            { format := .append pre (.nest indent rest)
              span? := inner.span?
              hoist? := some (pre, .nest indent rest, head) }
          else { format := .nest indent inner.format, span? := inner.span? }
        | none => { format := .nest indent inner.format, span? := inner.span? }
      | none => { inner with format := .nest indent inner.format }
    finishNode rebuilt (carrier? := some .nest)
  | .append left right => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let left ← transformNative left
    let right ← transformNative right
    let trailing? ← finishTrailing left right
    -- A placed block-dangling comment rewrites the right side wholesale; the hoist split cannot be
    -- tracked through it, so it does not survive.
    let right :=
      match trailing? with
      | some format => ({ format, span? := right.span? } : Transformed)
      | none => right
    -- Read off the *uncorrected* left, because this is what decides whether an offside constraint
    -- keyed to this append is applied here. Removing a redundant break can empty the left side; the
    -- constraint still belongs to this boundary, and an unapplied one refuses the command.
    let carrier? :=
      if left.span?.isNone && hasLineBoundary left.format then some .boundary else none
    -- A discretionary break directly in front of a hard newline, or a hard newline in front of one.
    -- See `dropTrailingBreak` for the first and `dropTrailingHardLine` for the second: `docComment`
    -- (`Term.lean:91-92`) ends with `ppLine`, so a doc comment used as a tactic's own syntax rather
    -- than as a declaration's docstring carries a separator its `sepByIndent` list also spells, and
    -- the two stacked into a line holding nothing but the list's indent.
    let leftFormat :=
      if opensWithNewline right.format then
        (dropTrailingBreak left.format).orElse fun _ => dropTrailingHardLine left.format
      else none
    if leftFormat.isSome then
      modify fun state =>
          { state with
            metrics := { state.metrics with redundantBreaks := state.metrics.redundantBreaks + 1 } }
    -- The hoist prefix survives only while it stays leftmost: a provably empty left side yields
    -- to the right's own prefix; a left side that still carries its prefix keeps it, with the
    -- right appended to its rest. Anything else -- real left content, or a corrected left whose
    -- reassociation the split cannot see through -- clears it.
    let hoist? :=
      match leftFormat with
      | some _ => none
      | none =>
        if provablyEmpty left.format then right.hoist?
        else
          match left.hoist? with
          | some (pre, rest, head) => some (pre, .append rest right.format, head)
          | none => none
    -- The spine-marker half of `finishAnchors`: the outermost open (resp. close) candidate is one
    -- of the children, and this append is where the chain next leaves the interval -- the merged
    -- span is no longer inside it. The marker drops onto the spine at the exact edge: before the
    -- left child or between the children for an open (right-leaning chains hold the interval's
    -- head on the left; a chain entering the interval holds it on the right), after the right
    -- child or between the children for a close. `isolateAnchors` pairs them after the walk, so
    -- same-edge markers nest: opens outermost-first, closes innermost-first. A prepended marker
    -- invalidates the hoist split's `format ≡ .append prefix rest`, so the hoist does not
    -- survive it.
    let mergedSpan := mergeSpan left.span? right.span?
    let mut opensBeforeLeft : Array Nat := #[]
    let mut opensBeforeRight : Array Nat := #[]
    let mut closesAfterLeft : Array Nat := #[]
    let mut closesAfterRight : Array Nat := #[]
    let mut hoist? := hoist?
    for index in [0:(← get).anchors.size]do
      let state ← get
      let interval := state.anchors[index]!
      if state.appliedAnchors.contains index then
        continue
      let inside :=
        match mergedSpan with
        | some span => interval.start <= span.start && span.stop <= interval.stop
        | none => true
      match state.anchorOpens.find? (·.1 == index) with
      | some (_, candidate) =>
        if left.span? == some candidate then
          if inside then
            modify fun s =>
                { s with
                  anchorOpens :=
                    (s.anchorOpens.filter (·.1 != index)).push (index, mergedSpan.getD candidate) }
          else
            opensBeforeLeft := opensBeforeLeft.push index
            hoist? := none
            modify fun s => { s with anchorOpens := s.anchorOpens.filter (·.1 != index) }
        else if right.span? == some candidate then
          if inside then
            modify fun s =>
                { s with
                  anchorOpens :=
                    (s.anchorOpens.filter (·.1 != index)).push (index, mergedSpan.getD candidate) }
          else
            opensBeforeRight := opensBeforeRight.push index
            modify fun s => { s with anchorOpens := s.anchorOpens.filter (·.1 != index) }
      | none =>
        pure ()
      match state.anchorCloses.find? (·.1 == index) with
      | some (_, candidate) =>
        if left.span? == some candidate then
          if inside then
            modify fun s =>
                { s with
                  anchorCloses :=
                    (s.anchorCloses.filter (·.1 != index)).push (index, mergedSpan.getD candidate) }
          else
            closesAfterLeft := closesAfterLeft.push index
            modify fun s => { s with anchorCloses := s.anchorCloses.filter (·.1 != index) }
        else if right.span? == some candidate then
          if inside then
            modify fun s =>
                { s with
                  anchorCloses :=
                    (s.anchorCloses.filter (·.1 != index)).push (index, mergedSpan.getD candidate) }
          else
            closesAfterRight := closesAfterRight.push index
            modify fun s => { s with anchorCloses := s.anchorCloses.filter (·.1 != index) }
      | none =>
        pure ()
    let leftFormat := leftFormat.getD left.format
    let leftFormat :=
      closesAfterLeft.reverse.foldl (init := leftFormat) fun format index =>
        .append format (.tag (anchorCloseMarker index) .nil)
    let leftFormat :=
      opensBeforeLeft.reverse.foldl (init := leftFormat) fun format index =>
        .append (.tag (anchorOpenMarker index) .nil) format
    let rightFormat :=
      closesAfterRight.reverse.foldl (init := right.format) fun format index =>
        .append format (.tag (anchorCloseMarker index) .nil)
    let rightFormat :=
      opensBeforeRight.reverse.foldl (init := rightFormat) fun format index =>
        .append (.tag (anchorOpenMarker index) .nil) format
    finishNode
        { format := .append leftFormat rightFormat
          span? := mergedSpan
          hoist? } carrier?
  | .group inner behavior => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    -- Hoisting through a group lets the group flatten as if the comment were not there: the
    -- comment rows are hard breaks, so the insertion keeps its own layout either way, and a group
    -- whose only forced break was the comment regains its width decision. This is the comment
    -- layout-transparency rule applied inside native groups. A group wrapping the boundary alone
    -- keeps it: that group is the renderer's fit measurement for the break itself, same as the
    -- boundary-only `nest` above.
    let rebuilt :=
      match inner.hoist? with
      | some (pre, rest, head) =>
        if provablyEmpty rest then { inner with format := .group inner.format behavior }
        else
          { format := .append pre (.group rest behavior)
            span? := inner.span?
            hoist? := some (pre, .group rest behavior, head) }
      | none => { inner with format := .group inner.format behavior }
    finishNode rebuilt
  | .tag tag inner => do
    modify fun state =>
        { state with
          metrics := { state.metrics with nativeNodes := state.metrics.nativeNodes + 1 } }
    let inner ← transformNative inner
    -- A tag marks a semantic span; the insertion stays inside it rather than narrowing the mark.
    finishNode
        { inner with
          format := .tag tag inner.format, hoist? := none }

private def spanForRange (terminals : Array Terminal) (range : SourceRange) : TokenSpan :=
  let start := terminals.findIdx? (range.start <= ·.range.start) |>.getD terminals.size
  let stop := terminals.findIdx? (range.stop <= ·.range.start) |>.getD terminals.size
  ⟨start, stop⟩

/- For every terminal that begins one or more syntax nodes, the terminal span of the construct a
boundary at that terminal heads: the smallest node starting at the terminal that extends past it
(`Term.tuple` beside its `hygienicLParen` delimiter wrapper), or, when the terminal *is* the whole
construct (a literal element), the smallest node starting there at all. The `.nest` hoist test
reads it (`Transformed.hoist?`); a boundary whose terminal has no entry does not hoist, which is
the behavior the walk had before hoisting existed.

The multi-terminal preference needs no grammar kinds: a delimiter wrapper spans exactly the token,
a list-grouping node spans the first item *and its siblings* and so is never smaller than the item
node itself, and either way the smallest remaining candidate is the headed construct. -/
private partial def collectHeadSpans (terminals : Array Terminal) (stx : Lean.Syntax)
    (starts : Array (Nat × TokenSpan) := #[]) : Array (Nat × TokenSpan) :=
  match stx with
  | .node _ kind children =>
    let starts :=
      match sourceRange? stx, (selectedLeafRanges stx)[0]? with
      | some range, some leafRange =>
        match terminals.findIdx? (·.range.start == leafRange.start) with
        | some index =>
          let span := spanForRange terminals range
          let width := span.stop - span.start
          -- `next` supersedes an earlier candidate when it is the first multi-terminal one, or a
          -- smaller one: the pre-order walk meets the list before the item and the item before
          -- its delimiter wrapper.
          let supersedes (old : TokenSpan) : Bool :=
            let oldWidth := old.stop - old.start
            if 1 < width then oldWidth <= 1 || width < oldWidth else oldWidth <= 1
          match starts.find? (·.1 == index) with
          | some (_, old) =>
            if supersedes old then
              starts.map fun pair => if pair.1 == index then (index, span) else pair
            else starts
          | none => starts.push (index, span)
        | none => starts
      | _, _ => starts
    let children := if kind == Lean.choiceKind then children[0]?.toArray else children
    children.foldl (init := starts) fun starts child => collectHeadSpans terminals child starts
  | _ => starts

/- Which terminal a collected source offset names: the first one at or after it.

Every rule collects source offsets, because a grammar shape is what it can see; `constrainBoundary`
works in terminal indices, because that is what the walk carries. This is the one place the two meet.

Collectors run independently, so more than one can name the same terminal. `constrainBoundary` applies
a boundary once, so a repeated index would leave the applied count permanently short of the collected
one and turn every such command into a refusal. Two rules asking for the *same* spelling there is a
duplicate and collapses; two rules asking for different spellings is a disagreement about the same
gap, which no order of this table resolves -- so it is refused rather than decided by which collector
the call site happens to list first. Both spellings are named in the refusal: a disagreement is a
rule that needs narrowing, and the pair says which two. -/
private def boundaryTable (terminals : Array Terminal) (starts : Array (Nat × BoundaryLayout)) :
    Except String (Array (Nat × BoundaryLayout)) :=
  starts.foldlM (init := #[]) fun table (start, layout) =>
    match terminals.findIdx? (start <= ·.range.start) with
    | some index =>
      match table.findIdx? fun (existing, _) => existing == index with
      | some slot =>
        let existing := table[slot]!.2
        match existing.join? layout with
        | some joined => .ok (table.set! slot (index, joined))
        | none =>
          let asks := s!"one asks for {existing.describe}, the other for {layout.describe}"
          .error s!"two layout rules disagree at terminal {index}: {asks}"
      | none => .ok (table.push (index, layout))
    | none => .ok table

/-- Why one command's native document could not be adapted, in the only distinction the caller
acts on.

`incomplete` is the toolchain's: the combinators backtrack, so a subtree the formatter cannot
format is omitted rather than reported, and the adapter sees a document that stops short of the
command's terminals. There is nothing here to repair — the document holds no decision about a leaf
it never emitted — so the command degrades to its own bytes, exactly as an escaping
`uncaught backtrack exception` does.

`unadapted` is this module's: a boundary, island, or offside constraint it collected from the
grammar went unapplied, or a comment leaked into comment-free syntax. Those are refusals, and they
stay refusals: `Mathlib/Util/ParseCommand.lean` reported `0/2` terminals when the nested-command
rule reached a `` `(command| …) `` body, and degrading that would have hidden the defect rather
than reporting it. The two are told apart by which check fails, not by reading a message. -/
private inductive TransformFailure where
  | incomplete (detail : String)
  | unadapted (detail : String)

private def TransformFailure.detail : TransformFailure → String
  | .incomplete detail | .unadapted detail => detail

/- Lower an adapted native format onto `Doc`'s native fragment, constructor by constructor, with no
grammar evidence and no structural annotations: nothing here reads the source, the terminals, or a
constraint; the transform above already spent all of that. The mapping is the oracle's `toDoc`
(`tests/Test/Unit/Layout.lean`), so every lowered document renders byte- and tag-event-identically
to the `Std.Format` it came from at any width, indent, and entry column. A newline-bearing `text`
is `nativeText`, the constructor with the native multiline semantics; both flatten behaviors and
both align flags map one-for-one.

The routing is byte-safe at the command boundary for two reasons, both about what surrounds a
command document in whole-module composition (`Analysis.lean`): no enclosing `group` spans a
command document — the assembly is `cat`/`mark`/`nest` only, so the opaque fit boundary
`Doc.registered` used to be was never observed — and every command is followed by zero-width
trailing trivia and a `Doc.hard`, so a trailing group's fit candidate inside the lowered format
measures the same suffix the native run measured: the rest of the format and nothing else. The
top level of the format also keeps the registered run's root semantics, because the only group
above it is the render's own root, which never flattens.

Total over the eight constructors and both flatten behaviors; the one check after it,
`Doc.wellFormed`, is the typed diagnostic for the impossible state (a lowerer that produced a
malformed document), and it refuses rather than degrading to verbatim source. -/
private partial def lowerNative (blocks : Array (Array FillLine) := #[]) : Std.Format → Doc
  | .nil => .empty
  | .line => .line " "
  | .align force => .align force
  | .text value => if value.contains '\n' then .nativeText value else .text value
  | .nest indent body => .nest indent (lowerNative blocks body)
  | .append left right => lowerNative blocks left ++ lowerNative blocks right
  | .group body behavior =>
    match behavior with
    | .allOrNone => .group (lowerNative blocks body)
    | .fill => .fill (lowerNative blocks body)
  | .tag tag body =>
    if tag == anchorTag then .anchor (lowerNative blocks body)
    else
      match fillTag? tag with
      | some index =>
        match blocks[index]? with
        | some lines => Doc.fillWords lines
        -- A tag naming no registered block keeps its body: the verbatim spelling the walk
        -- spliced, which is what the block would have spelled anyway.
        | none => .tag tag (lowerNative blocks body)
      | none => .tag tag (lowerNative blocks body)

/- The one private command plan: every fact the collector assembly derives about a command,
resolved against its terminals exactly once, before the native format exists. The transform and
the lowering consume it completely — every entry must be applied exactly once or the command is
refused — and no part of it is public: there is no `Plan` trait, no evidence registry, and no
callback into the engine, only this structure and its two construction steps.

Phase one (`CommandPlan.collect`) reads the source and the syntax and assembles the raw facts:
terminals, comments, exact islands, offside constraints, and the boundary table with its conflict
order. Phase two (`CommandPlan.resolve`) maps every range-keyed fact onto terminal intervals and
settles the conflicts that need the whole table in hand: one island per marker, no boundary inside
an island, one layout per terminal. A later structural-annotation interval (prompts 09–10) joins
as another resolved field here, not as a parallel channel. -/
private structure CommandPlan where
  source : String
  terminals : Array Terminal
  comments : Array InteriorComment
  trailing : Array (TokenSpan × InteriorComment)
  islands : Array ExactIsland
  constraints : Array (OffsideConstraint × TokenSpan)
  boundaries : Array (Nat × BoundaryLayout)
  flattened : Array TokenSpan
  nestedCommands : Array TokenSpan
  explodedSpans : Array TokenSpan
  headSpans : Array (Nat × TokenSpan)
  /- Plan-owned structural anchor intervals as terminal-index spans (LAY-ANCHOR-ENGINE): validated
  as a proper interval forest at construction, claimed by the deepest node spelling exactly the
  interval's terminals during the walk (`finishAnchors`), lowered to `Doc.anchor`. -/
  anchors : Array TokenSpan := #[]
  baseIndent : Nat
  deriving Inhabited

/-- Phase two: resolve the raw collected facts against the terminal sequence. Every per-range fact
leaves here as a per-interval one, the island/boundary conflicts are settled, and the boundary
table's disagreements are the one typed failure. -/
private def CommandPlan.resolve (source : String) (terminals : Array Terminal)
    (comments : Array InteriorComment) (blockDangling : Array (SourceRange × InteriorComment))
    (islands : Array ExactIsland) (constraints : Array OffsideConstraint)
    (boundaryStarts : Array (Nat × BoundaryLayout)) (joined : Array SourceRange)
    (nestedCommandRanges : Array SourceRange) (explodedRanges : Array SourceRange)
    (headSpans : Array (Nat × TokenSpan)) (baseIndent : Nat)
    (anchorRanges : Array SourceRange := #[]) : Except TransformFailure CommandPlan := do
  let constraints :=
    constraints.map fun constraint => (constraint, spanForRange terminals constraint.range)
  -- An exact island's bytes are its whole rendering, so the adapter spells no boundary between the
  -- terminals it covers and `constrainBoundary` returns nothing there. A boundary collected inside one
  -- can therefore never be applied, and every collected boundary must be applied or the command is
  -- refused -- which is how `Mathlib/Util/ParseCommand.lean` reported `0/2` once the nested-command
  -- rule started reaching the `command` quotations in an `elab_rules`. The collectors read the
  -- grammar, which is where a `` `(command| …) `` body really is a command; whether those bytes are the
  -- adapter's to lay out is decided here, once, for every rule rather than in each of them.
  --
  -- One island per marker. A marker is `markerFor`'s function of the range alone, so two protected
  -- nodes spanning the same bytes -- a node and the only child that fills it -- produce two entries
  -- that no later step can tell apart: the formatter spells one marker, `consumeIsland` applies one,
  -- and `appliedIslands` is short by exactly the duplicates. That is what
  -- `Mathlib/Analysis/InnerProductSpace/Projection/Submodule.lean` reported as `applied 2/4 exact
  -- islands` with no unapplied entry to name. Equal markers mean equal ranges mean equal bytes, so
  -- they are the same island and collapsing them is the whole repair.
  let islands :=
    islands.foldl (init := #[]) fun kept island =>
      if kept.any fun other : ExactIsland => other.marker == island.marker then kept
      else kept.push island
  -- The island's *first* covered terminal keeps its boundary: that boundary separates the island from
  -- the token in front of it and is the adapter's, which is why the bound is strict on the left.
  let boundaryStarts :=
    boundaryStarts.filter fun (start, _) =>
      !islands.any fun island => island.range.start < start && start < island.range.stop
  let boundaries ← (boundaryTable terminals boundaryStarts).mapError .unadapted
  let flattened := joined.map (spanForRange terminals)
  let nestedCommands := nestedCommandRanges.map (spanForRange terminals)
  let explodedSpans := explodedRanges.map (spanForRange terminals)
  -- Structural anchor intervals must form a proper forest: sorted by start, each interval either
  -- closes before the next opens or contains it whole. Two intervals that overlap without
  -- containment would both own their shared region's indentation; refuse at construction rather
  -- than discover it mid-walk. Intervals mapping to the same terminal span collapse, the way
  -- duplicate islands do: one scope per span, and the second would never find a node to claim.
  let sortedAnchors :=
    anchorRanges.qsort fun a b => a.start < b.start || (a.start == b.start && b.stop < a.stop)
  let mut openAnchors : Array SourceRange := #[]
  for range in sortedAnchors do
    unless range.start < range.stop do
      throw <| .unadapted s!"structural anchor interval is empty: {range.start}:{range.stop}"
    let mut stack := openAnchors
    while h : 0 < stack.size do
      if stack[stack.size - 1].stop <= range.start then
        stack := stack.pop
      else
        break
    if let some enclosing := stack.back? then
      unless range.stop <= enclosing.stop do
        throw <|
            .unadapted
              s!"structural anchor intervals overlap without containment: \
{enclosing.start}:{enclosing.stop} and {range.start}:{range.stop}"
    openAnchors := stack.push range
  let anchors :=
    (sortedAnchors.map (spanForRange terminals)).foldl (init := #[]) fun kept span =>
      if kept.contains span then kept else kept.push span
  -- An anchor whose open or close edge falls strictly inside an island's terminal coverage can
  -- never be claimed: the island consumes those terminals in one step, so no node starts or ends
  -- at the edge and the marker never drops. Quotations with an antiquotation are the sighted
  -- shape (`Mathlib/Tactic/ProxyType.lean`): the whole quotation is one exact island, and a
  -- struct instance's fields inside it are not the adapter's to lay out. Edges exactly at an
  -- island's own boundary are fine -- the island's node is a candidate like any other -- as is an
  -- island wholly inside the interval. This is the island/boundary conflict settle's mirror.
  let anchors :=
    anchors.filter fun span =>
      !islands.any fun island =>
          let islandStart := terminals.findIdx? (island.range.start <= ·.range.start)
          let islandStop :=
            terminals.findIdx? (island.range.stop <= ·.range.start) |>.getD terminals.size
          match islandStart with
          | some start =>
            (start < span.start && span.start < islandStop) ||
              (start < span.stop && span.stop < islandStop)
          | none => false
  let trailing := blockDangling.map fun (range, comment) => (spanForRange terminals range, comment)
  let comments :=
    comments.map fun comment =>
      { comment with
        boundary :=
          terminals.findIdx? (comment.range.start < ·.range.start) |>.getD terminals.size }
  return {
    source, terminals, comments, trailing, islands, constraints, boundaries, flattened,
    nestedCommands, explodedSpans, headSpans, anchors, baseIndent }

/- Pair the anchor markers the walk dropped and give each region a subtree: the spine items
between an open and its matching close re-associate under `.tag anchorTag`, and the interval
becomes one node the lowering maps to `Doc.anchor`. Items are processed bottom-up first, so a
nested interval's pair -- which lands on an inner spine or inside a spine item -- wraps before the
enclosing interval's. An unpaired marker (open without close, close without open, a pair split
across spines, or a break-led body) is the interval the walk could not claim, refused by index so
the ledger can name it. -/
private partial def isolateAnchors (plan : CommandPlan) (format : Std.Format) :
    Except TransformFailure (Std.Format × Array Nat) := do
  match format with
  | .append _ _ =>
    let mut applied : Array Nat := #[]
    let mut items : Array Std.Format := #[]
    for item in spineItems format do
      let (item, innerApplied) ← isolateAnchors plan item
      items := items.push item
      applied := applied ++ innerApplied
    let mut out : Array Std.Format := #[]
    let mut stack : Array (Nat × Nat) := #[]
    let spanOf (index : Nat) : String :=
      match plan.anchors[index]? with
      | some span => s!"{span.start}:{span.stop}"
      | none => "?"
    let refuse (index : Nat) (why : String) : Except TransformFailure (Std.Format × Array Nat) :=
      throw <| .unadapted s!"structural anchor interval {spanOf index} could not be isolated: {why}"
    for item in items do
      match item with
      | .tag tag .nil =>
        match anchorMarker? tag with
        | some (index, true) =>
          stack := stack.push (index, out.size)
        | some (index, false) =>
          match stack.back? with
          | none =>
            return ← refuse index "a close marker with no open on its spine"
          | some (openIndex, start) =>
            do
              if openIndex != index then
                return ← refuse index s!"its close met interval {spanOf openIndex}'s open first"
              let region := out.extract start out.size
              let body := region.foldl (init := .nil) Std.Format.append
              if nativeBeginsWithBreak body then
                return ← refuse index "the claimed region begins with a break"
              out := (out.extract 0 start).push (.tag anchorTag body)
              stack := stack.pop
              applied := applied.push index
        | none =>
          out := out.push item
      | _ =>
        out := out.push item
    match stack.back? with
    | some (index, _) =>
      return ← refuse index "an open marker whose spine never closed it"
    | none =>
      return (out.foldl (init := .nil) Std.Format.append, applied)
  | .group inner behavior =>
    let (inner, applied) ← isolateAnchors plan inner
    return (.group inner behavior, applied)
  | .nest indent inner =>
    let (inner, applied) ← isolateAnchors plan inner
    return (.nest indent inner, applied)
  | .tag tag inner =>
    let (inner, applied) ← isolateAnchors plan inner
    return (.tag tag inner, applied)
  | other =>
    return (other, #[])

/-- Transform one native format under a resolved plan. Every ledger refusal below is a plan entry
the walk could not apply exactly once; the counts name the first unapplied entry and the source it
was collected at. -/
private def transform (plan : CommandPlan) (native : Std.Format) :
    Except TransformFailure (Std.Format × Metrics × Array (Array FillLine)) := do
  let spelled := spelledMarkers native
  let droppedIslands :=
    plan.islands.filterMap fun island =>
      if spelled.contains island.marker then none else some island.marker
  let initial : TransformState :=
    { source := plan.source
      terminals := plan.terminals
      comments := plan.comments
      trailing := plan.trailing
      islands := plan.islands
      droppedIslands
      constraints := plan.constraints
      boundaries := plan.boundaries
      flattened := plan.flattened
      nestedCommands := plan.nestedCommands
      explodedSpans := plan.explodedSpans
      headSpans := plan.headSpans
      anchors := plan.anchors
      baseIndent := plan.baseIndent }
  let (result, state) ← ((transformNative native).run initial).mapError .unadapted
  let (isolated, isolatedAnchors) ← isolateAnchors plan result.format
  let appliedAnchors :=
    (state.appliedAnchors ++ isolatedAnchors).foldl (init := #[]) fun kept index =>
      if kept.contains index then kept else kept.push index
  if state.terminalIndex != state.terminals.size then
    throw <|
        .incomplete
          s!"native formatter consumed {state.terminalIndex}/{state.terminals.size} terminals; \
nearby: {nearbyTerminals state}; recent native leaves: {repr state.recentNativeLeaves}"
  if state.commentIndex != state.comments.size then
    let nextRange := state.comments[state.commentIndex]?.map fun comment => comment.range
    throw <|
        .unadapted
          s!"native formatter inserted {state.commentIndex}/{state.comments.size} interior comments; \
next expected range: {repr nextRange}; recent native leaves: \
{repr state.recentNativeLeaves}"
  -- A count alone says a rule went unapplied and nothing about which one; every one of these was
  -- minimized by hand from a whole mathlib module because of it. Each refusal below names the first
  -- unapplied entry and the source it was collected at.
  if state.appliedIslands.size != state.islands.size then
    let missing := state.islands.filter fun island => !state.appliedIslands.contains island.marker
    throw <|
        .unadapted
          s!"native formatter applied {state.appliedIslands.size}/{state.islands.size} exact islands; \
first unapplied: {repr (missing[0]?.map fun island => (island.range.start, island.range.stop, island.text))}"
  -- Only the required constraints are counted here; see `OffsideConstraint.required`. A chain
  -- compensation that finds no `nest` to cancel is a row that stayed wide, not a walk that lost its
  -- place, and `a.1.2` -- `proj` nested in `proj`, a chain by shape with no break in it -- is the
  -- shape that showed the difference matters on ordinary source.
  let required := state.constraints.zipIdx.filter fun ((constraint, _), _) => constraint.required
  let missing := required.filter fun (_, index) => !state.appliedConstraints.contains index
  if !missing.isEmpty then
    let described :=
      missing.map fun ((constraint, span), _) =>
        (constraint.range.start, constraint.range.stop, span.start, span.stop)
    throw <|
        .unadapted
          s!"native formatter applied {required.size - missing.size}/{required.size} \
offside constraints; first unapplied: {repr described[0]?}"
  if state.appliedBoundaries.size != state.boundaries.size then
    let missing := state.boundaries.filter fun (index, _) => !state.appliedBoundaries.contains index
    let described :=
      missing.map fun (index, _) =>
        (index,
          (state.terminals[index]?.map fun terminal : Terminal =>
            (terminal.range.start, terminal.sourceSpelling)))
    throw <|
        .unadapted
          s!"native formatter applied {state.appliedBoundaries.size}/{state.boundaries.size} \
boundaries; unapplied at {repr described}"
  if state.appliedFlattened.size != state.flattened.size then
    let missing :=
      (state.flattened.zipIdx.filter fun (_, index) => !state.appliedFlattened.contains index).map
        fun (span, _) => (span.start, span.stop)
    throw <|
        .unadapted
          s!"native formatter joined {state.appliedFlattened.size}/{state.flattened.size} guarded \
bail-outs; first unapplied span: {repr missing[0]?}"
  if state.appliedTrailing.size != state.trailing.size then
    throw <|
        .unadapted
          s!"native formatter placed {state.appliedTrailing.size}/{state.trailing.size} block-dangling \
comments; the block's document holds no break to hang one on"
  if appliedAnchors.size != state.anchors.size then
    let missing :=
      (state.anchors.zipIdx.filter fun (_, index) => !appliedAnchors.contains index).map
        fun (span, _) =>
        (span.start, span.stop,
          match state.terminals[span.start]?, state.terminals[span.stop - 1]? with
          | some first, some last =>
            (slice state.source ⟨first.range.start, last.range.stop⟩).toList.take 80 |>
              String.ofList
          | _, _ => "?")
    throw <|
        .unadapted
          s!"native formatter applied {appliedAnchors.size}/{state.anchors.size} structural \
anchors; first unapplied: {repr missing[0]?}"
  return (isolated, state.metrics, state.fillBlocks)

private def rootRange (stx : Lean.Syntax) : SourceRange :=
  sourceRange? stx |>.getD ⟨0, 0⟩

private def interiorComments (ownership : CommentOwnership) (stx : Lean.Syntax)
    (blockDangling : Array SourceRange) : Array InteriorComment :=
  let range := rootRange stx
  let leading := Comments.subtreeAt ownership stx .leading
  let trailing := Comments.subtreeAt ownership stx .trailing
  let dangling := Comments.subtreeAt ownership stx .dangling
  Comments.subtree ownership stx |>.filterMap fun comment =>
    if range.start <= comment.range.start && comment.range.stop <= range.stop then
      if comment.kind == .doc || blockDangling.contains comment.range then none
      else
        let placement :=
          if trailing.contains comment then .trailing
          else
            if dangling.contains comment then .dangling
            else if leading.contains comment then .leading else .leading
        some
          { payload := Comments.payload ownership comment
            range := comment.range
            placement := placement
            kind := comment.kind
            row := comment.row
            column := comment.column
            startsRow := comment.startsRow }
    else none

/- Every comment a block owns from past its own last token, with that block.

A comment dangling at the end of a block has to render at a column inside the block, and the boundary
mechanism cannot put it there. A boundary is a gap between two terminals, and the gap after a block's
last token is the same gap as the one before the next statement — so the comment renders at the *next*
statement's indent, which is the enclosing block's, and a reparse hands it to that statement as leading
trivia. Where the next statement is the next *command* the indent is column zero and the comment leaves
the declaration entirely; this is the same defect one nesting level out.

`finishTrailing` places these instead, by hanging the comment off the owning block's own subtree, where
`Format.text "\n"` re-indents to the indent that block was rendered at whatever the renderer chose —
the one column here nobody has to know in advance.

Nothing is in both sets: `interiorComments` skips exactly the ranges this returns. The two used to be
split by a range test — this took what lay past the command's end — and that test was a proxy for the
real one, which `Comments.blockDangling` already applies: an owner whose own range stops before the
comment starts. -/
private def blockDanglingComments (ownership : CommentOwnership) (stx : Lean.Syntax) :
    Array (SourceRange × InteriorComment) :=
  Comments.blockDangling ownership stx |>.filterMap fun (owner, comment) =>
    if comment.kind == .doc then none
    else
      some
        (owner,
          { payload := Comments.payload ownership comment
            range := comment.range
            placement := .dangling
            kind := comment.kind })

/- A syntax node kind carrying a `_root_` component, with the name that component was meant to be.

`macro (name := _root_.A.B) …` written inside `namespace N` leaves the two ends of one declaration
disagreeing about what `_root_` means, exactly as two ends disagreed about a stack index. The
parser *constant* is elaborated as an ordinary declaration name, which honours `_root_`, and is `A.B`.
The node *kind* is `(← getCurrNamespace) ++ declName.getId` (`Lean/Elab/Syntax.lean:465`), which does
not, and is `N._root_.A.B`. So every node that parser produces carries a kind naming no constant, and
`formatCommand` dies looking one up.

The obvious repair is to rewrite the kind to the suffix and format the corrected tree, and it does not
work -- measured, not assumed. `runForNodeKind` (`Lean/PrettyPrinter/Basic.lean:20-30`) resolves the
formatter by treating the node kind *as* the declaration name, so the rewrite makes the lookup succeed;
but the descr that lookup finds is `ParserDescr.node `Lean._root_.Lean.Parser.Command.registerLabelAttr …`
-- upstream baked the doubled name into the descr too -- and `node.formatter`'s own `checkKind`
(`Lean/PrettyPrinter/Formatter.lean:335-343`) compares it against the node it was handed and
`throwBacktrack`s. The refusal changes from `Unknown constant …` to `uncaught backtrack exception` and
nothing is formatted either way. One name cannot satisfy both ends; supplying the alias upstream should
have declared would mean adding a constant to the environment mid-run, which is a shim rather than a
repair.

So this is refused, and refused with the diagnosis rather than with whichever lookup failed first. The
suffix is reported only when the environment holds it, because that is what makes the message a
statement about the declaration rather than a guess about the name.

Four toolchain declarations spell it this way -- `registerLabelAttr`, `registerSimpAttr`,
`registerGrindAttr` and `registerSymSimpAttr`, all `macro (name := _root_.…)` inside `namespace Lean`.
mathlib declares none itself and uses three, in three of its 8,815 files. -/
private def rootedKind? (env : Lean.Environment) (kind : Lean.Name) : Option Lean.Name := do
  guard !(env.contains kind)
  let parts := kind.components
  let fromEnd ← parts.reverse.findIdx? (· == `_root_)
  let suffix := (parts.drop (parts.length - fromEnd)).foldl Lean.Name.append .anonymous
  guard (env.contains suffix)
  return suffix

private partial def rootedKindNode? (env : Lean.Environment) :
    Lean.Syntax → Option (Lean.Name × Lean.Name)
  | .node _ kind children =>
    match rootedKind? env kind with
    | some suffix => some (kind, suffix)
    | none => children.findSome? (rootedKindNode? env)
  | _ => none

private partial def nativeSize : Std.Format → Nat
  | .nest _ inner | .group inner _ | .tag _ inner => 1 + nativeSize inner
  | .append left right => 1 + nativeSize left + nativeSize right
  | _ => 1

/-- Phase one: read the source and the syntax and assemble the plan. Returns the protected syntax
alongside, which `command` still needs for the formatter registry and the `rootedKind` guard; it
is an input to the formatter run, not a plan fact. -/
private def CommandPlan.collect (source : String) (ownership : CommentOwnership) (stx : Lean.Syntax)
    (stripped : Lean.Syntax) (format : FormatConfig) (baseIndent : Nat) :
    Lean.CoreM (Except TransformFailure (CommandPlan × Lean.Syntax)) := do
  -- One table, computed once: every column question the collectors below ask is a binary search
  -- against it, not a slice of the file's prefix per question.
  let rowStarts := Comments.rowStarts source.toUTF8
  -- The same `format.indent` Lean's own `ppIndent`/`ppDedent` read, so a constraint that cancels one
  -- level of native indentation cancels exactly the amount native layout introduced.
  let formatIndent := Lean.Std.Format.getIndent (← Lean.getOptions)
  let terminals := terminalsFrom source stripped
  let blockDangling := blockDanglingComments ownership stx
  let comments := interiorComments ownership stx (blockDangling.map (·.2.range))
  -- The three evidential caps, collected here rather than at their boundary rows because
  -- `collectOffsideConstraints` has to decline any operand one of them sits inside; see
  -- LAY-CHAIN-COMPENSATION. The arrays are reused at `boundaryStarts` below, so this is one walk
  -- each, not two.
  let braceInteriorBreaks := collectBraceInteriorBreaks source stripped
  let braceLiteralRows := collectBraceLiteralRows source rowStarts stripped
  let letFamilyAlignments := collectLetFamilyAlignments source rowStarts stripped
  let columnPinStarts :=
    braceInteriorBreaks.map (·.1) ++ braceLiteralRows.map (·.1) ++ letFamilyAlignments.map (·.1)
  let constraints := collectOffsideConstraints formatIndent columnPinStarts stripped
  -- One table, one line per rule, and the spelling each rule asks for is right here rather than in the
  -- collector's name. A collector answers "where", `BoundaryLayout` answers "what".
  -- Both halves of the guarded-`let` join come from one collected range: the boundary joins the
  -- bail-out to the bar's line, and `transform` flattens the same span so the join leaves no break
  -- behind to land at the wrong column.
  let joined := collectGuardBailouts source stripped
  let unbreakableRuns := collectUnbreakableRuns source stripped
  let categories := (Lean.Parser.parserExtension.getState (← Lean.getEnv)).categories
  let commandKinds := (categories.find? `command).map (·.kinds) |>.getD { }
  let rootStart := ((selectedLeafRanges stripped)[0]?).map (·.start) |>.getD 0
  let ctorDocStarts := collectCtorDocStarts stripped
  let nestedCommandRanges := collectNestedCommandRanges commandKinds rootStart stripped
  let nestedCommandStarts := nestedCommandRanges.map (·.start)
  let attrDocComments := collectAttrDocComments stripped
  let attrDocStarts := attrDocComments.map (·.1.start)
  -- The one source-read question, shared by the doc rule and the attribute-bracket rule that
  -- must answer it the same way: did the source break the line before this token?
  let brokenBefore (start : Nat) : Bool :=
    (terminals.filter (·.range.stop <= start)).back?.any fun previous =>
      (slice source ⟨previous.range.stop, start⟩).contains '\n'
  -- The one boundary whose spelling is read off the source. Everything else here is decided by shape,
  -- because a shape is what native layout got wrong; this one asks the source because the question it
  -- answers -- which side of a break a comment is on -- is the source's to answer, and the comment
  -- contract compares the answer.
  let docBoundaries : Array (Nat × BoundaryLayout) :=
    (collectDocCommentRanges stripped).filterMap fun range =>
      -- A nested command that opens with its own docstring puts both rules on one terminal, and
      -- `open Foo in` / `/-- … -/` / `def …` is an ordinary mathlib shape. The command's column is the
      -- stronger claim -- it is a parse-relevant one and this is a line-side preference -- so the
      -- dedent owns that boundary and the doc rule steps aside rather than letting the two disagree.
      if
          range.start == rootStart || ctorDocStarts.contains range.stop ||
            nestedCommandStarts.contains range.start then
        none
      else
        let broken := brokenBefore range.start
        -- An attribute-owned doc comment broken in the source cannot take the `.hard` spelling
        -- every other doc takes: the nested column pushes its fixed payload past the width it was
        -- authored to fit, so it dedents to the attribute list's own column instead.
        some
          (range.start,
            if !broken then BoundaryLayout.flat
            else
              if attrDocStarts.contains range.start then BoundaryLayout.dedented
              else BoundaryLayout.hard)
  -- The bracket half of the attribute-doc decision: a doc the source broke pulls the closing `]`
  -- down to the same column, so the pair renders as one shape; a hugged doc keeps the `]` hugged with
  -- an `.elided` spelling -- `-/]`, no space -- because `Term.docComment` ends with `>> ppLine`
  -- (`Lean/Parser/Term.lean:91-92`) and an uncorrected document always breaks between the payload and
  -- the bracket, however short the hugged line. The design comment above once assumed the hugged case
  -- needed no correction; measured on `MathlibStyle.lean`'s `hugged` fixture at line-width 1000, the
  -- bracket always fell to its own line at the nested indent.
  let attrDocBoundaries : Array (Nat × BoundaryLayout) :=
    attrDocComments.filterMap fun (doc, bracket) =>
      some
        (bracket.start,
          if brokenBefore doc.start then BoundaryLayout.dedented else BoundaryLayout.elided)
  -- The magic trailing comma, collected only under `respect`: under `ignore` the trailing comma
  -- is inert layout evidence and no boundaries come of it.
  let (commaRanges, trailingCommaBoundaries) :=
    if format.magicTrailingComma == .respect then collectTrailingCommaExplosions stripped
    else (#[], #[])
  -- The closing brace's own row decision (`collectStructInstCloseBraces`): its ranges join
  -- `explodedRanges` only at the `transform` call, after the pin filter has run.
  let (closeBraceBoundaries, closeBraceRanges) :=
    collectStructInstCloseBraces source rowStarts comments stripped
  let explodedRanges := commaRanges
  -- The `return` braces held on the keyword's row: each gets a `.flat` join below, so the brace
  -- stays on `return`'s row whatever the document's width decisions say.
  let returnBraceStarts :=
    (collectReturnBraceStarts stripped).filter fun start => !brokenBefore start
  -- What each boundary's terminal heads, for the hoist's privacy test (`Transformed.hoist?`).
  let headSpans := collectHeadSpans terminals stripped
  -- Inside an exploded collection the source-column pins are dropped: explosion and the pins
  -- answer the same question (one element per row), the pin's column is stale once the collection
  -- explodes, and `boundaryTable` refuses a `.hard`/`.columned` disagreement at one terminal.
  let outsideExploded (start : Nat) : Bool :=
    !explodedRanges.any fun range => range.start < start && start < range.stop
  -- LAY-POSTHOC-RETIREMENT census: every surviving `BoundaryLayout` producer, its class, and the
  -- record that keeps it live. Liveness is not argued here but enforced: the applied-boundary
  -- ledger (`transform`'s "applied X/Y boundaries" refusal) makes a pin that never lands a loud
  -- failure, so a silently dead producer cannot exist, and retirement is settled by corpus parity
  -- instead. What anchors retired is already gone (`BoundaryLayout.fieldRow`,
  -- `collectStructInstFieldRows`, `collectRowSpreadStructInsts`, the `whereForm` carve-out --
  -- LAY-STRUCT-INST and LAY-INDENTED-SEQUENCES). What remains:
  --
  --   producer                                   layout             class / record
  --   collectUngroupedBodyStarts/ReturnTermStarts .flat             compatibility join
  --   collectWhereStarts                          .flat/.hard        the same phantom measurement
  --     at `whereStructInst`'s `ppSpace`, answered by `declaration-where` instead
  --   collectIndentedSequenceStarts               .hard              compatibility break
  --     (break decisions, kept at LAY-INDENTED-SEQUENCES: the phantom-`column - indent` fit
  --     measurement the anchor does not answer)
  --   collectCdotStarts                           .flat              join, mathlib's cdot linter
  --   nestedCommandStarts                         .dedented          structure-aware, Offside.lean
  --   ctorDocStarts/docBoundaries/attrDocBoundaries .elided/.flat/.dedented/.hard
  --                                                              comment handling, MathlibStyle.lean
  --   collectGuardBailouts (`joined`)             .flat              join, flattenedHard guard
  --   collectGuardBarBreaks                       .hard              compatibility break
  --   collectBraceAppArgStarts/ReturnBraceStarts  .flat              compatibility join
  --   collectBraceInteriorBreaks                  .columned          evidential cap, `«term{_}»` rows
  --   collectBraceLiteralRows                     .anchored          evidential cap, the
  --     `«term{_}»`/abbrev-`structInst` ambiguity cap (Smooth.lean 3755 -> 3756); the pin holds
  --     source columns inside anchor intervals too, where the anchor's uniform re-base would
  --     otherwise move a nested literal's continuation row
  --   collectLetFamilyAlignments                  .columned/.anchored evidential cap, the
  --     letI-family both-directions pairing (`BoundaryLayout.join?`)
  --   unbreakableRunBoundaries                    .flat              compatibility join
  --   collectStructInstEllipses                   .hard              compatibility break
  --   collectTrailingCommaExplosions              .hard/.explodedClose break + structure marker,
  --     Boundaries.lean and the CollectionFormatter suite
  --   collectStructInstCloseBraces                .hard/.explodedClose closing-brace row decision
  let boundaryStarts : Array (Nat × BoundaryLayout) :=
    (collectUngroupedBodyStarts format.declarationBody source format.lineWidth stripped
                (collectReturnTermStarts stripped)).map
            (·, BoundaryLayout.flat) ++
          (match format.declarationWhere with
          | .sameLine =>
            (collectWhereStarts source format.lineWidth stripped).flatMap
              fun (whereStart, fieldStart?, fits) =>
              -- A header that cannot carry `" where"` takes the
              -- `next-line` answer at the `where`. Declining forces
              -- nothing: the native document then shatters the
              -- signature at its own `:`, and `where` gets the row
              -- it needs. Whether the *field* opens its own row is a
              -- different question, so it is answered the same way
              -- either way -- otherwise a lone field rides up onto
              -- the `where` row exactly when the signature is long.
              match fieldStart?, fits with
              | none, true => #[]
              | none, false => #[(whereStart, BoundaryLayout.hard)]
              | some fieldStart, _ =>
                #[(whereStart, if fits then BoundaryLayout.flat else BoundaryLayout.hard),
                  (fieldStart, BoundaryLayout.hard)]
          | .nextLine =>
            (collectWhereStarts source format.lineWidth stripped).map (·.1, BoundaryLayout.hard)) ++
          (collectIndentedSequenceStarts source stripped).map (·, BoundaryLayout.hard) ++
          (collectCdotStarts stripped).map (·, BoundaryLayout.flat) ++
          nestedCommandStarts.map (·, BoundaryLayout.dedented) ++
          ctorDocStarts.map (·, BoundaryLayout.elided) ++
          docBoundaries ++
          attrDocBoundaries ++
          joined.map (·.start, BoundaryLayout.flat) ++
          (collectGuardBarBreaks source stripped).map (·, BoundaryLayout.hard) ++
          ((collectBraceAppArgStarts stripped).filterMap fun start =>
            if brokenBefore start then none else some (start, BoundaryLayout.flat)) ++
          returnBraceStarts.map (·, BoundaryLayout.flat) ++
          (braceInteriorBreaks.filter fun p => outsideExploded p.1).map
            (fun p => (p.1, BoundaryLayout.columned p.2)) ++
          (braceLiteralRows.filter fun p => outsideExploded p.1) ++
          letFamilyAlignments ++
          unbreakableRunBoundaries source terminals unbreakableRuns ++
          ((collectStructInstEllipses stripped).filterMap fun start =>
              let broken :=
              (terminals.filter (·.range.stop <= start)).back?.any fun previous =>
                (slice source ⟨previous.range.stop, start⟩).contains '\n'
              if broken then some (start, BoundaryLayout.hard) else none) ++
        trailingCommaBoundaries ++
      closeBraceBoundaries
  -- One anchor interval per multi-field `structInstFields` list, collected with the old row
  -- machinery still active: what the anchors make redundant is what the deletion checklist names.
  let structInstAnchors :=
    collectStructInstFieldAnchors stripped ++ collectTacticSequenceAnchors stripped
  let commentFree := withoutTrivia stripped
  let (formattedSyntax, islands) := protectSourceData categories source commentFree
  -- The closing brace's own row decision (`collectStructInstCloseBraces`): its ranges join
  -- `explodedRanges` only here, after the pin filter has run.
  match
    CommandPlan.resolve source terminals comments blockDangling islands constraints boundaryStarts
      joined nestedCommandRanges (explodedRanges ++ closeBraceRanges) headSpans baseIndent
      structInstAnchors with
  | .error failure =>
    return .error failure
  | .ok plan =>
    return .ok (plan, formattedSyntax)

/-- Format one actual command through Lean's live registry, preserving source payloads and applying
only the structurally measured boundary and offside corrections collected below. `baseIndent` is the
column the resulting registered leaf is rendered at; an exact island's dedent must cancel it. -/
def command (source : String) (ownership : CommentOwnership) (stx : Lean.Syntax)
    (format : FormatConfig) (baseIndent : Nat := 0) :
    Lean.CoreM (Except FormatterFailure Document) := do
  let trace ← Formatter.trace ownership .command stx
  let stripped := Formatter.withoutBoundaryTrivia stx
  -- The walks below each pick one alternative of a `choice` node and assume the rest spell the
  -- same bytes. `Syntax.reprint` verifies that instead of assuming it, and this is where lean-fmt
  -- does the same: one check on `stripped`, which is the tree all of them walk, makes the
  -- assumption true for all four.
  if let some (range, alternative, expected, actual) := choiceDisagreement? source stripped then
    return .error
        { category := .command
          kind := stx.getKind
          range
          trace
          detail :=
            s!"choice node at {range.start}:{range.stop} spells different source in its \
alternatives: alternative 0 is {expected}, alternative {alternative} is {actual}" }
  let collected ← CommandPlan.collect source ownership stx stripped format baseIndent
  let (plan, formattedSyntax) ←
    match collected with
    | .ok pair =>
      pure pair
    | .error (.incomplete detail) | .error (.unadapted detail) =>
      return .error
          { category := .command
            kind := stx.getKind
            range := rootRange stx
            trace
            detail }
  -- Named before `formatCommand` reaches it. Both lookups this breaks fail with a message about
  -- a name nobody wrote, and the one that fires depends on which end is asked first.
  if let some (kind, suffix) := rootedKindNode? (← Lean.getEnv) formattedSyntax then
    return .error
        { category := .command
          kind := stx.getKind
          range := rootRange stx
          trace
          detail :=
            s!"syntax node kind {kind} names no constant: it is a namespace prefixed onto a \
declaration name that spelled `_root_`, which the parser constant {suffix} honoured and \
Lean/Elab/Syntax.lean:465 did not. No formatter can be resolved for it. Write \
{repr Formatter.Trivia.formatIgnoreNextText} above the command to leave it verbatim" }
  -- A marker is matched by its spelling when the formatter hands the leaf back, so a source that
  -- already spells one would be indistinguishable from the placeholder standing in for protected
  -- syntax. The shape is unlikely, not impossible, and "unlikely" is not a guarantee: refuse instead.
  if let some marker :=
      plan.islands.find? fun island =>
        plan.terminals.any fun terminal => terminal.sourceSpelling == island.marker then
    return .error
        { category := .command
          kind := stx.getKind
          range := rootRange stx
          trace
          detail :=
            s!"source spells the exact-island marker {repr marker.marker}, which the formatter \
cannot tell from the placeholder that protects {marker.range.start}:{marker.range.stop}" }
  -- One command's own bytes, complete and validated downstream, in place of a layout the toolchain
  -- could not produce. The file still formats; `verbatimCommands` counts what it cost.
  let degrade (detail : String) : Except FormatterFailure Document :=
    match sourceRange? stx with
    | some range =>
      .ok {
          document := Doc.verbatim (slice source range)
          trace
          metrics :=
            { exactIslands := 1, exactIslandBytes := range.stop - range.start,
              verbatimCommands := 1 } }
    | none =>
      .error
        { category := .command
          kind := stx.getKind
          range := rootRange stx
          trace
          detail := s!"{detail} (no source range for the verbatim fallback)" }
  let refuse (detail : String) : Except FormatterFailure Document :=
    .error { category := .command, kind := stx.getKind, range := rootRange stx, trace, detail }
  try
    let native ← Lean.PrettyPrinter.formatCommand formattedSyntax
    let native := (dropTrailingHardLine native).getD native
    match transform plan native with
    | .ok (native, metrics, blocks) =>
      let document := lowerNative blocks native
      if document.wellFormed then
        return .ok { document, trace, metrics }
      else
        return refuse
            "the lowered document is not well formed: a lowerer defect produced a constructor \
`Doc.text` with a newline or a `Doc.line` with a multiline flat spelling"
    | .error (.incomplete detail) =>
      return degrade detail
    | .error (.unadapted detail) =>
      return refuse detail
  catch exception =>
    let detail ← exception.toMessageData.toString
    -- The toolchain has two ways of saying it has no formatter for a shape as written, and neither
    -- is a defect this adapter can repair.
    --
    -- A `throwBacktrack` no alternative catches is rethrown as `format: uncaught backtrack
    -- exception` (`Lean/PrettyPrinter/Formatter.lean:655`); a doubly-declared infix whose whole type
    -- is a binder's type is the sighted case. A dispatch that reaches `formatterForKind` with a kind
    -- naming no declaration dies as `Unknown constant …`; the module docstring above lists three
    -- shapes that reach it, and `Proofs/AlgebraicGeometry/Divisor/EffectiveCartier.lean` refused a
    -- whole file over one `group` node, which `Lean.Parser.group` builds wherever a parser of arity
    -- other than one is repeated.
    --
    -- Both degrade the command to its source bytes: they reparse and re-elaborate to exactly what
    -- the file already held, the structure and diagnostics gates still hold, and the rest of the
    -- file formats. Any other exception keeps refusing -- an exception this module did not
    -- anticipate is not evidence about the grammar.
    let formatterGap :=
      (detail.splitOn "uncaught backtrack exception").length > 1 ||
        (detail.splitOn "Unknown constant").length > 1
    if formatterGap then
      return degrade detail
    else
      return refuse detail

end Formatter.NativeLayout

end LeanFmt.Internal
