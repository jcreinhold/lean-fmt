module

/- Turn one projected module back into text.

This is the first consumer of `LeanFmt.Doc`. `RLC-FINAL` closed the layout stack with the standing
caveat that nothing consumed it, so every claim about realistic documents rested on fixtures written
against the engine; this module is where that changes.

**Where the tree comes from, and why.** `notes/01-command-printing.md` designs this interface twice and
decides the printer reads the `LosslessSource` projection rather than `Lean.Syntax` inside the
frontend. That is not a preference: `ruff-01`'s roadmap already committed to carrying structure
"without exposing Lean frontend objects to product callers", the artifact is already the cache key, and
printing in-frontend would buy free arg order for a median 1.96 s frontend run per file (`RLS-FINAL`).

**What the projection does not carry, measured rather than assumed.** Over all 21 modules of this
repository (41,340 nodes, `evidence/01-projection-shape.txt`), 14,827 nodes (35.9%) carry no token at
all — they are *absent* syntax, the unfilled optional slots of `declModifiers`, `optDeclSig`,
`Termination.suffix` — and `collect` gives them range `(0,0)` because a node's range is the hull of the
leaves beneath it and there are none. For 6,389 of them (15.5% of all nodes) the parent also has direct
token children, so nothing in the projection says where among its siblings the absent slot belongs.
`Lean.Syntax` has no position for them either; this is not something the projection dropped.

Two consequences run through everything below:

1. **Node order is index order, never range order.** `collect` pushes a node's placeholder at
   `build.nodes.size` before folding its args left to right, so a parent precedes its children and
   siblings ascend in arg order. Sorting children by range would be correct for the 64.0% that carry
   tokens and silently wrong for the rest.
2. **The conservative path reads bytes, not the tree.** Empty nodes contribute no bytes, so re-emitting
   a command's byte extent is unaffected by all 6,389 ambiguous placements. It is the only path whose
   correctness rests on no claim about any grammar, which is exactly what the roadmap's "unknown
   commands must round-trip conservatively" asks for. Every kind starts here and leaves only when a
   canonical layout for it is cited and pinned by a golden test.

The module is deliberately named `Printer`. `Format` would collide with `Std.Format` and `Lean.Format`,
which this project already had to reason about carefully in `RLC-SPEC`. -/

import all LeanFmt.LosslessSource
import all LeanFmt.Doc
-- The header is the one region the projection cannot describe (`LosslessSource.lean:358`), so laying
-- it out means parsing it here. `Lean.Parser.parseHeader` needs no imported environment — see
-- `headerSyntax?` — and this module is deliberately outside `LeanFmtCompilerPlugin`'s import cone.
import Lean.Parser.Module

namespace LeanFmt.Internal

/-! ## A navigable view -/

/-- `LosslessSource` stores one `parent` pointer per node and no children array, because it is a
transport format. This is the view a walk needs, computed once.

Both child arrays ascend in index order, which **is** arg order by `collect`'s construction. The
projection retains no other order, so this is not a property that can be checked against its output —
`evidence/01-projection-shape.txt` checks the observable consequence instead: among a parent's
token-bearing children, index order agrees with byte order (0 violations over 41,340 nodes). -/
structure Tree where
  source : LosslessSource
  /-- `nodeChildren[i]` are the node-children of node `i`, in arg order. -/
  nodeChildren : Array (Array Nat)
  /-- `tokenChildren[i]` indexes `source.tokens` for the tokens whose immediate parent is `i`, in
  source order. -/
  tokenChildren : Array (Array Nat)
  /-- The commands, in source order. A command is a node with no parent. -/
  roots : Array Nat
  /-- `rootOf[i]` is the command node `i` belongs to. -/
  rootOf : Array Nat
  /-- Node `i`'s subtree is exactly the index range `[i, subtreeEnd[i])`.

  This is not the measured contiguity property being smuggled in as an assumption: it is computed as
  the max of the children's ends, which is the subtree's extent whether or not the indices happen to
  be contiguous. `evidence/01-projection-shape.txt` reports 0 contiguity violations over 41,340 nodes,
  so the range is also gap-free in practice — but nothing below depends on that. -/
  subtreeEnd : Array Nat

/-- Build the view in a few linear passes.

`rootOf` is a single forward pass because a parent's index is always below its children's: `collect`
pushes the placeholder before recursing. That is the same fact `nodeChildren`'s ordering rests on, and
the same fact that lets `subtreeEnd` be folded in one backward pass: every child of `i` is above `i`,
so it is already final by the time `i` is reached. -/
def Tree.ofSource (source : LosslessSource) : Tree := Id.run do
  let count := source.nodes.size
  let mut nodeChildren : Array (Array Nat) := Array.replicate count #[]
  let mut rootOf : Array Nat := Array.replicate count 0
  let mut roots : Array Nat := #[]
  for index in [0:count] do
    match source.nodes[index]!.parent with
    | some parent =>
      nodeChildren := nodeChildren.modify parent (·.push index)
      rootOf := rootOf.set! index rootOf[parent]!
    | none =>
      rootOf := rootOf.set! index index
      roots := roots.push index
  let mut tokenChildren : Array (Array Nat) := Array.replicate count #[]
  for index in [0:source.tokens.size] do
    let node := source.tokens[index]!.node
    if node < count then
      tokenChildren := tokenChildren.modify node (·.push index)
  let mut subtreeEnd : Array Nat := Array.ofFn (n := count) (·.val + 1)
  for offset in [0:count] do
    let index := count - 1 - offset
    for child in nodeChildren[index]! do
      if subtreeEnd[child]! > subtreeEnd[index]! then
        subtreeEnd := subtreeEnd.set! index subtreeEnd[child]!
  return { source, nodeChildren, tokenChildren, roots, rootOf, subtreeEnd }

/-- The kind name of a node. -/
def Tree.kindOf (tree : Tree) (node : Nat) : String :=
  match tree.source.nodes[node]? with
  | some value => tree.source.kinds[value.kind]?.getD ""
  | none => ""

/-- Where a token's trailing run ends. `Trivia` stores only its stop because runs tile their span in
order, so the run's end is its last element's stop. -/
def tokenEnd (token : Token) : Nat :=
  match token.trailing.back? with
  | some trivia => trivia.stop
  | none => token.stop

/-! ## Command extents -/

/-- One command: which node it is, which bytes it owns, and which tokens it spans.

`first`/`last` index `source.tokens` and are inclusive. They exist because a canonical layout needs the
tokens, while the conservative path needs only the extent. -/
structure CommandSpan where
  root : Nat
  extent : SourceRange
  first : Nat
  last : Nat

/-- The byte extent of each command, in source order.

The extents tile `[headerStop, terminalStop)` exactly once and touch, so concatenating their slices
reproduces the command stream. That is not a coincidence to be checked at the end: `structurallyValid`
already requires the trivia runs to tile that interval exactly once, and a command's extent runs from
where the previous one ended to the end of its own last token's trailing run. Trivia between two
commands therefore belongs to the earlier one, which is the same greedy-trailing shape `RLC-SPEC`
measured on the parser and `Comments` splits.

`missing` leaves are skipped. They carry `start = stop = 0` (`collect` synthesizes them for
`Syntax.missing`) and would drag an extent back to the file start. An accepted module has none — the
producer would not have accepted it — so this guards a case the type permits and the corpus does not
contain, rather than one seen in the wild. -/
def Tree.commands (tree : Tree) : Array CommandSpan := Id.run do
  let source := tree.source
  let mut spans : Array CommandSpan := #[]
  let mut cursor := source.headerStop
  let mut current : Option Nat := none
  let mut stop := source.headerStop
  let mut first := 0
  let mut last := 0
  for index in [0:source.tokens.size] do
    let token := source.tokens[index]!
    if token.info == .missing then
      continue
    let root := tree.rootOf[token.node]?.getD 0
    match current with
    | none =>
      current := some root
      stop := tokenEnd token
      first := index
      last := index
    | some previous =>
      if previous == root then
        stop := tokenEnd token
        last := index
      else
        spans := spans.push { root := previous, extent := { start := cursor, stop }, first, last }
        cursor := stop
        current := some root
        stop := tokenEnd token
        first := index
        last := index
  if let some previous := current then
    spans := spans.push { root := previous, extent := { start := cursor, stop }, first, last }
  return spans

/-- The byte extent of each command. The tiling property above is about these. -/
def Tree.commandExtents (tree : Tree) : Array SourceRange :=
  tree.commands.map (·.extent)

/-! ## Printing -/

/- Bytes `[start, stop)` of the normalized source. Named for what it indexes: every offset in a
projection is a byte offset into `raw.crlfToLf`, never into the file on disk. -/
private def sliceNormalized (source : String) (start stop : Nat) : String :=
  if stop <= start then "" else
    match String.fromUTF8? (source.toUTF8.extract start stop) with
    | some value => value
    -- Unreachable on accepted source: every offset here is a parser position, so it lies on a
    -- codepoint boundary. Returning the whole remainder rather than `""` keeps a hypothetical failure
    -- loud — output that is wrong is far easier to notice than output that is quietly short.
    | none => source

/-- The source text of one token. -/
def Tree.tokenText (tree : Tree) (normalized : String) (index : Nat) : String :=
  match tree.source.tokens[index]? with
  | some token => sliceNormalized normalized token.start token.stop
  | none => ""

/-- May this command's tokens be re-spaced without losing anything?

A canonical layout emits the tokens and chooses the space between them, so anything *between* two
tokens that is not whitespace would be dropped on the floor. This asks the projection directly rather
than trusting the layout to be careful.

Only the runs strictly inside the command are examined. The last token's trailing run is *not* — it
holds the newline, the blank lines, and the next command's leading comments, so requiring it to be
comment-free would disqualify nearly every command in any commented file. `Tree.command` emits that
run verbatim instead, which is why it can be ignored here rather than handled.

This is the *trivia* half of the question. The other half — whether the tokens themselves are
newline-free — is `singleLineTokens`, and the two are asked over different ranges by a layout that
emits some of its tokens as `verbatim`: bytes that keep their newlines are fine, bytes that would be
re-spaced are not. -/
private def Tree.triviaClean (tree : Tree) (first last : Nat) : Bool := Id.run do
  for index in [first:last + 1] do
    let some token := tree.source.tokens[index]? | return false
    if token.leading.any (·.kind != .whitespace) then
      return false
    if index != last && token.trailing.any (·.kind != .whitespace) then
      return false
  return true

