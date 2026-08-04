module

public import LeanFmt.Analysis
public import LeanFmt.Application
public import LeanFmt.ArtifactStore
public import LeanFmt.Cache
public import LeanFmt.Cli
public import LeanFmt.Comments
public import LeanFmt.Config
public import LeanFmt.Discovery
public import LeanFmt.Doc
public import LeanFmt.Edit
public import LeanFmt.Formatter.NativeLayout
public import LeanFmt.Imports
public import LeanFmt.LanguageServer
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import Test

import all LeanFmt.Analysis
import all LeanFmt.Application
import all LeanFmt.ArtifactStore
import all LeanFmt.Cache
import all LeanFmt.Cli
import all LeanFmt.Comments
import all LeanFmt.Config
import all LeanFmt.Discovery
import all LeanFmt.Doc
import all LeanFmt.Edit
import all LeanFmt.Formatter.NativeLayout
import all LeanFmt.Imports
import all LeanFmt.LanguageServer
import all LeanFmt.Rules
import all LeanFmt.Suppression

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal

namespace LeanFmt.Test.Unit.Layout

/-! ## Layout

Several assertions below deliberately re-assert exact figures from a removed experiment (see git history):
if the product and the prototype ever disagree about margin 13, one of them is wrong
and this is where it surfaces. -/

private def hugeWidth : Nat :=
  1000000

private def stripLayout (s : String) : String :=
  s.foldl (fun acc c => if c == '\n' || c == ' ' then acc else acc.push c) ""

private def lineCount (s : String) : Nat :=
  (s.splitOn "\n").length

/-- The text at a byte range. `Mark.output` and `Comment.range` are byte-indexed, like every other
offset in the projection, so a test that reads one back must slice by bytes too. -/
private def slice (s : String) (start stop : Nat) : String :=
  (Substring.Raw.mk s ⟨start⟩ ⟨stop⟩).toString

private def nextRand (seed : Nat) : Nat :=
  (seed * 1103515245 + 12345) % 2147483648

/-- A letters-only atom: no space and no newline, so `stripLayout` cannot eat part of one. -/
private def atomFor (r : Nat) : String :=
  String.ofList (List.replicate (r % 6 + 1) (Char.ofNat (97 + r % 26)))

private structure GeneratedDoc where
  document : Doc
  flat : String
  atoms : String
  nextSeed : Nat
  deriving Inhabited

/-- A deterministic document generator with an independent expected flat spelling and literal-atom
model. Seeded rather than random so a failure is reproducible from the printed seed alone; `hard`,
`verbatim`, and registered leaves are excluded because these properties concern custom groups. -/
private partial def genDoc (depth : Nat) (seed : Nat) : GeneratedDoc :=
  let r := nextRand seed
  if depth == 0 then
    match r % 3 with
    | 0 => { document := .empty, flat := "", atoms := "", nextSeed := r }
    | 1 =>
      let atom := atomFor r
      { document := .text atom, flat := atom, atoms := atom, nextSeed := r }
    | _ =>
      let flat := if r % 2 == 0 then " " else ""
      { document := .line flat, flat, atoms := "", nextSeed := r }
  else
    match r % 7 with
    | 0 =>
      let atom := atomFor r
      { document := .text atom, flat := atom, atoms := atom, nextSeed := r }
    | 1 => { document := .line " ", flat := " ", atoms := "", nextSeed := r }
    | 2 => { document := .line "", flat := "", atoms := "", nextSeed := r }
    | 3 =>
      let left := genDoc (depth - 1) r
      let right := genDoc (depth - 1) left.nextSeed
      {
        document := .cat left.document right.document
        flat := left.flat ++ right.flat
        atoms := left.atoms ++ right.atoms
        nextSeed := right.nextSeed }
    | 4 =>
      let generated := genDoc (depth - 1) r
      { generated with document := .nest 2 generated.document }
    | 5 =>
      let generated := genDoc (depth - 1) r
      { generated with document := .group generated.document }
    | _ =>
      let generated := genDoc (depth - 1) r
      { generated with document := .mark ⟨r % 100, r % 100 + 5⟩ generated.document }

