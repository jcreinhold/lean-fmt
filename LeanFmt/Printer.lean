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

/-- Does this token begin its line?

`Doc.hard` emits a newline plus *the current indentation*, and this printer never nests, so the only
indentation it can produce is column 0. A layout that breaks a line inside a command that does not
start at column 0 would therefore silently de-indent it. Whether a top-level command belongs at column
0 is a language decision, and no prompt in this stack has made it — so the layouts that break lines ask
this first and keep their bytes when the answer is no. -/
private def Tree.atLineStart (tree : Tree) (normalized : String) (index : Nat) : Bool :=
  match tree.source.tokens[index]? with
  | none => false
  | some token => token.start == 0 || sliceNormalized normalized (token.start - 1) token.start == "\n"

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

**The shapes.** Four of the eleven alternatives open the same way — a keyword atom, then `declId`,
then a signature, then the value (`:187-188`, `:194-195`, `:196-197`, `:198-199`) — and those four are
what this recognizes:

    def «abbrev»    := leading_parser "abbrev " >> declId >> ppIndent optDeclSig >> declVal
    def definition  := leading_parser "def " >> recover declId .. >> ppIndent optDeclSig >> declVal >> optDefDeriving
    def «theorem»   := leading_parser "theorem " >> recover declId .. >> ppIndent declSig >> declVal
    def «opaque»    := leading_parser "opaque " >> declId >> ppIndent declSig >> declVal

`structure`, `instance`, and `inductive` are not among them and stay conservative:
`evidence/01-projection-shape.txt` counts 21, 11, and 6 of them here, and their grammar has not been
read.

The signature and the value are deliberately *not* reached. Both are terms, `RLF-EXPRESSIONS` owns
them, and everything from the `declId`'s last token onward stays verbatim until it does. -/
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
      "Lean.Parser.Command.theorem", "Lean.Parser.Command.opaque"
    ].contains (tree.kindOf shape)
  let shapeChildren := tree.nodeChildren[shape]!
  let declId ← shapeChildren[0]?
  guard (tree.kindOf declId == "Lean.Parser.Command.declId")
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

/-- The whole module: header, commands, uninterpreted tail.

The header is `[0, headerStop)` and is not a command — a module linter never receives it, so it has no
tokens and cannot be printed from the tree. The tail is `[terminalStop, normalizedBytes)`: empty when
the terminal is `eoi`, and `#exit` plus Lean's never-parsed remainder otherwise. Both are carried
verbatim because neither is syntax this printer has any claim on. -/
def Tree.document (tree : Tree) (normalized : String) : Doc :=
  let header : Doc := .verbatim (sliceNormalized normalized 0 tree.source.headerStop)
  let body := tree.commands.foldl
    (fun acc span => acc ++ tree.command normalized span) (.empty : Doc)
  let tail : Doc := .verbatim
    (sliceNormalized normalized tree.source.terminalStop tree.source.normalizedBytes)
  header ++ body ++ tail

namespace Printer

/-- Format one projected module.

`width` is required rather than defaulted. The margin is configuration, it enters cache identity
(`RLC-SPEC` §5), and `RLC-FINAL` left the value itself an open language decision — defaulting it here
would settle by accident a question a later prompt owns.

With every kind still on the conservative path this is the identity on accepted source, and that is a
property worth testing rather than an embarrassment: it says the skeleton — header split, command
extents, tail — loses nothing before any layout decision is layered on top. `tests/printer/run.sh`
checks it against real parser output. -/
def format (source : LosslessSource) (normalized : String) (width : Nat) : String :=
  renderText width ((Tree.ofSource source).document normalized)

end Printer

end LeanFmt.Internal