/-- Is every token in the range one line long?

Required of any token a layout emits through `Doc.text`: `text` is specified to hold exactly one line
(`Doc.lean:47-51`), the renderer measures columns by adding its width, and `RLC-IMPL` added `verbatim`
precisely because re-indenting a multi-line token is the `Std.Format` bug this project exists to avoid.
A layout emitting a token as `verbatim` instead does not need to ask. -/
private def Tree.singleLineTokens (tree : Tree) (normalized : String) (first last : Nat) : Bool :=
  Id.run do
    for index in [first:last + 1] do
      if (tree.tokenText normalized index).contains '\n' then
        return false
    return true

/-- Both halves, over a whole command. -/
private def Tree.respaceable (tree : Tree) (normalized : String) (span : CommandSpan) : Bool :=
  tree.triviaClean span.first span.last && tree.singleLineTokens normalized span.first span.last

/-- Does this command open an attribute bracket?

`spaceSeparated` puts one space between every pair of tokens, which is right for a flat run of
keywords and identifiers and wrong the moment a bracket appears: `@[` and `]` are tokens of their own,
so a run holding them emits `@[ expose ]` rather than `@[expose]`. A kind whose grammar is a flat run
*except* for an optional bracketed slot can therefore still take the flat layout on every command that
does not fill that slot, and must keep its bytes on the ones that do.

Asking it of the token text rather than of the tree is deliberate. The alternative is to find the slot
structurally and check whether it is empty, which needs the slot's index in its parent — a second
claim about the same grammar, and one that goes stale differently. `@[` is a single atom in the
parser's token table, an identifier can never spell it, and no layout here emits one, so its presence
is exactly the question being asked. -/
private def Tree.opensAttributeBracket (tree : Tree) (normalized : String) (span : CommandSpan) :
    Bool := Id.run do
  for index in [span.first:span.last + 1] do
    if tree.tokenText normalized index == "@[" then return true
  return false

/-- Do the bytes at `start` begin their line?

`Doc.hard` emits a newline plus *the current indentation*, and this printer never nests, so the only
indentation it can produce is column 0. A layout that breaks a line inside a construct that does not
start at column 0 would therefore silently de-indent it. Whether a top-level command belongs at column
0 is a language decision, and no prompt in this stack has made it — so the layouts that break lines ask
this first and keep their bytes when the answer is no.

`start - 1` is a byte step, and a multi-byte character before `start` makes the slice fail rather than
spell `"\n"`. That answers `false`, which is the safe direction: such a position is not a line start. -/
private def startsLine (normalized : String) (start : Nat) : Bool :=
  start == 0 || sliceNormalized normalized (start - 1) start == "\n"

/-- Is every byte in `[start, stop)` whitespace?

The trivia question a layout has to ask, phrased over bytes rather than over the projection's
classified runs, because the header's trivia never reaches the projection. It needs no classifier:
trivia is whitespace and comments, and no comment is whitespace-only. -/
private def whitespaceOnly (normalized : String) (start stop : Nat) : Bool :=
  (sliceNormalized normalized start stop).all Char.isWhitespace

/-- The column of the byte at `start`, counted in **codepoints** from its line's first byte.

Codepoints rather than bytes or terminal cells, because that is what the parser's column checks count
(`RLC-SPEC` §4.7) and this is used only to compare against them. It is deliberately not a width: the
wonky fixture's `日本語` occupies six terminal cells and three columns, and a layout that confused the
two would re-measure text this printer is not allowed to re-measure.

Counted by folding the prefix and resetting at each newline, which needs no special case for a `start`
on the first line: nothing resets it and the count is the prefix itself. `foldl` over a `String` steps
codepoints, so the unit is right by construction rather than by an adjustment. -/
private def columnOf (normalized : String) (start : Nat) : Nat :=
  (sliceNormalized normalized 0 start).foldl (fun col c => if c == '\n' then 0 else col + 1) 0

/-- Is the byte at `start` the first non-whitespace on its line?

Distinct from `startsLine`, and the difference is the indentation: `startsLine` asks whether a token is
at column 0, which is what a printer that never nests needs to know before it emits a line break.
This asks whether a token *begins* its line, indented or not — the question a counter has to ask to
tell `theorem foo := by\n  simp` from `theorem foo := by simp`, whose tactic blocks are both ownable
and sit at very different columns for entirely different reasons. -/
private def firstOnLine (normalized : String) (start : Nat) : Bool :=
  (sliceNormalized normalized 0 start).foldl
    (fun clean c => if c == '\n' then true else clean && c.isWhitespace) true

/-- Does this token begin its line? See `startsLine`. -/
private def Tree.atLineStart (tree : Tree) (normalized : String) (index : Nat) : Bool :=
  match tree.source.tokens[index]? with
  | none => false
  | some token => startsLine normalized token.start

/-- The bytes from token `lo`'s start through token `hi`'s stop, trivia between them included. -/
private def Tree.tokenSpanText (tree : Tree) (normalized : String) (lo hi : Nat) : String :=
  match tree.source.tokens[lo]?, tree.source.tokens[hi]? with
  | some a, some b => sliceNormalized normalized a.start b.stop
  | _, _ => ""

/-- Tokens joined by exactly one space.

This is the whole canonical layout for the keyword-then-identifier commands, and it is where the
formatter first *decides* something: `namespace    Foo` becomes `namespace Foo` no matter what the
source did. It is only correct for kinds whose grammar is a flat run of tokens that always want one
space between them, which is why it is not the default. -/
private def Tree.spaceSeparated (tree : Tree) (normalized : String) (first last : Nat) : Doc :=
  Id.run do
    let mut doc : Doc := .empty
    for index in [first:last + 1] do
      let text := tree.tokenText normalized index
      doc := if index == first then .text text else doc ++ .text " " ++ .text text
    return doc

/-- Space-separate every token of the command, if nothing would be lost. The layout for the kinds
whose whole grammar is a flat run of tokens. -/
private def Tree.wholeSpan? (tree : Tree) (normalized : String) (span : CommandSpan) :
    Option (Nat × Doc) :=
  if tree.respaceable normalized span then
    some (span.last, tree.spaceSeparated normalized span.first span.last)
  else none

/-- The first and last token index under `node`'s subtree, or `none` when it carries no token.

`none` is the *absent syntax* case and is the common one: 35.9% of nodes are empty
(`evidence/01-projection-shape.txt`), because an unfilled optional slot is still a node. Asking this
question is how a layout distinguishes "the slot is empty" from "the slot is filled", which is
information the projection carries exactly and positions do not carry at all. -/
private def Tree.subtreeTokens (tree : Tree) (node : Nat) : Option (Nat × Nat) := Id.run do
  let some stop := tree.subtreeEnd[node]? | return none
  let mut bounds : Option (Nat × Nat) := none
  for index in [node:stop] do
    for token in tree.tokenChildren[index]! do
      bounds := match bounds with
        | none => some (token, token)
        | some (lo, hi) => some (min lo token, max hi token)
  return bounds

/-- The `declId` naming this shape: a child of it, or a child of one of its `optional` wrappers.

Bounded to those two depths on purpose. Every shape `declarationShell?` recognizes puts the name
there, and searching the whole subtree instead would let a `declId` appearing inside a value extend
the shell over it — the shell must be a *prefix* of the command's tokens, and nothing enforces that
but where this looks. -/
private def Tree.shapeDeclId? (tree : Tree) (shape : Nat) : Option Nat := Id.run do
  for child in tree.nodeChildren[shape]! do
    if tree.kindOf child == "Lean.Parser.Command.declId" then
      return some child
    if tree.kindOf child == "null" then
      for grandchild in tree.nodeChildren[child]! do
        if tree.kindOf grandchild == "Lean.Parser.Command.declId" then
          return some grandchild
  return none

/-- A `declaration`'s shell, as token indices: what to emit and where the claim stops. -/
private structure DeclShell where
  /-- Token bounds of the `docComment` slot, or `none` when it is empty. Emitted verbatim. -/
  doc : Option (Nat × Nat)
  /-- Token bounds of the `attributes` slot, or `none` when it is empty. Emitted verbatim. -/
  attrs : Option (Nat × Nat)
  /-- First token of the flat run: the keyword modifiers, the declaration keyword, the name. -/
  restFirst : Nat
  /-- Last token the shell claims: the `declId`'s. Everything after it is bytes. -/
  last : Nat

/-- A `declaration`'s shell, or `none` when this is not a shape the printer has read the grammar for.

`Lean/Parser/Command.lean:282-285` (v4.32.0):

    def declaration := leading_parser
      declModifiers false >> («abbrev» <|> definition <|> «theorem» <|> «opaque» <|> ...)

so a `declaration` is exactly two node-children, and the second one names the shape. Four of the
eleven alternatives open the same way — a keyword atom, then `declId`, then a signature, then the
value (`:187-188`, `:194-195`, `:196-197`, `:198-199`) — and those four are what this recognizes:

    def «abbrev»    := leading_parser "abbrev " >> declId >> ppIndent optDeclSig >> declVal
    def definition  := leading_parser "def " >> recover declId .. >> ppIndent optDeclSig >> declVal >> optDefDeriving
    def «theorem»   := leading_parser "theorem " >> recover declId .. >> ppIndent declSig >> declVal
    def «opaque»    := leading_parser "opaque " >> declId >> ppIndent declSig >> declVal

**The modifiers.** `declModifiers` (`:114-121`) is seven optional slots, in a fixed order:

    def declModifiers (inline : Bool) := leading_parser
      optional docComment >>
      optional (Term.«attributes» >> if inline then skip else ppDedent ppLine) >>
      optional visibility >> optional «protected» >> optional («meta» <|> «noncomputable») >>
      optional «unsafe» >> optional («partial» <|> «nonrec»)

Each `optional` is a `null` node whether or not it was filled, so the slots are addressable by index
and an unfilled one is empty rather than absent. That is measured, not assumed — a `declModifiers`
node with all seven slots empty still has seven children.

The first two slots are not flat runs of one-space-apart tokens and are read by index:

* **Slot 0, `docComment`.** `Lean/Parser/Term.lean:91-93` — which is inside `namespace Lean.Parser.Command`,
  hence the kind — opens with the doc-comment atom, then `ppSpace`, then `commentBody`, then `ppLine`.
  It ends in `ppLine`, so the declaration goes on the next line. Emitted `verbatim`: it is two tokens,
  the opener and the body, and the body's interior is prose that is not this formatter's to re-space
  or re-indent. (The grammar is paraphrased rather than quoted because quoting it here would open a
  nested comment inside this one.)
* **Slot 1, `attributes`.** Followed by `if inline then skip else ppDedent ppLine`, and `declaration`
  passes `inline := false` (`:282`), so this line break is the grammar's own. Emitted `verbatim`
  because it is bracketed — `@[` `inline` `]` one space apart is `@[ inline ]`.

Slots 2–6 are each a single keyword atom (`«private»` is `leading_parser "private "`, `:68`, and its
siblings are the same shape), so they join the flat run with the declaration keyword and the name.

**The shapes.** Six of the eleven alternatives open with a keyword and the declaration's name, and the
shell is exactly that prefix:

    def «abbrev»    := leading_parser "abbrev " >> declId >> ppIndent optDeclSig >> declVal
    def definition  := leading_parser "def " >> recover declId .. >> ppIndent optDeclSig >> declVal >> optDefDeriving
    def «theorem»   := leading_parser "theorem " >> recover declId .. >> ppIndent declSig >> declVal
    def «opaque»    := leading_parser "opaque " >> recover declId .. >> ppIndent declSig >> optional declValSimple
    def «inductive» := leading_parser "inductive " >> recover declId .. >> ppIndent optDeclSig >> ..
    def «structure» := leading_parser (structureTk <|> classTk) >> declId >> ppIndent (optDeclSig >> ..) >> ..

(`:187-188`, `:194-195`, `:196-197`, `:198-199`, `:238-240`, `:274-281`. `«structure»` covers `class`
too: `classTk` is one of its two openers, so `class Foo where` is a `structure` node.)

`declId` is *found* rather than indexed, because it does not sit at a fixed position: `definition` has
it first, `«structure»` has `structureTk` ahead of it. It is looked for among the shape's children and
one level inside their `optional` wrappers — which is where every grammar above puts it — and never
deeper, so a `declId` occurring inside a value could not drag the shell past the name.

**`instance` is excluded, and its grammar says why** (`:202-204`):

    def «instance» := leading_parser
      Term.attrKind >> "instance" >> optNamedPrio >> optional (ppSpace >> declId) >> ppIndent declSig >> declVal

Its `declId` is optional — anonymous instances are ordinary Lean — so the shell would have to end at
the keyword instead, and `optNamedPrio` (`:64-65`) is bracketed, so one space between its tokens gives
`( priority := 5 )`. Neither is hard; both are separate claims needing separate fixtures, and
`evidence/01-projection-shape.txt` counts 11 of them.

The signature and the value are deliberately *not* reached, and neither are a `structure`'s fields or
an `inductive`'s constructors. Everything from the `declId`'s last token onward stays verbatim. -/
private def Tree.declarationShell? (tree : Tree) (root : Nat) : Option DeclShell := do
  let children := tree.nodeChildren[root]!
  guard (children.size == 2)
  let modifiers := children[0]!
  let shape := children[1]!
  guard (tree.kindOf modifiers == "Lean.Parser.Command.declModifiers")
  let slots := tree.nodeChildren[modifiers]!
  -- Seven, because seven is what the grammar above has. If a future Lean adds an eighth, this stops
  -- recognizing declarations rather than laying out a shape it has not read.
  guard (slots.size == 7)
  guard <| [
      "Lean.Parser.Command.abbrev", "Lean.Parser.Command.definition",
      "Lean.Parser.Command.theorem", "Lean.Parser.Command.opaque",
      "Lean.Parser.Command.inductive", "Lean.Parser.Command.structure"
    ].contains (tree.kindOf shape)
  let declId ← tree.shapeDeclId? shape
  let (first, _) ← tree.subtreeTokens root
  let (_, last) ← tree.subtreeTokens declId
  let doc := tree.subtreeTokens slots[0]!
  let attrs := tree.subtreeTokens slots[1]!
  -- The flat run starts after whichever of the two verbatim slots was filled last. Tokens are indexed
  -- in source order and both slots precede the rest of the command, so this needs no search.
  let restFirst := match attrs, doc with
    | some (_, hi), _ => hi + 1
    | none, some (_, hi) => hi + 1
    | none, none => first
  guard (restFirst <= last)
  return { doc, attrs, restFirst, last }

/-- The canonical layout for this command's kind, if it has one.

Every kind here is cited against the parser it mirrors and pinned by a golden test. A kind absent from
this dispatch is not a bug and not a TODO — it is the conservative path, which is the roadmap's
"unknown commands must round-trip conservatively" and the only path resting on no grammar claim.

**A layout claims a prefix of the command's tokens, not necessarily all of them**, which is what the
returned index says: the last token the `Doc` accounts for. Everything past it is bytes. A whole-kind
layout returns `span.last` and reduces to the obvious thing; a *shell* layout — a `declaration`, whose
signature and value are terms this stack does not own — returns the token where its claim stops. This
is the shape `notes/01-command-printing.md` §7 committed to when it left declaration values to
`RLF-EXPRESSIONS`, and it costs nothing, because a command's `Doc` was always able to mix canonical
structure with `verbatim` subtrees. -/
private def Tree.canonical? (tree : Tree) (normalized : String) (span : CommandSpan) :
    Option (Nat × Doc) :=
  match tree.kindOf span.root with
  -- `Lean/Parser/Command.lean:317-318` (v4.32.0):
  --   def «namespace» := leading_parser "namespace " >> checkColGt >> ident
  -- A keyword and an identifier, always exactly one space apart. `checkColGt` constrains the parser,
  -- not the printer: it is satisfied by any column past the command's, and column 0 + one space is.
  | "Lean.Parser.Command.namespace" => tree.wholeSpan? normalized span
  -- `Lean/Parser/Command.lean:337-338` (v4.32.0):
  --   def «end» := leading_parser "end" >> optional (ppSpace >> checkColGt >> identWithPartialTrailingDot)
  -- The identifier is optional, so this is one token or two; `spaceSeparated` handles both without
  -- knowing which, because it spaces whatever tokens the command actually has.
  | "Lean.Parser.Command.end" => tree.wholeSpan? normalized span
  -- `Lean/Parser/Command.lean:299-300` (v4.32.0):
  --   def «section» := leading_parser
  --     sectionHeader >> "section" >> optional (ppSpace >> checkColGt >> ident)
  -- The label is optional, so this is one token or two before the header, and `spaceSeparated` handles
  -- both. `sectionHeader` (`:288-292`) is four optional slots:
  --   optional ("@[" >> nonReservedSymbol "expose" >> "] ") >> optional ("public ") >>
  --   optional ("noncomputable ") >> optional ("meta ")
  -- Three of them are lone keyword atoms and flat-run correctly — `noncomputable section` is the one
  -- that actually occurs. The first does not: `@[` and `]` are separate tokens, so a run holding them
  -- emits `@[ expose ]`. Commands filling that slot keep their bytes, which is the call `open` already
  -- makes for `openOnly`'s brackets rather than a new kind of judgement.
  | "Lean.Parser.Command.section" => do
    guard !(tree.opensAttributeBracket normalized span)
    tree.wholeSpan? normalized span
  -- `Lean/Parser/Command.lean:531-532` (v4.32.0):
  --   def «universe» := leading_parser "universe" >> many1 (ppSpace >> checkColGt >> ident)
  -- A keyword and one or more identifiers, one space apart. No brackets, no separators, and no terms:
  -- `many1` of an `ident` is the flat run `spaceSeparated` is for, whatever its length.
  | "Lean.Parser.Command.universe" => tree.wholeSpan? normalized span
  -- `Lean/Parser/Command.lean:852-853` (v4.32.0):
  --   def «open» := leading_parser withPosition ("open" >> openDecl)
  -- `withPosition` builds no node, so the command is the `open` atom plus one `openDecl` alternative
  -- (`:737-739`, a pseudo-kind, so the alternative *is* the child). Three of the six are flat runs of
  -- identifiers and keywords that want one space between them (`:724-725`, `:732-735`):
  --   openSimple  := many1 (ppSpace >> checkColGt >> ident)
  --   openScoped  := " scoped" >> many1 (ppSpace >> checkColGt >> ident)
  --   openHiding  := ppSpace >> atomic (ident >> " hiding") >> many1 (ppSpace >> checkColGt >> ident)
  -- The other two are not, and are left conservative rather than guessed at (`:728-731`):
  -- `openRenaming` is `sepBy1 openRenamingItem ", "`, so a flat run emits `a → b , c → d` with a
  -- space before the comma; `openOnly` is `atomic (ident >> " (") >> many1 ident >> ")"`, so a flat
  -- run emits `Foo ( a b )`. Both need a layout that knows about separators and brackets, which is a
  -- claim this prompt has not made.
  | "Lean.Parser.Command.open" => do
    let children := tree.nodeChildren[span.root]!
    guard (children.size == 1)
    guard <| [
        "Lean.Parser.Command.openSimple", "Lean.Parser.Command.openScoped",
        "Lean.Parser.Command.openHiding"
      ].contains (tree.kindOf children[0]!)
    tree.wholeSpan? normalized span
  -- The declaration *shell*: doc comment, attributes, modifiers, keyword, name. See
  -- `declarationShell?` for the citations and for why the signature and the value are not touched.
  | "Lean.Parser.Command.declaration" => do
    let shell ← tree.declarationShell? span.root
    guard (shell.last <= span.last)
    -- Over the whole shell, because a comment between *any* two of these tokens would be dropped:
    -- the layout chooses every gap in it, including the two it fills with a line break.
    guard (tree.triviaClean span.first shell.last)
    -- But only over the flat run, because the two verbatim slots keep their bytes and their newlines.
    -- Asking it of the docstring would refuse every multi-line one, which is most of them.
    guard (tree.singleLineTokens normalized shell.restFirst shell.last)
    -- The line breaks below indent to nothing, so they may only be emitted at column 0.
    guard (shell.doc.isNone && shell.attrs.isNone || tree.atLineStart normalized span.first)
    let verbatimSlot (bounds : Option (Nat × Nat)) : Doc :=
      match bounds with
      | none => .empty
      | some (lo, hi) => .verbatim (tree.tokenSpanText normalized lo hi) ++ .hard
    return (shell.last, verbatimSlot shell.doc ++ verbatimSlot shell.attrs
      ++ tree.spaceSeparated normalized shell.restFirst shell.last)
  | _ => none