private def testDoc : IO Unit := do
  -- The case the whole model was chosen for. A `do` block is `do act1; act2` flat and drops the
  -- separator when broken. Oppen *and* `Std.Format` both
  -- render `do\n  act1;\n  act2` here and strand the semicolon, because their break carries blanks
  -- only. This is the one thing `line (flat)` buys, so it is the first thing checked.
  let doBlock : Doc :=
    .text "do" ++ .nest 2 (.group (.line " " ++ .text "act1" ++ .line "; " ++ .text "act2"))
  ensure (renderText 40 doBlock == "do act1; act2") "the flat do block lost its separator"
  ensure (renderText 12 doBlock == "do\n  act1\n  act2")
      "the broken do block stranded its separator"
  -- A group is decided against the line, not against itself: `f(arg)` is 6 columns but the line it
  -- would produce is 14.
  let tail : Doc :=
    .group (.text "f(" ++ .nest 2 (.line "" ++ .text "arg") ++ .line "" ++ .text ")") ++
      .text " => tail"
  ensure (renderText 14 tail == "f(arg) => tail") "a group that fits its line was broken"
  ensure (renderText 13 tail == "f(\n  arg\n) => tail") "a group whose line overflows stayed flat"
  -- A margin is not a guarantee: `) => tail` is atomic, so no margin makes this line shorter.
  ensure (renderText 5 tail == "f(\n  arg\n) => tail") "an unbreakable atom was broken anyway"
  -- Nested groups decide independently: the outer breaks, the inner still fits.
  let nested : Doc :=
    .group (.text "aaaa" ++ .line " " ++ .group (.text "b" ++ .line " " ++ .text "c"))
  ensure (renderText 6 nested == "aaaa\nb c") "an inner group broke because its parent did"
  -- `hard` forces every enclosing group open. This is why a line comment is safe: `--` swallows its
  -- line, so a group must never flatten one onto the same line as the code that follows it.
  ensure (renderText hugeWidth (.group (.text "a" ++ .hard ++ .text "b")) == "a\nb")
      "a group containing a hard break was flattened"
  ensure (renderText hugeWidth (.nest 2 (.group (.text "a" ++ .hard ++ .text "b"))) == "a\n  b")
      "a hard break ignored the current indentation"
  ensure (renderText hugeWidth (.nest 2 (.text "a" ++ .blank ++ .text "b")) == "a\n\n  b")
      "a structural blank line contained indentation whitespace"
  -- `verbatim` is the constructor added for exactly this reason: a block comment's
  -- interior is content, and `hard` would re-indent it. `Std.Format` re-indents it too.
  let block : Doc := .nest 4 (.hard ++ .verbatim "/- a\n b -/" ++ .hard ++ .text "x")
  ensure (renderText hugeWidth block == "\n    /- a\n b -/\n    x")
      "verbatim text was re-indented, rewriting its content"
  -- After a multi-line verbatim the column is its last line, not the old column plus its width.
  ensure (renderText 12 (.group (.verbatim "aa\nbbb" ++ .line " " ++ .text "cc")) == "aa\nbbb\ncc")
      "a multi-line verbatim was treated as flat"
  -- `text` claims to be one line, and the claim is checkable rather than conventional.
  ensure (Doc.wellFormed doBlock) "a well-formed document was rejected"
  ensure (!Doc.wellFormed (.text "a\nb")) "a text holding two lines was accepted"
  ensure (!Doc.wellFormed (.line "a\nb")) "a break with a multi-line flat spelling was accepted"
  ensure (Doc.wellFormed (.verbatim "a\nb")) "verbatim is how a newline is stated and was rejected"
  ensure (!Doc.wellFormed (.mark ⟨20, 10⟩ (.text "x"))) "a reversed source mark was accepted"
  -- Columns are codepoints, as in Lean's native renderer. Six CJK codepoints plus a space and `x`
  -- fit at eight despite occupying more terminal cells, and fail at seven.
  let unicode : Doc := .group (.text "世界世界世界" ++ .line " " ++ .text "x")
  ensure (renderText 8 unicode == "世界世界世界 x") "Unicode columns were counted as bytes or cells"
  ensure (renderText 7 unicode == "世界世界世界\nx")
      "a Unicode group did not break at its codepoint width"
  -- A registered formatter result remains opaque and is interpreted at the active column. Its
  -- native group therefore sees the two columns already emitted by the custom prefix.
  let native := Std.Format.group ("a" ++ Std.Format.line ++ "b")
  let hybrid : Doc := .text "x " ++ .registered native
  let wideHybrid := renderDetailed 5 hybrid
  let narrowHybrid := renderDetailed 4 hybrid
  ensure (wideHybrid.text == "x a b") "an opaque registered document ignored its active column"
  ensure (narrowHybrid.text == "x a\nb") "an opaque registered document did not reflow"
  ensure (wideHybrid.metrics.nativeEvents > 0 && narrowHybrid.metrics.nativeEvents > 0)
      "the registered document was not interpreted through the native renderer"
  -- `fill` is the native flatten behavior, decided per break against the whole remainder. At
  -- width five every element stays on the row; at four the last one wraps.
  let fillDoc : Doc := .fill (.text "a" ++ .line " " ++ .text "b" ++ .line " " ++ .text "c")
  ensure (renderText 5 fillDoc == "a b c") "a fill that fit was broken"
  ensure (renderText 4 fillDoc == "a b\nc") "a fill did not wrap its overflowing element"
  -- `nativeText` carries the native semantics: its interior newline breaks to the entry's indent
  -- and re-groups the remainder of the enclosing group, so a tail that fits flattens even though
  -- the group's own decision was broken. `hard` is the custom contrast: it forces every enclosing
  -- group open and nothing re-groups after it.
  let regrouped : Doc := .group (.nativeText "a\nb" ++ .line " " ++ .text "c")
  ensure (renderText hugeWidth regrouped == "a\nb c")
      "a native hard line did not re-group its fitting tail"
  let forced : Doc := .group (.text "a" ++ .hard ++ .text "b" ++ .line " " ++ .text "c")
  ensure (renderText hugeWidth forced == "a\nb\nc") "a custom hard break re-grouped its tail"
  -- The entry column enters the first row's fit measurement, as in the native machine: the same
  -- group that flattens at column zero breaks when one column is already spent.
  let entry : Doc := .group (.text "ab" ++ .line " " ++ .text "cd")
  ensure ((renderDetailed 5 entry (column := 1)).text == "ab\ncd")
      "the entry column did not enter the first row's fit measurement"
  ensure ((renderDetailed 5 entry).text == "ab cd") "a fitting group broke at column zero"
  -- Source map. Output ranges are bytes; `mark` carries no width and renders exactly as its body.
  let marked : Doc := .text "a" ++ .mark ⟨10, 20⟩ (.text "bcd") ++ .text "e"
  let (out, marks) := render hugeWidth marked
  ensure (out == "abcde") "mark changed the rendering"
  ensure (marks == #[{ source := ⟨10, 20⟩, output := ⟨1, 4⟩ }])
      "the source map recorded the wrong range"
  ensure (slice out 1 4 == "bcd") "the recorded output range does not hold the marked text"
  -- Marks complete innermost-first, so the array is in completion order rather than source order.
  let (_, nestedMarks) := render hugeWidth (.mark ⟨1, 2⟩ (.text "x" ++ .mark ⟨3, 4⟩ (.text "y")))
  ensure
      (nestedMarks ==
        #[{ source := ⟨3, 4⟩, output := ⟨1, 2⟩ }, { source := ⟨1, 2⟩, output := ⟨0, 2⟩ }])
      "nested marks were not recorded innermost-first"
  -- A mark spanning a break still bounds exactly what it produced.
  let (spanOut, spanMarks) :=
    render 4 (.mark ⟨0, 9⟩ (.group (.text "aaa" ++ .line " " ++ .text "bbb")))
  ensure (spanOut == "aaa\nbbb") "a marked group did not break"
  ensure
      (spanMarks.size == 1 &&
        slice spanOut spanMarks[0]!.output.start spanMarks[0]!.output.stop == spanOut)
      "a mark spanning a break lost part of its output"
  -- **When is a rendered unit's bytes independent of what follows it?** Range formatting reports an
  -- actual range and promises the text outside it is byte-identical, so it may only expand to a unit
  -- whose rendering the rest of the document cannot re-decide. That is not a property of commands —
  -- it is a property of `fits`, which walks the *tail* of the work list (`Doc.lean:168-188`). A group
  -- at the end of a unit therefore measures itself against whatever comes after, unless something
  -- between them stops the walk.
  --
  -- Exactly one thing does: a `verbatim` holding a newline, which `fits` treats like `hard`
  -- (`Doc.lean:174-176`). So "ends in trivia containing a newline" is the frozen unit boundary
  -- condition.
  let unitEndingIn (trailing : String) : Doc :=
    .group (.text "aaaa" ++ .line " " ++ .text "bbbb") ++ .verbatim trailing
  -- At margin 10 the group is 9 columns and fits flat on its own either way.
  ensure (renderText 10 (unitEndingIn "\n") == "aaaa bbbb\n")
      "the newline-terminated unit did not fit flat"
  ensure (renderText 10 (unitEndingIn " ") == "aaaa bbbb ")
      "the space-terminated unit did not fit flat"
  -- Newline-terminated: no tail, however long, can reach back through it.
  ensure
      ((renderText 10 (unitEndingIn "\n" ++ .text "yyyyyyyyyyyyyyyy")).startsWith
        (renderText 10 (unitEndingIn "\n")))
      "a newline-terminated unit's layout depended on the document after it"
  -- Not newline-terminated: a one-character tail is enough to rebreak the unit before it. This is
  -- the same-line case (`def a := 1 def b := 2`), and it is why a range must expand to a newline.
  ensure (renderText 10 (unitEndingIn " " ++ .text "x") == "aaaa\nbbbb x")
      "a space-terminated unit was not rebroken by the text after it — the fit walk no longer runs into \
     the tail, so the range-expansion boundary condition needs restating"
  -- Properties over 400 generated documents. The seed is printed on failure, and generation is
  -- deterministic, so a counterexample is reproducible from that number alone.
  let mut seed := 20260716
  for i in [0:400]do
    let generated := genDoc 5 seed
    seed := generated.nextSeed
    let wrapped : Doc := .group generated.document
    ensure (Doc.wellFormed wrapped) s!"generated document {i} (seed {seed}) was not well formed"
    -- At an unreachable margin every group is flat, so the renderer must agree with an
    -- independently defined flat rendering. This is what pins `line`'s flat text end to end.
    ensure (renderText hugeWidth wrapped == generated.flat)
        s!"flat rendering diverged on document {i} (seed {seed})"
    -- At margin 0 every group with any width breaks, so only the literal atoms survive. Nothing may
    -- be dropped, duplicated, or reordered by breaking.
    ensure (stripLayout (renderText 0 wrapped) == generated.atoms)
        s!"breaking lost or duplicated text on document {i} (seed {seed})"
    for width in [0, 1, 40, 80, 100, 1000]do
      -- Rendering is a function, not a process with state.
      let rendered := renderDetailed width wrapped
      ensure (renderDetailed width wrapped == rendered)
          s!"rendering at width {width} was not deterministic on document {i} (seed {seed})"
      -- Every recorded range must address real output.
      for mark in rendered.sourceMap do
        ensure
            (mark.output.start <= mark.output.stop &&
              mark.output.stop <= rendered.text.utf8ByteSize)
            s!"document {i} (seed {seed}) recorded an out-of-bounds output range at width {width}"
      -- A document can emit no more custom commands than a fixed multiple of its nodes and marks.
      ensure (rendered.metrics.workSteps <= 2 * Doc.size wrapped + 1)
          s!"document {i} (seed {seed}) exceeded its work-step bound at width {width}"
      ensure (lineCount rendered.text <= Doc.size wrapped + 1)
          s!"document {i} (seed {seed}) produced more lines than nodes at width {width}"

/- `NativeLayout` refuses a `choice` node whose alternatives do not spell the same source, rather than
taking `children[0]?` on faith the way `terminalsFrom` used to. The parser does not build a
disagreeing `choice`, so no fixture reaches that refusal from a file and no suite under `tests/` can
prove it fires. Without this the gate is unreachable code. The `Syntax` is hand-built for exactly that
reason. -/
private def choiceAtom (start stop : Nat) (val : String) : Lean.Syntax :=
  .atom (.original "".toRawSubstring ⟨start⟩ "".toRawSubstring ⟨stop⟩) val

private def testChoiceVerification : IO Unit := do
  let source := "alpha beta"
  let agree :=
    Lean.Syntax.node .none Lean.choiceKind #[choiceAtom 0 5 "alpha", choiceAtom 0 5 "alpha"]
  ensure (Formatter.NativeLayout.choiceDisagreement? source agree).isNone
      "a choice node whose alternatives spell the same source was refused"
  let disagree :=
    Lean.Syntax.node .none Lean.choiceKind #[choiceAtom 0 5 "alpha", choiceAtom 6 10 "beta"]
  let some (range, alternative, _, _) :=
    Formatter.NativeLayout.choiceDisagreement? source
      disagree | throw (IO.userError "a choice node whose alternatives spell different source was accepted")
  ensure (alternative == 1) s!"expected the disagreement at alternative 1, got {alternative}"
  ensure (range == ⟨0, 10⟩) s!"expected the choice node's own range, got {range.start}:{range.stop}"
  -- The outer alternatives agree -- both spell bytes 0..5, because the wrapper's own terminals come
  -- from the inner choice's first alternative. The disagreement is one level down, inside outer
  -- alternative 1, which is precisely where `terminalsFrom` never looks. A gate that descended the
  -- way the walk does would report this file clean.
  let nested :=
    Lean.Syntax.node .none Lean.choiceKind
      #[choiceAtom 0 5 "alpha",
        Lean.Syntax.node .none `wrapper
          #[Lean.Syntax.node .none Lean.choiceKind
              #[choiceAtom 0 5 "alpha", choiceAtom 6 10 "beta"]]]
  ensure
      (Formatter.NativeLayout.choiceSpelling source nested[0]! ==
        Formatter.NativeLayout.choiceSpelling source nested[1]!)
      "the nested case is vacuous: its outer alternatives already disagree"
  ensure (Formatter.NativeLayout.choiceDisagreement? source nested).isSome
      "a disagreement nested below the first alternative was missed"

/- Generated terminal sequences through the alignment walk, with no syntax tree and no formatter.

`Formatter.NativeLayout.transform` is the adapter minus syntax collection: terminals, comments,
islands, constraints, and boundaries arrive as data, one state machine runs over an `Std.Format`, and
the command is refused unless every one of them was applied exactly once. Nothing in that signature
is a `Lean.Syntax`, so the sequences below are built rather than parsed -- which is the only way to
put a duplicate spelling, a multi-byte payload, and a deliberately wrong native document next to each
other in one test. `private` is not an obstacle: `import all` above reaches it, the same way
`testChoiceVerification` reaches `choiceDisagreement?`.

The round trip guarantees more than "the payloads match". The emitted payload sequence *is* the
terminal sequence by construction -- alignment writes `terminal.sourceSpelling` at the Nth native
leaf -- so a native document that reorders its own leaves cannot corrupt the output. It is counted as
normalization instead, which is the deliberate asymmetry: Lean's formatter legitimately respells a
token, so refusing a spelling mismatch would refuse ordinary files. Insert and delete are refusals
because they change the leaf *count*, which position cannot absorb. -/
private def spelledTerminals (spellings : Array (String × String)) :
    String × Array Formatter.NativeLayout.Terminal :=
  Id.run do
    let mut source := ""
    let mut terminals := #[]
    for (syntaxSpelling, sourceSpelling) in spellings do
      let start := source.utf8ByteSize
      source := source ++ sourceSpelling
      terminals :=
        terminals.push { syntaxSpelling, sourceSpelling, range := ⟨start, source.utf8ByteSize⟩ }
      source := source ++ " "
    return (source, terminals)

private def nativeSequence (leaves : Array String) : Std.Format :=
  leaves.foldl (init := (none : Option Std.Format))
      (fun document leaf =>
        match document with
        | none => some (Std.Format.text leaf)
        | some document => some (document ++ Std.Format.line ++ Std.Format.text leaf)) |>.getD
    Std.Format.nil

private def alignedPayloads (format : Std.Format) : Array String :=
  ((format.pretty 200).split (fun char => char == ' ' || char == '\n')).toArray.map
      (·.copy) |>.filter
    (!·.isEmpty)

private def testAlignmentSequences : IO Unit := do
  -- A duplicate spelling, two multi-byte payloads, and one terminal the formatter respells the way
  -- `«x»` is spelled `x` in syntax.
  let spellings :=
    #[("alpha", "alpha"), ("beta", "beta"), ("alpha", "alpha"), ("λ", "λ"), ("x", "«x»"),
      ("γδ", "γδ")]
  let (source, terminals) := spelledTerminals spellings
  let expected := spellings.map (·.2)
  let leaves := spellings.map (·.1)
  let run (native : Std.Format) :=
    Formatter.NativeLayout.transform source terminals #[] #[] #[] #[] #[] #[] #[] #[] #[] 0 native
  let .ok (aligned, metrics) :=
    run (nativeSequence leaves) | throw (IO.userError "an ordinary terminal sequence was refused")
  ensure (alignedPayloads aligned == expected)
      s!"alignment did not preserve the ordered payloads: {repr (alignedPayloads aligned)}"
  ensure (metrics.tokenLeaves == spellings.size)
      s!"expected {spellings.size} token leaves, got {metrics.tokenLeaves}"
  ensure (metrics.normalizedTokens == 0)
      s!"a leaf spelling one of its terminal's two spellings counted as normalized \
({metrics.normalizedTokens})"
  -- Insert: one native leaf more than there are terminals.
  -- Insert: one native leaf more than there are terminals. A leaf the adapter cannot place is
  -- `unadapted` — this module's own machinery — and stays a refusal.
  let .error (.unadapted inserted) :=
    run
      (nativeSequence
        (leaves.push "epsilon")) | throw (IO.userError "an extra native leaf was accepted")
  ensure ((inserted.splitOn "extra text leaf").length == 2)
      s!"the extra leaf was refused without naming it: {inserted}"
  -- Delete: one native leaf fewer. A document that stops short of the terminals is `incomplete` —
  -- the toolchain's backtracking dropped a subtree — and the command degrades to its own bytes.
  let .error (.incomplete deleted) :=
    run (nativeSequence leaves.pop) | throw (IO.userError "a missing native leaf was accepted")
  ensure
      ((deleted.splitOn s!"consumed {spellings.size - 1}/{spellings.size} terminals").length == 2)
      s!"the missing leaf was refused without naming the counts: {deleted}"
  -- Reorder: the payloads still come out in terminal order, and the two moved leaves are the two
  -- that now spell neither of their terminal's spellings.
  let swapped := leaves.swapIfInBounds 1 3
  let .ok (reordered, reorderedMetrics) :=
    run
      (nativeSequence
        swapped) | throw (IO.userError "a reordered native document was refused rather than counted")
  ensure (alignedPayloads reordered == expected)
      s!"a reordered native document changed the payload order: {repr (alignedPayloads reordered)}"
  ensure (reorderedMetrics.normalizedTokens == 2)
      s!"expected the two moved leaves to count as normalized, got \
{reorderedMetrics.normalizedTokens}"

/- A leaf whose own bytes carry whitespace escalates to an enclosing island.

`ProofWidgets.Jsx.jsxText` is the measured case and no such parser exists in this project, so the tree
is built by hand -- which is also the sharper test, because it asserts the rule the leaf's bytes
decide rather than one library's kind. Three leaves over one source: an ordinary token, a leaf whose
bytes end in a space, and a string literal's own bytes, which contain a space and must *not* escalate.

The claim is escalation, not protection: the island has to cover the enclosing node, because the
boundary the adapter would choose sits in *front* of the whitespace leaf and reparses into it. An
island over the leaf alone keeps that boundary and fixes nothing. -/
private def sourceLeaf (start stop : String.Pos.Raw) (value : String) (ident : Bool := false) :
    Lean.Syntax :=
  let info := Lean.SourceInfo.original "".toRawSubstring start "".toRawSubstring stop
  if ident then .ident info value.toRawSubstring value.toName [] else .atom info value

private def testWhitespaceEnvelope : IO Unit := do
  -- `<b>alpha </b>` in miniature: `open`, the payload leaf, `close`.
  let source := "open alpha close"
  let node :=
    Lean.Syntax.node .none `test
      #[sourceLeaf ⟨0⟩ ⟨4⟩ "open", sourceLeaf ⟨5⟩ ⟨11⟩ "alpha ", sourceLeaf ⟨11⟩ ⟨16⟩ "close"]
  let (rewritten, islands) := Formatter.NativeLayout.protectSourceData { } source node
  ensure (islands.size == 1)
      s!"a whitespace-bearing leaf produced {islands.size} islands, expected one"
  let island := islands[0]!
  ensure (island.range.start == 0 && island.range.stop == 16)
      s!"the island covers {island.range.start}:{island.range.stop}, not the enclosing node"
  ensure (island.text == source)
      s!"the island's bytes are {repr island.text}, not the node's source"
  ensure (rewritten.isIdent)
      s!"the enclosing node was not replaced by a marker leaf: {rewritten.getKind}"
  -- The negative half. A string literal's bytes contain a space and are already exact under the
  -- ordinary path; escalating one would put every `"a b"` in mathlib inside an island.
  let quoted := "call \"a b\""
  let literal :=
    Lean.Syntax.node .none `test #[sourceLeaf ⟨0⟩ ⟨4⟩ "call", sourceLeaf ⟨5⟩ ⟨10⟩ "\"a b\""]
  let (_, quotedIslands) := Formatter.NativeLayout.protectSourceData { } quoted literal
  ensure quotedIslands.isEmpty
      s!"interior whitespace escalated: {quotedIslands.size} islands over {repr quoted}"

/-- A pinned row lands where its spelling says, in both directions.

`columned` and `anchored` name one column and differ only in what they do when the document has
already indented past it: the first keeps the document's indent, the second dedents to the column.
The difference is a one-token distinction in `boundaryFormat`, it is invisible in any candidate
whose ambient nest is left of the pin, and getting it wrong is a file-level refusal --
`Proofs/.../Rational/GlobalMinimalModel.lean` reparsed its `letI` body as one more argument of the
value. So it is stated here, over a document whose nest is deliberately right of both pins. -/
private def testPinnedRows : IO Unit := do
  let (source, terminals) := spelledTerminals #[("a", "a"), ("b", "b")]
  -- `a`, then a break the document indents four columns, then `b`: the pin at `b` is the only
  -- thing that can move that row.
  let native := Std.Format.text "a" ++ .nest 4 (.line ++ .text "b")
  let run (layout : Formatter.NativeLayout.BoundaryLayout) : IO String := do
    let .ok (rendered, _) :=
      Formatter.NativeLayout.transform source terminals #[] #[] #[] #[] #[(2, layout)] #[] #[] #[]
        #[] 0 native | throw (IO.userError s!"a pinned row was refused: {repr layout}")
    return rendered.pretty 200
  ensureEq "a columned pin below the ambient nest kept the document's indent" "a\n    b"
      (← run (.columned 2))
  ensureEq "an anchored pin below the ambient nest did not dedent to its column" "a\n  b"
      (← run (.anchored 2))

/- `anchor` captures the entry column — the column of the next byte its body would emit — and
re-bases the body's indent to it. That is the primitive prompt 04 adds for the structural
annotations of prompts 09-10: Lean's parser records an offside column in source columns, and the
layout engine needs a way to break at exactly that column no matter what nest surrounds it.

The contract from `notes/02-native-contract.md`: backward-only (the capture looks at bytes already
emitted, never ahead), fit-invisible (the anchor contributes zero width and no hard-stop, so no
enclosing group's decision changes), innermost-wins (a nested anchor re-captures). A body whose
first emission is a break captured nothing and is a development error, pinned by `wellFormed`
here — the renderer panics on it, which no in-process test can survive. -/
private def testAnchor : IO Unit := do
  -- Under a nest: the break lands on the captured column, not the nest's. `f(` ends at column 2,
  -- so the anchored tail breaks to 2 where the nested one breaks to 10.
  let anchored : Doc := .group (.text "f(" ++ .anchor (.text "x" ++ .line " " ++ .text "y"))
  ensure (renderText 4 anchored == "f(x\n  y") "an anchor did not re-base its break column"
  let nested : Doc := .group (.text "f(" ++ .nest 10 (.text "x" ++ .line " " ++ .text "y"))
  ensure (renderText 4 nested == "f(x\n          y") "the nest contrast drifted"
  -- Fit-invisible: the decision at every width matches the un-anchored document; only the broken
  -- layout differs, because the anchor re-based the indent.
  let plain : Doc := .text "p " ++ .group (.text "xy" ++ .line " " ++ .text "z")
  let captured : Doc := .text "p " ++ .group (.anchor (.text "xy" ++ .line " " ++ .text "z"))
  ensure (renderText 6 captured == renderText 6 plain)
      "an anchor changed an enclosing group's flat decision"
  ensure (renderText 5 plain == "p xy\nz" && renderText 5 captured == "p xy\n  z")
      "an anchor changed an enclosing group's broken decision"
  -- Innermost-wins: the inner anchor re-captures at column 4; the outer anchor's own line still
  -- breaks to the outer capture, column 2.
  let both : Doc :=
    .group
      (.text "a " ++
        .anchor
          (.text "b " ++ .anchor (.text "c" ++ .line " " ++ .text "d") ++ .line " " ++ .text "e"))
  ensure (renderText 3 both == "a b c\n    d\n  e") "a nested anchor did not re-capture"
  -- A break-first body captured nothing: rejected at construction-checking time.
  ensure (Doc.wellFormed (.anchor (.text "x"))) "a text-first anchor was rejected"
  ensure (!Doc.wellFormed (.anchor (.line " "))) "a break-first anchor was accepted"

/-! ## The native oracle (LAY-RENDERER-ORACLE)

A differential oracle between the pinned `Std.Format.prettyM` renderer and the `Doc` machine for
unannotated native input. `toDoc` lowers a `Std.Format` tree onto the native fragment; both sides
render at the same width, indent, and entry column; bytes and the tag-event count must agree.
The pinned renderer stays an in-test oracle — production never falls back to it.

Every compared render also gates renderer work by counts: an unannotated document is emitted in
exactly `size` work steps (no marks, one item per node), however many group re-decisions the fill
and hard-line paths make. A failure prints the seed, the tree, and the configuration, which is
enough to reproduce it. -/

/-- A structural printer for failing trees, since `ToString Std.Format` would render the very
bytes under comparison. -/
private partial def dumpFormat : Std.Format → String
  | .nil => "nil"
  | .line => "line"
  | .align force => s!"align {force}"
  | .text value => s!"text {repr value}"
  | .nest n body => s!"nest {n} ({dumpFormat body})"
  | .append left right => s!"append ({dumpFormat left}) ({dumpFormat right})"
  | .group body behavior =>
    s!"group[{if behavior == .fill then "fill" else "allOrNone"}] ({dumpFormat body})"
  | .tag tag body => s!"tag {tag} ({dumpFormat body})"

/-- Lower a native tree onto the native fragment of `Doc`. A newline-bearing `text` is
`nativeText`, the constructor with native multiline semantics; anything else is one `Doc` node
per `Std.Format` node. -/
private partial def toDoc : Std.Format → Doc
  | .nil => .empty
  | .line => .line " "
  | .align force => .align force
  | .text value => if value.contains '\n' then .nativeText value else .text value
  | .nest n body => .nest n (toDoc body)
  | .append left right => .cat (toDoc left) (toDoc right)
  | .group body behavior => if behavior == .fill then .fill (toDoc body) else .group (toDoc body)
  | .tag tag body => .tag tag (toDoc body)

/-- Oracle-side render state: the pinned machine's column discipline (`pushOutput` never sees a
newline, so the column advances by the whole atom) plus a tag-event counter, the observation the
default `String` instance erases. -/
private structure OracleState where
  out : String := ""
  column : Nat := 0
  tagEvents : Nat := 0

private instance : Std.Format.MonadPrettyFormat (StateM OracleState)
    where
  pushOutput value :=
    modify fun state =>
      { state with
        out := state.out ++ value, column := state.column + value.length }
  pushNewline indent :=
    modify fun state =>
      { state with
        out := state.out ++ "\n".pushn ' ' indent, column := indent }
  currColumn := return (← get).column
  startTag _ := modify fun state => { state with tagEvents := state.tagEvents + 1 }
  endTags count := modify fun state => { state with tagEvents := state.tagEvents + count }

/-- The pinned renderer, observed: bytes and tag events at an entry column. -/
private def nativeObserved (format : Std.Format) (width indent column : Nat) : String × Nat :=
  let act : StateM OracleState Unit := Std.Format.prettyM format width indent
  let state := act.run { column } |>.2
  (state.out, state.tagEvents)

/-- A deterministic native-tree generator over every constructor: nil, single- and multi-line
text, line, append, signed nests (down to -3), both group behaviors, both align flags, and tags.
Seeded, so a failure reproduces from the printed seed alone. -/
private partial def genFormat (depth : Nat) (seed : Nat) : Std.Format × Nat :=
  let r := nextRand seed
  let atom := atomFor r
  if depth == 0 then
    match r % 4 with
    | 0 => (.nil, r)
    | 1 => (.text atom, r)
    | 2 => (.line, r)
    | _ => (.text (atom ++ "\n" ++ atomFor (r / 7)), r)
  else
    match r % 10 with
    | 0 => (.nil, r)
    | 1 => (.text atom, r)
    | 2 => (.line, r)
    | 3 =>
      let (left, seed₁) := genFormat (depth - 1) r
      let (right, seed₂) := genFormat (depth - 1) seed₁
      (.append left right, seed₂)
    | 4 =>
      let (body, seed₁) := genFormat (depth - 1) r
      (.nest (((r % 9 : Nat) : Int) - 3) body, seed₁)
    | 5 =>
      let (body, seed₁) := genFormat (depth - 1) r
      (.group body .allOrNone, seed₁)
    | 6 =>
      let (body, seed₁) := genFormat (depth - 1) r
      (.group body .fill, seed₁)
    | 7 =>
      let (body, seed₁) := genFormat (depth - 1) r
      (.align (r % 2 == 0) ++ body, seed₁)
    | 8 =>
      let (body, seed₁) := genFormat (depth - 1) r
      (.tag (r % 8) body, seed₁)
    | _ => (.text (atom ++ "\n" ++ atomFor (r / 7)), r)

/-- The newline count inside native `text` atoms: each one re-queues the remainder of its atom
as a fresh work item after the hard line, so it adds exactly one renderer work step beyond the
node count. -/
private partial def hardLineRequeues : Std.Format → Nat
  | .text value => value.foldl (fun acc char => if char == '\n' then acc + 1 else acc) 0
  | .nest _ body | .group body _ | .tag _ body => hardLineRequeues body
  | .append left right => hardLineRequeues left + hardLineRequeues right
  | _ => 0

/-- One tree at one configuration: bytes, tag events, and the work-step gate. -/
private def oracleAgrees (label : String) (format : Std.Format) (width indent column : Nat) :
    IO Unit := do
  let document := toDoc format
  let (nativeBytes, nativeTags) := nativeObserved format width indent column
  let rendered := renderDetailed width document #[] indent column
  ensure (rendered.text == nativeBytes)
      s!"{label}: byte divergence at width {width}, indent {indent}, column {column}\n      tree: {dumpFormat format}\nnative:\n{repr nativeBytes}\nlean-fmt:\n{repr rendered.text}"
  ensure (rendered.metrics.nativeEvents == nativeTags)
      s!"{label}: tag-event divergence at width {width}, indent {indent}, column {column}\n      tree: {dumpFormat format}\nnative: {nativeTags} events, lean-fmt:       {rendered.metrics.nativeEvents}"
  ensure (rendered.metrics.workSteps == Doc.size document + hardLineRequeues format)
      s!"{label}: renderer work {rendered.metrics.workSteps} != nodes {Doc.size document} + \
      hard-line requeues {hardLineRequeues format} at width {width}, indent {indent}, column \
      {column}\ntree: {dumpFormat format}"

/-- Hand-curated corners, one per behavior the contract pins: the root group that never flattens,
a hard line re-grouping its tail, fill inheriting a flattened enclosing group, an `align false`
vanishing inside a flattened group while charging the phantom measure, an `align true` at and past
its indent, a negative nest clamping, a tag around a breaking group, and a multiline text denying
flattening. The generated trees reach these shapes only by luck; these must hit them every run. -/
private def oracleCorners : Array (String × Std.Format) :=
  #[("root-disallow-hard", .text "a\nb"),
    ("hard-regroups-tail", .group (.text "a\nb" ++ .line ++ .text "c")),
    ("fill-in-flattened",
      .group (.text "x" ++ .line ++ (.group (.text "y" ++ .line ++ .text "z") .fill))),
    ("align-false-flat", .group (.text "ab" ++ .align false ++ .text "cd")),
    ("align-false-phantom",
      .group (.align false ++ .text "aaaa" ++ .line ++ .text "bbbb") ++ .text "cccccccc"),
    ("align-true-nested", .nest 4 (.text "x" ++ .align true ++ .text "y")),
    ("negative-nest", .nest (-3) (.text "x" ++ .line ++ .text "y")),
    ("tag-around-group", .tag 7 (.group (.text "aa" ++ .line ++ .text "bb"))),
    ("multiline-denies-flatten", .group (.text "aa\nbb" ++ .line ++ .text "cc")),
    ("fill-wraps-tail",
      .group
        (.text "call" ++ .line ++
          (.group (.text "aaa" ++ .line ++ .text "bbb" ++ .line ++ .text "ccc") .fill))),
    ("empty-text-atom", .group (.text "" ++ .line ++ .text "x")),
    ("align-at-root", .align true ++ .text "x"),
    -- The Rotate.lean case: a fill lookahead whose remainder is a group item with a hard line in
    -- its flat interior. The machine measures the group item flat, so the hard line is a
    -- *flattened* hard line and denies the fill's flatten even though the candidate fits.
    ("fill-lookahead-flattened-hard",
      .group (.text "aa" ++ .line ++ .group (.text "bbb\nccc" ++ .text "dd") .allOrNone) .fill),
    -- Same denial one level down: the hard line sits inside a nested group inside the fill
    -- candidate's broken walk, behind an ordinary line that would otherwise stop it.
    ("fill-lookahead-nested-hard",
      .group
        (.text "aa" ++ .line ++
          (.group (.text "b" ++ .line ++ .group (.text "ccc\nddd") .fill) .allOrNone))
        .fill),
    -- An allOrNone candidate whose own flat interior has the hard line behind a nested group.
    ("group-candidate-nested-hard",
      .group (.text "aa" ++ .line ++ .group (.text "bbb\nccc") .fill))]

private def testNativeOracle : IO Unit := do
  let widths := [0, 1, 5, 20, 80, hugeWidth]
  let mut seed := 20260804
  for i in [0:300]do
    let (format, nextSeed) := genFormat 5 seed
    seed := nextRand nextSeed
    for width in widths do
      for column in [0, 5]do
        for indent in [0, 3]do
          oracleAgrees s!"generated {i} (seed {seed})" format width indent column
  for (label, format) in oracleCorners do
    for width in widths do
      for column in [0, 3]do
        oracleAgrees s!"corner {label}" format width column 0

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testDoc", run := testDoc }, { name := "testAnchor", run := testAnchor },
    { name := "testNativeOracle", run := testNativeOracle },
    { name := "testChoiceVerification", run := testChoiceVerification },
    { name := "testAlignmentSequences", run := testAlignmentSequences },
    { name := "testPinnedRows", run := testPinnedRows },
    { name := "testWhitespaceEnvelope", run := testWhitespaceEnvelope }]

end LeanFmt.Test.Unit.Layout
