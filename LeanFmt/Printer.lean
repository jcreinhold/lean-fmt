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

**What the projection does not carry, measured rather than assumed.** Over all 20 modules of this
repository (34,844 nodes, `evidence/01-projection-shape.txt`), 12,797 nodes (36.7%) carry no token at
all — they are *absent* syntax, the unfilled optional slots of `declModifiers`, `optDeclSig`,
`Termination.suffix` — and `collect` gives them range `(0,0)` because a node's range is the hull of the
leaves beneath it and there are none. For 5,345 of them (15.3% of all nodes) the parent also has direct
token children, so nothing in the projection says where among its siblings the absent slot belongs.
`Lean.Syntax` has no position for them either; this is not something the projection dropped.

Two consequences run through everything below:

1. **Node order is index order, never range order.** `collect` pushes a node's placeholder at
   `build.nodes.size` before folding its args left to right, so a parent precedes its children and
   siblings ascend in arg order. Sorting children by range would be correct for the 84.7% that carry
   tokens and silently wrong for the rest.
2. **The conservative path reads bytes, not the tree.** Empty nodes contribute no bytes, so re-emitting
   a command's byte extent is unaffected by all 5,345 ambiguous placements. It is the only path whose
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
token-bearing children, index order agrees with byte order (0 violations over 34,844 nodes). -/
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
  be contiguous. `evidence/01-projection-shape.txt` reports 0 contiguity violations over 34,844 nodes,
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

`none` is the *absent syntax* case and is the common one: 36.7% of nodes are empty
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

/-- How many of this module's commands take a canonical layout rather than the conservative path.

Reported by `printer-roundtrip` and floored by `tests/printer/run.sh`, because byte identity cannot
see this number and the corpus cannot either. This repository writes its declarations the way the
layout would, so every guard here could refuse every command and the round-trip would still be green
on all 20 modules — the formatter would simply have become the identity function again. This is the
number that says the layout *ran*. -/
def Tree.canonicalCommands (tree : Tree) (normalized : String) : Nat :=
  tree.commands.foldl (init := 0) fun count span =>
    if (tree.canonical? normalized span).isSome then count + 1 else count

/-- One command.

The extent is split into three: the trivia before the first token, the tokens the layout claimed, and
**everything from there to the end of the extent**. Only the middle is ever canonicalized. The outer
two are emitted verbatim
because they carry the comments and blank lines *between* commands — which belong to no command's
layout, and which `RLC-SPEC` measured the parser attaching greedily to whichever token came first.

`Doc.verbatim` is the right constructor for those and not a shortcut around the algebra. `RLC-IMPL`
added it for exactly this shape — bytes that are not the formatter's to touch — and unlike `hard` it
neither re-indents its content nor forces its group to break. -/
def Tree.command (tree : Tree) (normalized : String) (span : CommandSpan) : Doc :=
  match tree.canonical? normalized span with
  | none => .verbatim (sliceNormalized normalized span.extent.start span.extent.stop)
  | some (last, canonical) =>
    let tokenStart := (tree.source.tokens[span.first]?.map (·.start)).getD span.extent.start
    let tokenStop := (tree.source.tokens[last]?.map (·.stop)).getD span.extent.stop
    let before : Doc := .verbatim (sliceNormalized normalized span.extent.start tokenStart)
    let after : Doc := .verbatim (sliceNormalized normalized tokenStop span.extent.stop)
    before ++ canonical ++ after

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
`module`, and one line each thereafter. That is what `afterModule` selects between.

Choosing the gap means owning every byte in it, so the choice is declined in two cases and the bytes
stand instead:

* **a comment in the gap.** Common enough that this module's own header has one, and refusing the whole
  header over it — the first thing this function did — would have switched the layout off for the file
  that introduced it. The import below the comment still gets laid out; only the vertical decision
  defers.
* **the next group is not at a line start.** `Doc.hard` emits a newline plus the current indentation,
  and this printer never nests, so an indented group would be silently de-indented (see `startsLine`).
  It also declines when the gap holds no newline at all, so `module import Foo` on one line keeps its
  bytes rather than being split by a rule nobody argued. -/
private def headerGap (normalized : String) (stop start : Nat) (afterModule : Bool) : Doc :=
  if whitespaceOnly normalized stop start && startsLine normalized start then
    if afterModule then .hard ++ .hard else .hard
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