/-- One region of a command a layout accounts for: the tokens `[first, last]`, and the `Doc` standing
in for their bytes.

A command's layout is an array of these — sorted, non-overlapping — and every byte *between* two
claims stays verbatim. `canonical?` returns the first and largest of them, the prefix ending at the
declaration's name; the members claim the rest. Generalizing from the single prefix to an array is
what lets one `structure` command lay out its own shell, leave its signature as bytes, and then still
lay out each field's shell — regions the prefix model could not reach past. -/
private structure Claim where
  first : Nat
  last : Nat
  doc : Doc

/-- Do the gaps inside `[first, last]` hold no line break?

The gap *bytes*, not the trivia runs: `triviaClean` is asked first and says no comment sits in them,
so what is left is whitespace and the only question is whether it crosses a line. A flat run may
collapse horizontal space to one byte, but it may never delete a newline. `declarationShell?` keeps
such a break by emitting `hard` after its doc comment; a member shell cannot, because `hard` indents
to nothing (`RLC-IMPL`: the printer never nests) and a member is indented, so the break would land the
name at column 0 — which for `structFields` is `manyIndent`, i.e. `withPosition ((colGe p)*)`
(`Lean/Parser/Extra.lean:199-201`), and would not parse. A member shell refuses the shape instead. -/
private def Tree.flatGaps (tree : Tree) (normalized : String) (first last : Nat) : Bool := Id.run do
  for index in [first:last] do
    let some a := tree.source.tokens[index]? | return false
    let some b := tree.source.tokens[index + 1]? | return false
    if (sliceNormalized normalized a.stop b.start).contains '\n' then return false
  return true

/-- The shell of one `inductive` constructor or `structure` field: its opener, its modifiers, its name.

`RLF-COMMANDS`'s task names structures and inductives, and `declarationShell?` stops at the
declaration's own name, so the members are what is left of them. Their grammars leave a shell and
little else (`Lean/Parser/Command.lean:210-212`, `:257-258`, `:265-266`, v4.32.0):

    def ctor              := leading_parser
      atomic (optional docComment >> "\n| ") >> ppGroup (declModifiers true >> rawIdent >> optDeclSig)
    def structSimpleBinder := leading_parser
      atomic (declModifiers true >> ident) >> optDeclSig >> optional (Term.binderTactic <|> Term.binderDefault)
    def structCtor        := leading_parser
      atomic (ppIndent (declModifiers true >> ident >> many (ppSpace >> Term.bracketedBinder) >> " :: "))

Everything past the name is `optDeclSig` or a `bracketedBinder` — a *term*, which `RLF-EXPRESSIONS`
owns — so the claim ends at the name. That also sidesteps `structCtor`'s `" :: "`, which `many
(ppSpace >> Term.bracketedBinder)` can separate from the name by arbitrarily many tokens: the shell
would not be one contiguous run, and a run is all a `Claim` can be.

The name is indexed among the shape's **direct token children**, which is why each shape states how
many it must have. `ctor`'s are `|` and the name; its doc comment is under `optional`, hence a child
of a `null` node and not of the `ctor` — so it stays outside the shell and keeps its own bytes and
line break for free. `structSimpleBinder`'s only direct token is the name, and its doc comment *is*
inside `declModifiers` and therefore inside the shell — which `flatGaps` then refuses, correctly:
that field's modifier run has to stay on its own line and nothing here could put it there.

An unmodified field is just its name — a one-token shell, with no gap to collapse and nothing any
layout could change. That is not a claim, and `first < name` is what says so. -/
private def Tree.memberShell? (tree : Tree) (normalized : String) (node : Nat) : Option Claim := do
  let (nameIndex, tokenCount) ← match tree.kindOf node with
    | "Lean.Parser.Command.ctor" => some (1, 2)
    | "Lean.Parser.Command.structSimpleBinder" => some (0, 1)
    | "Lean.Parser.Command.structCtor" => some (0, 2)
    | _ => none
  let direct := tree.tokenChildren[node]!
  guard (direct.size == tokenCount)
  let name := direct[nameIndex]!
  let modifiers ← (tree.nodeChildren[node]!).find? fun child =>
    tree.kindOf child == "Lean.Parser.Command.declModifiers"
  -- Tokens are indexed in source order, so the shell's first token is whichever of the opener and the
  -- modifier run comes first — `ctor` puts `|` ahead of its modifiers, the other two do not.
  let first := match tree.subtreeTokens modifiers with
    | some (lo, _) => min lo direct[0]!
    | none => direct[0]!
  guard (first < name)
  -- Over the whole shell: a comment between any two of these tokens would be dropped by the flat run.
  guard (tree.triviaClean first name)
  guard (tree.singleLineTokens normalized first name)
  guard (tree.flatGaps normalized first name)
  return { first, last := name, doc := tree.spaceSeparated normalized first name }

/-- Every member shell inside this command that starts after the command's own claim ends. -/
private def Tree.memberClaims (tree : Tree) (normalized : String) (root : Nat) (after : Nat) :
    Array Claim := Id.run do
  let mut claims : Array Claim := #[]
  -- Pre-order DFS makes a node's subtree the contiguous index range `[root, subtreeEnd)`
  -- (`RLF-COMMANDS` measures this: `evidence/01-projection-shape.txt`), and index order agrees with
  -- source order, so the claims come out sorted with no sort.
  for node in [root:tree.subtreeEnd[root]!] do
    if let some claim := tree.memberShell? normalized node then
      if claim.first > after then
        claims := claims.push claim
  return claims

/-! ## Terms

Only `Term.app` decides anything here, and that is measured rather than a place to start.
`notes/02-expressions.md` §3 records why: Lean's own formatter takes inter-atom spacing from the
atom's **declared** string — `infixl:65 " + "` (`Init/Notation.lean:284`) declares `+` with a space on
each side, and `Init/Prelude.lean:5390` says so outright — falling back to a lexical
minimum-separation rule only for atoms that declare none (`Lean/PrettyPrinter/Formatter.lean:366-417`).
The projection records a token's *source* text, never the declaration, so a term layout can cite only
those kinds whose spacing does not depend on that string.

`Term.app` is the largest such kind and the largest term kind in real Lean at all — 11,679 of 122,011
token-bearing nodes on the frozen sample (`evidence/02-term-census.txt`). It declares **no atom**:
`app := trailing_parser:leadPrec:maxPrec many1 argument` (`Lean/Parser/Term.lean:892`). What separates
a function from its argument is `argument := checkWsBefore "expected space" >> checkColGt "expected to
be indented" >> …` (`:885-888`), and `checkWsBefore` "requires that there is some whitespace at this
location" (`Lean/Parser/Basic.lean:1180-1184`). **The parser rejects `f a` with the space removed**, so
one space is the minimum the grammar accepts rather than this formatter's taste. That is a stronger
citation than any command layout has, each of which cited a shape the parser *permits*.

`Term.proj` (1,448) needs no layout, and that is an answer rather than a gap. It is `checkNoWsBefore >>
"." >> checkNoWsBefore >> (fieldIdx <|> rawIdent)` (`:906-907`), so the parser rejects `e . f` — every
proj in a module that analyzed is *already* tight, and a layout collapsing it would be provably dead
code on every input this printer can receive.
-/

/-- One constituent of a node, in source order: one of its own tokens, or a whole node-child.

The projection stores a node's tokens and its node-children in two separate arrays, so neither alone
is the node's shape. `f a b` is an `app` whose *token* child is `f` and whose *node* child is the
`null` that `many1 argument` built — and `a` and `b` are that null's **tokens**, not its nodes. A
layout that needs "the gaps between this node's parts" can get them from neither array, only from the
two merged by position. -/
private structure Part where
  /-- First token index of this part. -/
  first : Nat
  /-- Last token index of this part; equal to `first` for one of the node's own tokens. -/
  last : Nat
  /-- The node-child this part is, or `none` when it is one of the node's own tokens. -/
  child : Option Nat

/-- A node's parts, in source order. -/
private def Tree.parts (tree : Tree) (node : Nat) : Array Part := Id.run do
  let mut parts : Array Part := #[]
  for token in tree.tokenChildren[node]! do
    parts := parts.push { first := token, last := token, child := none }
  for child in tree.nodeChildren[node]! do
    if let some (first, last) := tree.subtreeTokens child then
      parts := parts.push { first, last, child := some child }
  -- Tokens are indexed in source order, so ordering by `first` is ordering by position. Empty
  -- node-children are dropped rather than placed: they contribute no bytes, and nothing in the
  -- projection says where among its siblings an absent slot belongs (`evidence/01-projection-shape.txt`
  -- measures 15.5% of nodes to be exactly that ambiguous).
  return parts.qsort (·.first < ·.first)

/-- An `app`'s parts: its function, and its arguments lifted out of the `null` that holds them.

`many1 argument` builds exactly one `null` node around every argument (`Lean/Parser/Term.lean:892`),
so an app's parts are *not* its own: `f a b` is `app` with token child `f` and node child `null`, and
`a` and `b` are the null's tokens. Reading `parts` directly would collapse the gap between `f` and the
null — the first argument — and leave every later gap inside it untouched, turning `f  a  b` into
`f a  b`. The null is the `many`, not a constituent, so it is lifted rather than descended into.

The same holds for every laid-out kind: `explicitBinder`'s `many1 binderIdent` and its `binderType`
each arrive as one null, so `(x y : A)`'s parts are only the binder's own brackets until they are
lifted. One level is enough — no grammar this file lays out nests a `many` inside an `optional`. -/
private def Tree.liftedParts (tree : Tree) (node : Nat) : Array Part := Id.run do
  let mut parts : Array Part := #[]
  for token in tree.tokenChildren[node]! do
    parts := parts.push { first := token, last := token, child := none }
  for child in tree.nodeChildren[node]! do
    if tree.kindOf child == "null" then
      parts := parts ++ tree.parts child
    else if let some (first, last) := tree.subtreeTokens child then
      parts := parts.push { first, last, child := some child }
  return parts.qsort (·.first < ·.first)

/-- How a kind's grammar spaces the gaps between its parts. -/
private inductive Spacing where
  /-- Every gap is exactly one space. -/
  | flat
  /-- The two gaps just inside the outer brackets are tight; every other gap is one space.

  **This is not a rule about brackets.** It is three declarations that happen to agree, and
  `structInst` is the counter-example that proves it: it declares `"{ "` and `" }"` — *spaced* —
  where `implicitBinder` declares a bare `"{"` and `"}"` (`Term.lean:351-355` against
  `Term/Basic.lean:217-218`). Same brace, opposite spacing, and the projection sees `{` for both. So
  a kind may be added here only by reading its own grammar and finding bare brackets, never by
  recognizing that it has brackets at all. See `spacingOf`. -/
  | bracketed
  /-- No layout: every gap keeps its bytes. -/
  | keep
  deriving BEq

/-- The spacing each kind's parser declares, and nothing else.

**`bracketed` is one rule covering three binders, and it is read off their grammars rather than
imposed on them** (`Lean/Parser/Term/Basic.lean`, v4.32.0):

    def explicitBinder (requireType := false) := leading_parser ppGroup <|
      "(" >> withoutPosition (many1 binderIdent >> binderType requireType >>
        optional (binderTactic <|> binderDefault)) >> ")"                          -- :206-207
    def implicitBinder (requireType := false) := leading_parser ppGroup <|
      "{" >> withoutPosition (many1 binderIdent >> binderType requireType) >> "}"  -- :217-218
    def instBinder := leading_parser ppGroup <|
      "[" >> withoutPosition (optIdent >> termParser) >> "]"                       -- :248-249

Each opens and closes with a **bare** atom — `"("`, not `" ( "` — so the declaration puts no space
against the bracket, and Lean's lexical rule adds none either because `(x` does not re-lex as one
token (`Lean/PrettyPrinter/Formatter.lean:392-399`). Every interior gap is one space, and each for its
own declared reason: `many1 binderIdent` separates two idents, which is the one case that rule forcing
a space unconditionally (`:387-389`); `binderType := … optional (" : " >> termParser)` (`:181-182`),
`binderDefault := " := " >> termParser` (`:186-187`) and `optIdent := optional (atomic (ident >> " :
"))` (`:238-239`) each declare their atom **with** a space on each side.

That last group is the declared-string spacing `notes/02-expressions.md` §3 says the projection cannot
carry — and it is citable here for the reason a notation's is not: these are parser declarations in
the compiler this stack pins, a closed set, not an open one the corpus being formatted can extend.

**`withoutPosition` is why collapsing inside these three is unconditionally safe**, and it is a
stronger warrant than the one `app` gets. `withoutPosition(p)` "runs `p` without the saved position,
meaning that position-checking parsers like `colGt` will have no effect… usually used by bracketing
constructs like `(...)` so that the user can locally override whitespace sensitivity"
(`Lean/Parser/Basic.lean:1565-1571`). So inside a binder's brackets there is no live column check for
re-spacing to break: `app` has to argue *collapse, do not break* against a `checkColGt` that is
switched on, while here it is switched off by the grammar itself.

**`matchAlt` is `flat` because every boundary it owns declares a space** (`Lean/Parser/Term.lean:265-270`):

    matchAlt (rhsParser := termParser) := leading_parser (withAnonymousAntiquot := false)
      "| " >> ppIndent (sepBy1 (sepBy1 termParser ", ") " | " >> darrow >>
        checkColGe "…" >> rhsParser)

`"| "` declares a trailing space, `darrow := " => "` (`:99`) declares one on each side, and those are
the alternative's only own gaps — so all three are one space and none is tight. Its patterns are *not*
touched: `sepBy1 (sepBy1 …)` builds **two** levels of `null` and `liftedParts` lifts one, so a
multi-pattern alternative's inner run arrives as a single opaque part and keeps its bytes. That is the
conservative direction, and `| 0,     m => m` in the golden is what it looks like.

Collapsing here is safe under the rule `notes/02-expressions.md` §5b states, even though `matchAlt`
has a live `checkColGe` and no `withoutPosition`: `matchAlts := withPosition $ many1Indent (ppLine >>
matchAlt)` (`:279-280`) saves at the **first alternative's `|`**, which is at the start of a line and
left of every token a same-line collapse can move. Contrast `sepByIndent` below, which saves at a
position *inside* the construct.

**`structInst` is deliberately absent, and it is absent twice over.** Its braces are declared `"{ "`
and `" }"` (`Term.lean:351-355`), so `bracketed` would emit `{x := 1}` where the grammar says
`{ x := 1 }` — the `Spacing.bracketed` docstring's counter-example. And even a rule that got the
braces right could not run: `structInst`'s `withoutPosition` does not reach its fields, because
`sepByIndent` re-establishes a saved position inside it and separates two fields by `", "` **or** by
`checkColEq >> checkLinebreakBefore` (`Parser/Extra.lean:202-204`). Fields at a shared column on
consecutive lines are separated *by that column*, so collapsing the gap after `{` moves the first
field left, the second does not move, and the parse changes. That is a horizontal collapse breaking a
later line — the one thing `notes/02-expressions.md` §7 assumes cannot happen — and it is why §5b
sharpens the rule to *no live column check may compare two tokens whose relative columns the collapse
changes*.

`strictImplicitBinder` is deliberately absent, and that is the same citation read the other way: it is
the one bracketed binder whose interior is **not** wrapped in `withoutPosition` (`:234-236`), so an
enclosing saved position still reaches its contents. Collapsing a run of spaces moves every later
token on the line to the left, which is exactly the quantity `checkColGt` tests, so the rule that is
free for the other three would be doing something unproven here. It is rare enough not to reach the
sample's top kinds, and a rule that has to be argued is worse than none. -/
private def spacingOf (kind : String) : Spacing :=
  match kind with
  | "Lean.Parser.Term.app" => .flat
  | "Lean.Parser.Term.binderDefault" => .flat
  | "Lean.Parser.Term.matchAlt" => .flat
  | "Lean.Parser.Term.explicitBinder" => .bracketed
  | "Lean.Parser.Term.implicitBinder" => .bracketed
  | "Lean.Parser.Term.instBinder" => .bracketed
  | _ => .keep

/-- The separator a kind's grammar declares at gap `index` of `count` parts, or `none` to keep bytes. -/
private def Spacing.separator (spacing : Spacing) (index count : Nat) : Option String :=
  match spacing with
  | .keep => none
  | .flat => some " "
  -- Gaps run `0 … count - 2`, so the last one is `count - 2`. At `count = 3` — `[C]` — the single
  -- interior part makes gap 0 both the first and the last, and both are tight, which is why this is
  -- two independent tests rather than an if/else.
  | .bracketed => if index == 0 || index + 2 == count then some "" else some " "

/-- The bytes between two of a node's parts, or the separator its grammar declares there.

Only a gap that is *whitespace and nothing else* takes the separator. A comment would be **deleted**
by it, which is the failure `respaceable` exists to prevent one layer up. A newline is refused for a
different and sharper reason: rejoining a line is a vertical decision this prompt does not have, and
`argument`'s `checkColGt "expected to be indented"` (`Lean/Parser/Term.lean:885-888`) makes an app's
line breaks parser-significant — an argument pulled left of the enclosing saved position stops being
an argument, the same way `structFields`'s `manyIndent` makes field indentation parser-significant.

An **empty** gap passes that test and is a real case rather than a no-op: the declared `" : "` is a
pretty-printing string, not a parsing one, so `(x :A)` parses and canonicalizes to `(x : A)`. This is
the only place the layouts *add* a space rather than collapse one. -/
private def Tree.gapDoc (tree : Tree) (normalized : String) (spacing : Spacing) (index count : Nat)
    (prior part : Part) : Doc :=
  let raw := match tree.source.tokens[prior.last]?, tree.source.tokens[part.first]? with
    | some a, some b => sliceNormalized normalized a.stop b.start
    | _, _ => ""
  match spacing.separator index count with
  | some separator =>
    if raw.all (· == ' ') then (if separator.isEmpty then .empty else .text separator)
    else .verbatim raw
  | none => .verbatim raw

/-- One term: the grammar this stack can cite for it, and its bytes everywhere else.

**The recursion is what makes the fallback lossless rather than lazy.** A kind with no layout does not
become bytes wholesale — its parts are recursed into and only the gaps *between* them keep their
bytes. So an `app` nested inside a `paren` inside a notation is still found and still collapsed, while
every byte no layout claimed survives untouched. A node with no parts contributes nothing, which is
the absent-syntax case. -/
private partial def Tree.termDoc (tree : Tree) (normalized : String) (node : Nat) : Doc := Id.run do
  let spacing := spacingOf (tree.kindOf node)
  let parts := if spacing == .keep then tree.parts node else tree.liftedParts node
  let mut doc : Doc := .empty
  let mut index := 0
  let mut previous : Option Part := none
  for part in parts do
    if let some prior := previous then
      doc := doc ++ tree.gapDoc normalized spacing (index - 1) parts.size prior part
    doc := doc ++ (match part.child with
      | some child => tree.termDoc normalized child
      | none => .verbatim (tree.tokenSpanText normalized part.first part.last))
    previous := some part
    index := index + 1
  return doc

/-- Every maximal laid-out term inside this command that no shell already claimed.

Maximal, because `termDoc` recurses: an app inside an app's argument, or inside a binder's type, is
laid out by its ancestor's claim already, and claiming it again would emit its bytes twice. Pre-order
DFS makes a node's subtree the contiguous index range `[node, subtreeEnd)`
(`evidence/01-projection-shape.txt`), so skipping a claimed subtree is one comparison and the claims
come out in source order with no sort.

**The overlap test against the shells is not defensive.** `declModifiers` can hold an attribute, an
attribute can take an argument, and an argument is a term — so a term really can sit inside the region
`declarationShell?` already claimed, and two claims over the same tokens would duplicate them. -/
private def Tree.termClaims (tree : Tree) (normalized : String) (root : Nat) (taken : Array Claim) :
    Array Claim := Id.run do
  let mut claims : Array Claim := #[]
  let mut skipUntil := root
  for node in [root:tree.subtreeEnd[root]!] do
    if node < skipUntil then continue
    if spacingOf (tree.kindOf node) == .keep then continue
    let some (first, last) := tree.subtreeTokens node | continue
    if taken.any (fun claim => first ≤ claim.last && claim.first ≤ last) then continue
    claims := claims.push { first, last, doc := tree.termDoc normalized node }
    skipUntil := tree.subtreeEnd[node]!
  return claims

/-- Every region of this command the layout accounts for, in source order.

Empty means the conservative path: no layout recognized the kind, and the command is bytes. Members
are only claimed inside a command that has a layout of its own — a kind on the conservative path rests
on no grammar claim, and reaching inside it to lay out a field would be exactly such a claim.

**Terms inherit that rule, and the reason is weaker for them than for members.** An `app` is an `app`
whatever command encloses it — the parser said so, and collapsing its gaps rests on `argument`'s
`checkWsBefore` rather than on any claim about the enclosing kind. So terms inside a `lemma` could be
laid out soundly, and are not, only because that is a wider claim than this prompt measured. It is
recorded in `results/02-expressions.md` as scope rather than as a rule. -/
private def Tree.claims (tree : Tree) (normalized : String) (span : CommandSpan) : Array Claim :=
  match tree.canonical? normalized span with
  | none => #[]
  | some (last, doc) =>
    let shells := #[{ first := span.first, last, doc : Claim }] ++
      tree.memberClaims normalized span.root last
    (shells ++ tree.termClaims normalized span.root shells).qsort (·.first < ·.first)

/-- How many member shells this module's layouts claimed.

Reported alongside `canonical` and floored by `tests/printer/run.sh`, for the same reason: this
repository writes its constructors the way the layout would, so every member claim here could vanish
and the round-trip would stay green. `evidence/01-projection-shape.txt` measures that no member in
this corpus holds *collapsible* slack, which makes this number the only evidence the member layout
ran at all, and `tests/printer/run.sh`'s wonky fixture the only evidence it changes anything. -/
def Tree.memberShells (tree : Tree) (normalized : String) : Nat :=
  tree.commands.foldl (init := 0) fun count span =>
    match tree.canonical? normalized span with
    | none => count
    | some (last, _) => count + (tree.memberClaims normalized span.root last).size

/-- How many gaps of the given kinds hold spacing the layout would rewrite.

A fact about the *source*, deliberately not about the claims: it counts every node of those kinds in
the module, including ones inside commands on the conservative path, and asks only whether the
separator its grammar declares differs from the bytes actually there. So it is an upper bound on what
the layout changes, and it is that on purpose — it answers "does real Lean write `f     a` at all",
which is a question about Lean rather than about this printer's guards, and a number filtered through
the guards could not tell "the source is already canonical" from "a guard refused it".

This exists because `reformatted` cannot see the difference. That counter is per module, and the
command layouts already reformat 12 of the sample's 62, so a term layout that changed thousands of
gaps and one that changed none both report 12. `RLF-COMMANDS` learned this shape already: `members=`
had to be counted because byte identity could not see it either.

A gap that is not whitespace-only is not counted, because the layout refuses it — so this measures
what the layout *does*, not what it declines. -/
private def Tree.slackIn (tree : Tree) (normalized : String) (kinds : Array String) : Nat := Id.run do
  let mut count := 0
  for node in [0:tree.source.nodes.size] do
    let kind := tree.kindOf node
    if !kinds.contains kind then continue
    let spacing := spacingOf kind
    let parts := tree.liftedParts node
    let mut index := 0
    let mut previous : Option Part := none
    for part in parts do
      if let some prior := previous then
        let raw := match tree.source.tokens[prior.last]?, tree.source.tokens[part.first]? with
          | some a, some b => sliceNormalized normalized a.stop b.start
          | _, _ => ""
        if raw.all (· == ' ') then
          if let some separator := spacing.separator (index - 1) parts.size then
            if raw != separator then count := count + 1
      previous := some part
      index := index + 1
  return count

/-- How many application gaps in this module hold slack the layout would narrow. -/
def Tree.appSlack (tree : Tree) (normalized : String) : Nat :=
  tree.slackIn normalized #["Lean.Parser.Term.app"]

/-- How many bracketed-binder gaps in this module hold spacing the layout would rewrite.

Counted apart from `appSlack` rather than folded into one number, because the two answer different
questions about the corpus and one can be zero while the other is not: `app` only ever *collapses*
slack, while a binder is the one place a layout **adds** a space, to `(x :A)`. -/
def Tree.binderSlack (tree : Tree) (normalized : String) : Nat :=
  tree.slackIn normalized
    #["Lean.Parser.Term.explicitBinder", "Lean.Parser.Term.implicitBinder",
      "Lean.Parser.Term.instBinder"]

/-- The match-alternative gaps whose bytes are not the spacing `matchAlt` declares.

Counts only the alternative's *own* gaps — `| pat`, `pat =>`, `=> rhs`. The gaps between two patterns
of one alternative (`| 0, m =>`) are inside the `sepBy1` null and are not this counter's, for the same
reason the layout does not touch them: `liftedParts` lifts one level of `null`, and `sepBy1 (sepBy1 …)`
builds two. -/
def Tree.matchSlack (tree : Tree) (normalized : String) : Nat :=
  tree.slackIn normalized #["Lean.Parser.Term.matchAlt"]

/-- The tactic blocks in this module, and how many of them a block layout could re-indent at all.

Two numbers rather than a slack count, because `RLF-TACTICS` fails at a different place than
`RLF-EXPRESSIONS` did. A slack counter asks *would the layout change these bytes*; the question here is
prior to that — **may the layout touch this block at all** — and `notes/03-tactics.md` §5 is why.

`nest` moves a `hard`. It cannot move a `.keep` gap, because those reach the output as `verbatim`,
whose interior is never re-indented (`Doc.lean:62-68`) — the same guarantee that stops a comment body
being rewritten. So re-indenting a block moves its tactics' *first* lines and leaves their continuation
lines behind, and by `sepBy1Indent`'s separator clause (`Lean/Parser/Extra.lean:206-208`) a
continuation that lands on the block's column stops being a continuation and becomes a tactic. The
block may be re-indented only if the printer owns every newline in it, which here means: **every tactic
is on one line.**

A tactic's span is tested rather than its gaps, and that is deliberate — a newline *inside* a token is
just as unownable as one in a gap, because a multi-line string literal reaches the output verbatim too,
and must. `tokenSpanText` over the tactic's own first-to-last token catches both.

**`ownable` is an upper bound, and is reported as one.** It asks only whether the printer could own the
newlines *inside* this block. A block that passes can still sit inside one that does not — an ownable
`simp`/`exact` pair nested under a `with` alternative whose lines this printer does not emit — and then
its `nest` would count from column 0 instead of from where it actually starts (`Printer.lean:1186`,
`startsLine`). The sufficient condition is ownable *and* reachable from the command root through
printer-owned newlines only. This counter deliberately does not test that: the loose number is the one
that says whether the strict one is worth computing, and if the upper bound is small the question is
closed either way.

**`ownLine` and `atTwo`** are the rest of the tuple, and together they decide design A
(`notes/03-tactics.md` §8). A would rewrite a block as `nest 2` over `hard`-separated tactics, starting
on a new line at column 2: `nest` counts from column 0 for a printer that never nests (§7), and
`Format.defIndent := 2` (`Init/Data/Format/Basic.lean:379`) is where the 2 comes from. Since
`tacticBlankGaps` is 0 on real code, every separator is *already* one newline — so A rewrites a block
to its own bytes exactly when the block already begins its line at column 2, and changes something
otherwise. Splitting `ownable` three ways is what says *which* something, and the three answers are
not alike:

* **`atTwo`** — begins its line, at column 2. A is the identity here. This is A's whole no-op set.
* **`ownLine` but not `atTwo`** — begins its line, deeper than 2. **Nested**, and A would de-indent it
  to 2, out of whatever encloses it. This is the `.keep` trap of §5 with a number on it.
* **not `ownLine`** — inline, as in `:= by simp`, where the block sits wherever `by ` left it. A would
  break it onto a new line, which is a *wrapping* decision and wants a margin nobody has set (§7).

`ownable` alone cannot tell the three apart — it says only that the printer could own the newlines
*inside* the block — and the distance between it and `atTwo` is the measured size of the upper bound's
overstatement.

The block's column is its first tactic's, which is the whole block's: `checkColEq` puts every tactic in
a `sepBy1Indent` on one column (`Lean/Parser/Extra.lean:206-208`), so there is nothing to average. -/
def Tree.tacticBlocks (tree : Tree) (normalized : String) : Nat × Nat × Nat × Nat := Id.run do
  let mut blocks := 0
  let mut ownable := 0
  let mut ownLine := 0
  let mut atTwo := 0
  for node in [0:tree.source.nodes.size] do
    if tree.kindOf node != "Lean.Parser.Tactic.tacticSeq1Indented" then continue
    let parts := tree.liftedParts node
    if parts.isEmpty then continue
    blocks := blocks + 1
    let mut everyTacticOneLine := true
    for part in parts do
      let span := tree.tokenSpanText normalized part.first part.last
      if span.contains '\n' then everyTacticOneLine := false
    if everyTacticOneLine then
      ownable := ownable + 1
      if let some first := parts[0]? then
        if let some token := tree.source.tokens[first.first]? then
          if firstOnLine normalized token.start then
            ownLine := ownLine + 1
            if columnOf normalized token.start == 2 then atTwo := atTwo + 1
  return (blocks, ownable, ownLine, atTwo)

/-- The separator gaps between two tactics that hold more than one newline — the gaps design B would
have rewritten, and the only bytes in this prompt that would have changed.

**It is 0 on the frozen sample, across 62 modules and 1,966 blocks, and design B is retired.** Real
Lean does not put a blank line between two tactics: every blank line in the sample is followed by a
column-0 line, so it *ends* an indented block rather than sitting inside one
(`evidence/03-blank-line-columns.txt`, which reads the bytes as lines and never loads this code).
The counter stays because the 0 is the finding and a number nobody can reproduce is not one —
`tests/printer/run.sh` hand-counts it to 3 against a written fixture, and two mutations of the two
guards below each move that 3.

`sepByIndent.formatter` pushes exactly one `"\n"` per newline separator (`Lean/Parser/Extra.lean:218`),
and design B cited that the way the header layout cites `ppLine >> ppLine`. **It is a weaker citation
than it looks, and it would not have licensed B even at a non-zero count.** The header's `ppLine`s are
a grammar declaring its own vertical shape. This is a *formatter*, and it starts from a `Syntax` tree
whose newline separator is a null node (`n.matchesNull 0`, `:215`) — the blank line is already gone
before that code runs, so one `"\n"` is all it can emit and not a ruling that an author's blank line
should be collapsed. This printer starts from a lossless projection that still holds those bytes. The
two disagree about what is known, not about what is right, and the compiler cannot be cited for a
decision it never had the information to make.

Two guards, and each refuses rather than counts:

* **whitespace-only.** A separator gap can hold a comment — `\n  -- why\n  ` — and rewriting its
  newline run would delete it. This is `gapDoc`'s spaces-only test widened from spaces to whitespace,
  and mutation 3 of `RLF-EXPRESSIONS` is what proved that test load-bearing.
* **a newline must be present at all.** A `;`-separated gap on one line is not this layout's business;
  the grammar offers `psep` and a linebreak as alternatives (`Extra.lean:206-208`) and nothing licenses
  turning one into the other.

Counted per *gap* rather than per block, for the reason `binderCommented` exists in the printer
fixtures: a block can hold one blank-line gap and five clean ones, and a per-block number could not
tell a layout that fixed the one from a layout that rewrote all six. -/
def Tree.tacticBlankGaps (tree : Tree) (normalized : String) : Nat := Id.run do
  let mut count := 0
  for node in [0:tree.source.nodes.size] do
    if tree.kindOf node != "Lean.Parser.Tactic.tacticSeq1Indented" then continue
    let parts := tree.liftedParts node
    let mut previous : Option Part := none
    for part in parts do
      if let some prior := previous then
        let raw := match tree.source.tokens[prior.last]?, tree.source.tokens[part.first]? with
          | some a, some b => sliceNormalized normalized a.stop b.start
          | _, _ => ""
        let newlines := raw.foldl (fun n c => if c == '\n' then n + 1 else n) 0
        if raw.all Char.isWhitespace && newlines > 1 then count := count + 1
      previous := some part
  return count

/-- How many of this module's commands take a canonical layout rather than the conservative path.

Reported by `printer-roundtrip` and floored by `tests/printer/run.sh`, because byte identity cannot
see this number and the corpus cannot either. This repository writes its declarations the way the
layout would, so every guard here could refuse every command and the round-trip would still be green
on all 20 modules — the formatter would simply have become the identity function again. This is the
number that says the layout *ran*. -/
def Tree.canonicalCommands (tree : Tree) (normalized : String) : Nat :=
  tree.commands.foldl (init := 0) fun count span =>
    if (tree.canonical? normalized span).isSome then count + 1 else count

/-- The syntax kind of every command the layouts refused, one entry per command.

`canonicalCommands` counts the claims; this names the misses, and the two answer different questions.
On this repository the miss list is short and already understood, so this exists for the frozen
mathlib sample, where `canonical` is barely half of `commands` against 95% here. That gap is a fact
about which *kinds* this repository happens to contain, and a bare percentage cannot say which — a
number that low is either a list of grammars nobody has read yet, which is ordinary remaining work, or
a guard refusing shapes it was built to claim, which is a defect. Only the kinds distinguish them.

**A refused `declaration` reports its inner shape instead**, as `declaration/«instance»`. The bare kind
is useless for exactly the case that matters: `declaration` is one kind covering eleven alternatives
(`:282-285`), and refusing an `instance` is a decision this stack made and cited, while refusing a
`def` would be a defect. Those must not tally to the same line. The shape is the second node-child's
kind, which is where `declaration`'s grammar puts the alternative; a `declaration` with no such child
cannot occur in an accepted module, and reports the bare kind rather than inventing one.

Deliberately not a count per kind: the caller tallies. Even split by shape a kind is refused for two
unlike reasons — no layout claims it at all, or a layout claims it and a runtime guard said no — and
this still cannot tell those apart, so it reports the kind and leaves that reading to whoever has both
this and the grammar. -/
def Tree.unclaimedKinds (tree : Tree) (normalized : String) : Array String :=
  tree.commands.foldl (init := #[]) fun kinds span =>
    if (tree.canonical? normalized span).isSome then kinds else
      let kind := tree.kindOf span.root
      let detailed :=
        if kind == "Lean.Parser.Command.declaration" then
          match (tree.nodeChildren[span.root]!)[1]? with
          | some shape => s!"{kind}/{tree.kindOf shape}"
          | none => kind
        else kind
      kinds.push detailed

/-- The syntax kind of every node whose subtree carries at least one token, one entry per node.

`unclaimedKinds` names the commands the layouts refused; this names what is *inside* them, and inside
the regions every claimed command leaves verbatim — the terms. `RLF-EXPRESSIONS` has to pick which
term kinds it can cite a grammar for, and `RLF-COMMANDS` paid to learn that a census taken over this
repository answers a question about its author rather than about Lean, so the caller runs this over
the frozen sample and tallies.

**Nodes whose subtree holds no token are skipped**, because an absent slot has no atoms and therefore
nothing a layout could decide about it — 36% of this corpus's nodes are absent syntax
(`evidence/01-projection-shape.txt`). The filter is the subtree rather than the direct token
children, so a *filled* `many`/`optional` wrapper survives it and `null` still leads the census. That
is correct and not the filter leaking: those wrappers are real syntax, they simply declare no atoms
of their own.

Deliberately not a count per kind, and deliberately the bare kind: the caller tallies, and what it
must tally by is the distinction between a kind this printer can cite (`Lean.Parser.Term.*`, a parser
declaration in the compiler this stack pins) and one it cannot (a `notation`, whose kind is generated
from its own syntax and whose spacing lives in its declaration, not in the tree). That distinction is
visible in the kind string and in nothing else here. -/
def Tree.nodeKinds (tree : Tree) : Array String := Id.run do
  let mut kinds := #[]
  for index in [0:tree.source.nodes.size] do
    if (tree.subtreeTokens index).isSome then
      kinds := kinds.push (tree.kindOf index)
  return kinds

/-- One command.

The extent is the claims, and the bytes between them. Everything a layout did not claim is emitted
verbatim: the trivia before the first token, any region between two claims — a declaration's
signature, a field's type — and everything from the last claim to the end of the extent. Those carry
the comments and blank lines *between* commands, which belong to no command's layout, and which
`RLC-SPEC` measured the parser attaching greedily to whichever token came first.

`Doc.verbatim` is the right constructor for those and not a shortcut around the algebra. `RLC-IMPL`
added it for exactly this shape — bytes that are not the formatter's to touch — and unlike `hard` it
neither re-indents its content nor forces its group to break. -/
def Tree.command (tree : Tree) (normalized : String) (span : CommandSpan) : Doc := Id.run do
  let claims := tree.claims normalized span
  if claims.isEmpty then
    return .verbatim (sliceNormalized normalized span.extent.start span.extent.stop)
  let mut doc : Doc := .empty
  let mut cursor := span.extent.start
  for claim in claims do
    let start := (tree.source.tokens[claim.first]?.map (·.start)).getD span.extent.start
    let stop := (tree.source.tokens[claim.last]?.map (·.stop)).getD span.extent.stop
    doc := doc ++ .verbatim (sliceNormalized normalized cursor start) ++ claim.doc
    cursor := stop
  return doc ++ .verbatim (sliceNormalized normalized cursor span.extent.stop)

/-! ## The module header

`[0, headerStop)` is the one region of a module the projection does not describe. That is not an
oversight to route around: `LosslessSource.lean:358` records *why* — "a module linter never receives
it" — so the artifact cannot carry header tokens without making its shape depend on which producer
built it, which is strictly worse than carrying none.

So the header's structure has to come from somewhere else, and the only two candidates are the bytes
and the parser. The bytes alone are not enough: a lexical scan for `import` cannot tell a keyword from
the same word inside a comment. That leaves parsing, here, which is why this is the one place the
printer touches `Lean.Syntax`.

`notes/01-command-printing.md`'s Design A is not contradicted by that. Its argument was that printing
*commands* in-frontend costs a median 1.96 s frontend run per file (`RLS-FINAL`); a header parse is not
a frontend run — `Lean.Parser.parseHeader` builds an *empty* environment and uses only the builtin
token table plus `Module.updateTokens` (`Lean/Parser/Module.lean:75-79`). Nor does it widen what
`format` depends on: `format` already takes `normalized`, because every conservative path slices bytes
out of it. The header parse reads those same bytes. Its whole cost is that `format` becomes `IO`, and
both callers are `IO` already.
-/

/-- Every leaf beneath `stx` as its byte range, in source order, or `none` if any has no bytes.

`.missing` and the synthetic infos are refusals rather than skips. They mean the parser did not read
this text, and a layout that quietly dropped them would emit a header that is missing a word.

Only the leaf's *own* range is taken. The trivia around it needs no separate record: the gap between
two leaves is exactly the bytes between them, so every question below is byte arithmetic on
`normalized` and none of it depends on which of the two leaves the parser chose to attach a comment
to. -/
private partial def headerLeaves (stx : Lean.Syntax) (acc : Array (Nat × Nat)) :
    Option (Array (Nat × Nat)) :=
  match stx with
  | .missing => none
  | .node _ _ args => args.foldl (init := some acc) fun acc arg => acc.bind (headerLeaves arg)
  | .atom info _ | .ident info _ _ _ =>
    match info with
    | .original _ pos _ endPos => some (acc.push (pos.byteIdx, endPos.byteIdx))
    | _ => none

/-- The header's line groups — the `module` keyword, `prelude`, and each `import` — in source order.

Found by kind rather than by argument index. The grammar is

    header := optional (moduleTk >> ppLine >> ppLine) >> optional («prelude» >> ppLine) >>
      many («import» >> ppLine) >> ppLine

(`Lean/Parser/Module/Syntax.lean:26-29`), whose only node-children through the `optional`/`many` nulls
are exactly these three kinds. Dispatching on kind means the empty `optional` slots — which have no
position, the same absence measured in this module's header comment — need no special case, and an
argument-index assumption that a later Lean release invalidated would show up as a refusal rather than
as a header laid out from the wrong slot. -/
private partial def headerGroups (stx : Lean.Syntax) (acc : Array Lean.Syntax) : Array Lean.Syntax :=
  match stx with
  | .node _ kind args =>
    if kind == ``Lean.Parser.Module.moduleTk || kind == ``Lean.Parser.Module.«prelude»
        || kind == ``Lean.Parser.Module.«import» then
      acc.push stx
    else
      args.foldl (init := acc) fun acc arg => headerGroups arg acc
  | _ => acc

/-- One group as a single line: its leaves one space apart, or its bytes when that would lose
something.

The two refusals are the ones every layout in this module makes, asked over one group's span: a comment
between two leaves (`whitespaceOnly`) would be dropped by re-spacing, and a leaf spelling more than one
line cannot go through `Doc.text`, which holds exactly one (`Doc.lean:47-51`).

The newline check is defensive and no test reaches it, which is worth saying rather than leaving to be
discovered. Five of the header's six atoms are fixed keywords, and the sixth leaf is a module name — so
the only way to spell a newline inside one is an escaped identifier, `import «a⏎b»`, which the lexer
does accept (`takeUntilFn isIdEndEscape`, `Lean/Parser/Basic.lean:986`). It is not reachable from these
tests, because such a module would have to exist on disk to elaborate. The guard costs one scan and
holds up a `Doc.text` precondition, so it stays.

Space-separating covers `import`'s modifiers — `public`, `meta`, `all` — without enumerating them.
They are leaves like any other and their order is the parser's, not this function's. -/
private def headerGroupDoc (normalized : String) (leaves : Array (Nat × Nat)) : Doc := Id.run do
  let some (firstStart, _) := leaves[0]? | return .empty
  let some (_, lastStop) := leaves[leaves.size - 1]? | return .empty
  let keepBytes : Doc := .verbatim (sliceNormalized normalized firstStart lastStop)
  let mut line : Doc := .empty
  for h : index in [0:leaves.size] do
    let (start, stop) := leaves[index]
    let text := sliceNormalized normalized start stop
    if text.contains '\n' then return keepBytes
    if index != 0 && !whitespaceOnly normalized leaves[index - 1]!.2 start then return keepBytes
    line := if index == 0 then .text text else line ++ .text " " ++ .text text
  return line

/-- The bytes between two groups: the break the grammar asks for, or the bytes that were there.

The grammar's own vertical layout is `optional (moduleTk >> ppLine >> ppLine) >> optional («prelude» >>
ppLine) >> many («import» >> ppLine)` (`Lean/Parser/Module/Syntax.lean:26-29`) — a blank line after
`module`, and one line each thereafter. `afterModule` selects the first; the rest of the rule is
below, because "one line each thereafter" is what the grammar asks when *generating* a header from
syntax, and this printer is not generating one — it is reading a header somebody wrote.

Choosing the gap means owning every byte in it, so the choice is declined in two cases and the bytes
stand instead:

* **a comment in the gap.** Common enough that this module's own header has one, and refusing the whole
  header over it — the first thing this function did — would have switched the layout off for the file
  that introduced it. The import below the comment still gets laid out; only the vertical decision
  defers.
* **the next group is not at a line start.** `Doc.hard` emits a newline plus the current indentation,
  and this printer never nests, so an indented group would be silently de-indented (see `startsLine`).
  It also declines when the gap holds no newline at all, so `module import Foo` on one line keeps its
  bytes rather than being split by a rule nobody argued.

**A blank line the author left between two imports is kept**, and that is a stop rule rather than a
preference. `RLF-COMMANDS` scopes import *organization* out of this prompt — "sorting is a separate
opt-in fix" — and grouping imports by blank line is organization, not spacing: mathlib's headers put
one between their `public import`s and their plain `import`s, and deleting it reorganizes the header
just as surely as reordering it would. This layout re-spaces *within* a line and never decides which
imports belong together.

Runs of blank lines collapse to one, which is spacing and is this layout's to choose. The one blank
line the layout *adds* is after `module`, because the header grammar puts `ppLine` there
(`Lean/Parser/Module/Syntax.lean:17-36`) and a module keyword crowded against its first import is the
one vertical shape the grammar itself rules out.

An earlier version emitted a single `hard` between every pair of groups, which read "the grammar
decides vertical space" as licence to delete blank lines. `evidence/01-printer-sample.txt` is where
that surfaced: it dropped a line from real mathlib headers, and no header in this repository had a
blank line inside it for the corpus to notice. -/
private def headerGap (normalized : String) (stop start : Nat) (afterModule : Bool) : Doc :=
  if whitespaceOnly normalized stop start && startsLine normalized start then
    let lines := (sliceNormalized normalized stop start).foldl
      (fun count character => if character == '\n' then count + 1 else count) 0
    if afterModule || lines > 1 then .hard ++ .hard else .hard
  else
    .verbatim (sliceNormalized normalized stop start)

/-- The canonical header layout, or `none` to keep every byte of it.

Import *order* is never touched. `many («import» >> ppLine)` is walked in source order and each import
keeps its position, because import order is semantic in Lean's module system and `RLF-COMMANDS` scopes
sorting out of this prompt explicitly.

As in `Tree.command`, the claim is bounded by the leaves: the bytes before the first one (a file's
copyright comment) and from the last one to `headerStop` (the blank line before the first command) go
out verbatim, because they are trivia belonging to no group's layout. Between those bounds every byte
is either a leaf or a gap, and `headerGroupDoc`/`headerGap` each decline to bytes on their own, so a
refusal is local to the group or gap that earned it. -/
private def headerLayout? (normalized : String) (headerStop : Nat) (stx : Lean.Syntax) :
    Option Doc := Id.run do
  if stx.getKind != ``Lean.Parser.Module.header then return none
  let groups := headerGroups stx #[]
  if groups.isEmpty then return none

  let mut grouped : Array (Array (Nat × Nat)) := #[]
  for group in groups do
    let some leaves := headerLeaves group #[] | return none
    if leaves.isEmpty then return none
    grouped := grouped.push leaves

  let some (firstStart, _) := grouped[0]![0]? | return none
  let some (_, lastStop) := grouped[grouped.size - 1]!.back? | return none
  -- The header parse and the projection agree on where the header ends, or this is not the header the
  -- artifact was built from and none of its offsets mean anything here.
  if lastStop > headerStop then return none
  if !startsLine normalized firstStart then return none

  let mut body : Doc := .empty
  for h : g in [0:grouped.size] do
    body := body ++ headerGroupDoc normalized grouped[g]
    if g + 1 != grouped.size then
      let some (_, stop) := grouped[g].back? | return none
      let some (start, _) := grouped[g + 1]![0]? | return none
      body := body ++
        headerGap normalized stop start (groups[g]!.getKind == ``Lean.Parser.Module.moduleTk)

  return some <|
    .verbatim (sliceNormalized normalized 0 firstStart)
      ++ body
      ++ .verbatim (sliceNormalized normalized lastStop headerStop)

/-- The whole module: header, commands, uninterpreted tail.

The header arrives already laid out because reading it needs `IO` (`headerDoc`) and nothing else here
does. The tail is `[terminalStop, normalizedBytes)`: empty when the terminal is `eoi`, and `#exit`
plus Lean's never-parsed remainder otherwise. It is carried verbatim because it is not syntax this
printer has any claim on. -/
def Tree.document (tree : Tree) (normalized : String) (header : Doc) : Doc :=
  let body := tree.commands.foldl
    (fun acc span => acc ++ tree.command normalized span) (.empty : Doc)
  let tail : Doc := .verbatim
    (sliceNormalized normalized tree.source.terminalStop tree.source.normalizedBytes)
  header ++ body ++ tail

namespace Printer

/-- Parse the header out of the source bytes and lay it out, or `none` to keep its bytes.

Any parser message at all is a refusal. The header parser recovers from errors by fabricating partial
syntax — `identWithPartialTrailingDot` exists to produce a dotted ident that "can never fully succeed"
(`Lean/Parser/Extra.lean:84-88`) — and refusing on a non-empty log is what keeps that partial syntax
out of a layout that would space-separate it into `import Foo .`. On an accepted module the log is
empty, since the frontend parsed this same header without complaint to produce the artifact.

The `?` form is separate from `headerDoc` because the answer is not observable in the output: refusing
produces the same bytes the source already had, so a test that only reads formatted text cannot tell a
layout that ran from one that declined. `tests/printer/run.sh` asks this directly. -/
def headerDoc? (normalized : String) (headerStop : Nat) : IO (Option Doc) := do
  let (stx, _, messages) ← Lean.Parser.parseHeader (Lean.Parser.mkInputContext normalized "<header>")
  if !messages.toList.isEmpty then return none
  return headerLayout? normalized headerStop stx.raw

/-- The header laid out, or its bytes. -/
def headerDoc (normalized : String) (headerStop : Nat) : IO Doc := do
  return (← headerDoc? normalized headerStop).getD
    (.verbatim (sliceNormalized normalized 0 headerStop))

/-- Format one projected module.

`width` is required rather than defaulted. The margin is configuration, it enters cache identity
(`RLC-SPEC` §5), and `RLC-FINAL` left the value itself an open language decision — defaulting it here
would settle by accident a question a later prompt owns.

`IO` is here for one reason: the header. `Lean.Parser.parseHeader` builds an empty environment, which
is an `IO` action, and the header cannot be laid out without it (see the header section above). Both
callers are `IO` already, and the parse reads only `normalized`, which this function already takes — so
nothing about what a formatted module *depends on* changed, and the artifact's digest still binds it.

`tests/printer/run.sh` checks the result against real parser output: every module round-trips byte for
byte, which is what says a layout that ran neither ran long nor stopped short. -/
def format (source : LosslessSource) (normalized : String) (width : Nat) : IO String := do
  let header ← headerDoc normalized source.headerStop
  return renderText width ((Tree.ofSource source).document normalized header)

end Printer

end LeanFmt.Internal
