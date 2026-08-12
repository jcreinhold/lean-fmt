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
public import LeanFmt.LosslessSource
public import LeanFmt.Rules
public import LeanFmt.Suppression
public import LeanFmt.Validator
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
import all LeanFmt.LosslessSource
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all LeanFmt.Validator
import all Test.Unit.Fixtures
import all Test.Unit.Layout

import Lean.Data.Lsp

open LeanFmt LeanFmt.Internal
open LeanFmt.Test.Unit.Fixtures
open LeanFmt.Test.Unit.Layout

namespace LeanFmt.Test.Unit.Source

/-! ## Source

The lossless projection and what reads coordinates off it: validation, range selection, and
suppression directives. Every rejection below is an ordinary miss rather than an error, which is the
property the cases exist to pin. -/

/- Every rejection below is an ordinary miss, not an error: a consumer that cannot authenticate a
projection must fall back to the exact frontend rather than trust it or fail the run. -/
private def testLosslessSource : IO Unit := do
  let source := fixtureLosslessSource
  ensure source.structurallyValid "a correctly tiled projection was rejected"
  ensure (source.validFor fixtureSourceText) "the projection rejected its own source"
  -- The recorded CRLF defect: the parser normalizes before it assigns any offset, so the CRLF and
  -- LF forms of one module share a projection. Digesting raw bytes made every CRLF file a
  -- permanent silent miss.
  ensure (source.validFor "def x := 1\r\n")
      "the CRLF form of the projected module was not recognized"
  ensure (!(source.validFor "def x := 2\n")) "a different source matched the projection"
  ensure (!(source.validFor "def x := 1")) "a truncated source matched the projection"
  -- `#exit` ends the token stream before end of file. `terminalStop` is where the terminal command
  -- begins, so the tail covers `#exit` and Lean's never-parsed remainder alike; no token may claim
  -- to describe bytes the parser never read. Recording the terminal's *end* instead left `#exit`
  -- itself covered by nothing, and every file containing one failed to validate at all.
  let tailText := fixtureSourceText ++ "#exit\nnever parsed at all\n"
  let withTail : LosslessSource :=
    { source with
      normalizedBytes := tailText.utf8ByteSize
      normalizedDigest := Digest.ofString tailText }
  ensure withTail.structurallyValid "a projection with an unparsed tail was rejected"
  ensure (withTail.validFor tailText) "the tail projection rejected its own source"
  ensure (withTail.terminalStop < withTail.normalizedBytes) "the tail fixture records no tail"
  let rejects (label : String) (broken : LosslessSource) : IO Unit :=
    ensure (!broken.structurallyValid) s!"{label} was accepted as a valid projection"
  rejects "a stale schema" { source with schema := "lean-fmt.lossless-source.v0" }
  rejects "a gap between tokens"
      { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 5 } }
  rejects "overlapping tokens"
      { source with tokens := source.tokens.set! 1 { source.tokens[1]! with start := 3 } }
  rejects "a token whose span is inverted"
      { source with
        tokens :=
          source.tokens.set! 0
            { source.tokens[0]! with
              start := 3, stop := 0 } }
  let longTrailing := { source.tokens[0]! with trailing := #[{ kind := .whitespace, stop := 5 }] }
  rejects "trivia running past the next token"
      { source with tokens := source.tokens.set! 0 longTrailing }
  rejects "a token stream that stops short of the terminal"
      { source with terminalStop := source.terminalStop + 1 }
  rejects "a terminal past the end of the source"
      { source with terminalStop := source.normalizedBytes + 1 }
  rejects "a header past the terminal" { source with headerStop := source.terminalStop + 1 }
  rejects "a token owned by a nonexistent node"
      { source with tokens := source.tokens.set! 0 { source.tokens[0]! with node := 9 } }
  rejects "a node with a nonexistent kind"
      { source with nodes := source.nodes.set! 0 { source.nodes[0]! with kind := 9 } }
  rejects "a node with a nonexistent parent"
      { source with nodes := source.nodes.set! 0 { source.nodes[0]! with parent := some 9 } }
  rejects "a fabricated token position"
      { source with tokens := source.tokens.set! 0 { source.tokens[0]! with info := .synthetic } }
  let decoded : Except String LosslessSource := Lean.fromJson? (Lean.toJson source)
  match decoded with
  | .ok actual =>
    ensure (actual == source) "lossless-source JSON round trip failed"
  | .error message =>
    throw <| IO.userError s!"lossless-source JSON decode failed: {message}"

/-- Unit selection and splicing over a layout source map.

Driven with a hand-built map rather than a real render, because the questions here are about the
selection algebra — which units a request reaches, when the forward extension fires, what the actual
range is, and whether the splice keeps the caller's bytes — and a synthetic map states each case in
one line. The modes suite drives the same code through the real printer. -/
private def testRangeSelection : IO Unit := do
  -- Three units over a 24-byte source. Unit 1's *output* does not end in a newline, which is the
  -- same-line-commands shape (`def a := 1 def b := 2`) the forward extension exists for.
  --   source:   [0,8) [8,16) [16,24)
  --   rendered: [0,8) [8,15) [15,23)
  let normalized := "AAAAAAA\nBBBBBBB\nCCCCCCC\n"
  let rendered := "aaaaaaa\n" ++ "bbbbbb " ++ "ccccccc\n"
  let marks : Array Mark :=
    #[{ source := ⟨0, 8⟩, output := ⟨0, 8⟩ }, { source := ⟨8, 16⟩, output := ⟨8, 15⟩ },
      { source := ⟨16, 24⟩, output := ⟨15, 23⟩ }]
  let run (start stop : Nat) : Option Application.RangeResult :=
    Application.sliceRange normalized rendered marks ⟨start, stop⟩
  -- A request inside unit 0 formats unit 0 and nothing else: its output ends in a newline, so the
  -- extension does not fire, and units 1-2 keep their source bytes verbatim.
  let some first := run 2 4 |
    ensure false "a request inside unit 0 selected no unit";
    return
  ensure (first.actual == ⟨0, 8⟩) s!"unit 0 request reported actual range {repr first.actual}"
  ensure (first.text == "aaaaaaa\nBBBBBBB\nCCCCCCC\n")
      s!"unit 0 splice did not keep the later units' source bytes: {repr first.text}"
  -- A request inside unit 1 must drag unit 2 in: unit 1's output ends in a space, so its layout was
  -- decided by what follows it, and reporting `[8,16)` would be a promise the bytes do not keep.
  let some second := run 9 10 |
    ensure false "a request inside unit 1 selected no unit";
    return
  ensure (second.actual == ⟨8, 24⟩)
      s!"the forward extension did not fire on a unit ending mid-line: {repr second.actual}"
  ensure (second.text == "AAAAAAA\nbbbbbb ccccccc\n")
      s!"unit 1-2 splice is wrong: {repr second.text}"
  -- Full range reproduces the whole render byte for byte — whole-file / full-range equivalence,
  -- stated where the splice can be held to it.
  let some whole := run 0 24 |
    ensure false "the full range selected no unit";
    return
  ensure (whole.text == rendered) s!"full range did not reproduce the render: {repr whole.text}"
  ensure (whole.actual == ⟨0, 24⟩) s!"full range reported {repr whole.actual}"
  -- An empty request is a cursor position: it selects the unit holding that offset. On a boundary it
  -- takes the unit that *starts* there, not the one that ends there.
  let some empty := run 3 3 |
    ensure false "an empty request selected no unit";
    return
  ensure (empty.actual == ⟨0, 8⟩) s!"an empty request in unit 0 reported {repr empty.actual}"
  let some boundary := run 8 8 |
    ensure false "a boundary request selected no unit";
    return
  ensure (boundary.actual == ⟨8, 24⟩)
      s!"an empty request on the 0/1 boundary did not take the unit starting there: {repr boundary.actual}"
  -- At end of file there is no unit starting there, so the last one answers.
  let some eof := run 24 24 |
    ensure false "an end-of-file request selected no unit";
    return
  ensure (eof.actual == ⟨16, 24⟩) s!"an end-of-file request reported {repr eof.actual}"
  -- Reported output ranges must index the text the caller was handed, not the pre-splice render.
  ensure (second.marks.size == 2) s!"the 1-2 request reported {second.marks.size} units"
  let body := second.marks[0]!
  ensure (slice second.text body.output.start second.marks[1]!.output.stop == "bbbbbb ccccccc\n")
      "the re-based output ranges do not bound the formatted text"
  -- A map with no units at all cannot answer, and says so rather than inventing an empty range.
  ensure ((Application.sliceRange normalized rendered #[] ⟨0, 4⟩).isNone)
      "an empty source map produced a result"

/-- Project suppression directives over findings, and recover directives from the module header.

`apply` is a pure projection over `Array Finding`; the first block checks it in isolation, with
hand-built facts, so the scope arithmetic is tested without a parser. The second block is the
regression that shipped broken once: a directive in the module header `[0, headerStop)` — the
natural home for `ignore-file` — is invisible to artifact trivia, so `collect` scans the header
itself. A hand-built single-command projection puts a directive above the first command and asserts it
is both parsed and, when malformed, reported rather than dropped. -/
private def testSuppression : IO Unit := do
  -- `apply` in isolation. `src` supplies real bytes for the `FMT900` removal fix's range math.
  let src := "module\n-- lean-fmt: ignore-file\ndef x := 1  \n"
  let bytes := src.toUTF8
  let mkFinding (code : String) (start stop : Nat) : Finding :=
    { code, severity := .warning, message := "x", range := ⟨start, stop⟩ }
  -- Synthetic findings drive the code-agnostic suppression machinery. `f013` is a line-range finding;
  -- `f014` is an empty range on the file's upper bound (the shape a rule can still produce, e.g. an
  -- end-of-file diagnostic), kept to prove an empty finding on a scope boundary is caught.
  let f013 := mkFinding "FMT011" 42 44
  let f014 := mkFinding "FMT012" 44 44
  let mkDir (scope : DirectiveScope) (codes? : Option (Array String)) (scopeRange : SourceRange) :
    Directive := { scope, codes?, scopeRange, commentRange := ⟨7, 31⟩ }
  let facts (ds : Array Directive) : SuppressionFacts := { directives := ds, malformed := #[] }
  -- File-scope blanket suppresses every finding in the file.
  let blanket := Suppression.apply (facts #[mkDir .file none ⟨0, bytes.size⟩]) bytes #[f013, f014]
  ensure (blanket.kept.isEmpty && blanket.suppressed == 2 && blanket.unused.isEmpty)
      "file blanket did not suppress every finding"
  -- Code selector suppresses only the named code; the other survives.
  let named :=
    Suppression.apply (facts #[mkDir .file (some #["FMT011"]) ⟨0, bytes.size⟩]) bytes #[f013, f014]
  ensure (named.kept.map (·.code) == #["FMT012"] && named.suppressed == 1 && named.unused.isEmpty)
      "code selector suppressed the wrong set"
  -- Suppression is a projection over codes, so the source-security codes flow through it like any
  -- other. A report-only FMT002 finding is suppressed by a directive that names it.
  let f004 := mkFinding "FMT002" 42 45
  let bidiSuppressed :=
    Suppression.apply (facts #[mkDir .file (some #["FMT002"]) ⟨0, bytes.size⟩]) bytes #[f004]
  ensure (bidiSuppressed.kept.isEmpty && bidiSuppressed.suppressed == 1)
      "a directive naming FMT002 did not suppress the report-only security finding"
  -- A directive whose scope holds no matching finding is unused: FMT900 with a safe removal fix.
  let dead := Suppression.apply (facts #[mkDir .line (some #["FMT011"]) ⟨7, 31⟩]) bytes #[f013]
  ensure (dead.kept.size == 1 && dead.suppressed == 0) "an out-of-scope directive still suppressed"
  ensure (dead.unused.map (·.code) == #["FMT900"]) "an unused directive did not emit FMT900"
  ensure (dead.unused[0]!.fix?.map (·.applicability) == some .safe)
      "the FMT900 removal fix is not safe"
  -- The removal edit is a *clean line* deletion: a directive alone on its line takes the whole line
  -- and its terminating newline (`⟨7, 32⟩` over `src` — `-- …-file` is `[7, 31)`, the `\n` is `31`),
  -- and replaces with nothing. Applying it must leave `module\ndef x := 1  \n`, not a blank line.
  let removal := dead.unused[0]!.fix?.bind (·.edits[0]?)
  ensure (removal.map (·.range) == some ⟨7, 32⟩ && removal.map (·.replacement) == some "")
      "the FMT900 removal fix does not delete exactly the directive line and its newline"
  -- A list with one live and one dead code suppresses the live one and reports the dead one.
  let mixed :=
    Suppression.apply (facts #[mkDir .file (some #["FMT011", "FMT999"]) ⟨0, bytes.size⟩]) bytes
      #[f013]
  ensure (mixed.suppressed == 1 && mixed.unused.map (·.code) == #["FMT900"])
      "a mixed live/dead code list did not both suppress and report"
  -- The non-breaking floor on retired/reserved codes -- a retired/reserved code is inert in a suppression: it
  -- suppresses nothing but is never flagged unused, unlike a genuinely-unknown code (FMT999 above,
  -- which does raise FMT900) -- HAD three cases here. They used FMT001 as their retired instance.
  --
  -- The pre-release renumbering made FMT001 a *live* security rule and emptied `reservedCodes`
  -- (docs/adding-a-rule.md §"Retiring a rule"), so those three cases would have kept running and kept passing while
  -- testing something else entirely: a live rule that happened not to fire. A test that still passes
  -- after its subject has been redefined underneath it is worse than a deleted one, so they are
  -- deleted rather than repointed.
  --
  -- The production branches they covered are still there and still reachable the moment a rule
  -- retires. They are currently UNTESTED, which `reservedCodes`' docstring states at the definition.
  -- Restoring coverage needs a real retirement, not a placeholder entry invented to have something to
  -- assert against.
  -- The empty finding sits exactly on a file scope's upper bound and must still be caught.
  let eof := Suppression.apply (facts #[mkDir .file none ⟨0, 44⟩]) bytes #[f014]
  ensure (eof.suppressed == 1) "a file scope ending at EOF did not catch the empty finding"
  -- Header recovery. `headerStop` is the first command's start, so the directive on line 2 lives in
  -- `[0, headerStop)`, which the artifact omits and `collect` must scan for itself.
  let mkProj (text : String) (headerStop : Nat) : LosslessSource :=
    let size := text.utf8ByteSize
    let tokenStop := headerStop + 3
    { schema := losslessSourceSchema
      mainModule := "Test"
      normalizedBytes := size
      normalizedDigest := Digest.ofString text
      headerStop
      terminalStop := size
      kinds := #["Lean.Parser.Command.declaration"]
      nodes := #[{ kind := 0, parent := none, range := ⟨headerStop, size⟩ }]
      tokens :=
        #[{ node := 0, start := headerStop, stop := tokenStop,
            trailing := #[{ kind := .whitespace, stop := size }] }] }
  let headerFacts := Suppression.collect (mkProj src 32) src
  ensure (headerFacts.directives.size == 1) "collect missed a directive in the module header"
  ensure (headerFacts.directives[0]!.scope == .file)
      "the header directive parsed with the wrong scope"
  ensure (headerFacts.directives[0]!.scopeRange == ⟨0, src.utf8ByteSize⟩)
      "the header ignore-file scope is not the whole file"
  ensure headerFacts.malformed.isEmpty "a well-formed header directive was flagged malformed"
  -- A malformed header directive is reported (FMT901, display-only), never silently dropped.
  let badSrc := "module\n-- lean-fmt: nope\ndef x := 1\n"
  let badFacts := Suppression.collect (mkProj badSrc 25) badSrc
  ensure (badFacts.directives.isEmpty && badFacts.malformed.map (·.code) == #["FMT901"])
      "a malformed header directive was not reported as FMT901"
  ensure (badFacts.malformed[0]!.fix?.map (·.applicability) == some .displayOnly)
      "the FMT901 fix is not display-only"

/-- Attribution's one lookup: which command owns a source offset.

This decides whether a validation failure is degraded or refused, so its *partiality* is the point.
The units tile `[headerStop, terminalStop)` and nothing else, and an offset outside that -- a header
gate, a terminal-tail gate -- has to come back `none`, because that is the whole of what makes a
failure no command owns still take the file down. -/
private def testCommandOf : IO Unit := do
  -- Three commands over a file whose header ends at 10 and whose terminal tail starts at 40.
  let units : Array SourceRange := #[⟨10, 20⟩, ⟨20, 33⟩, ⟨33, 40⟩]
  ensureEq "the header is not a command" none (commandOf? units 0)
  ensureEq "the byte before the first command is not a command" none (commandOf? units 9)
  ensureEq "a unit's first byte" (some 0) (commandOf? units 10)
  ensureEq "a unit's last byte" (some 0) (commandOf? units 19)
  -- The bound is half-open on both sides, so the byte a unit ends on belongs to the next one and to
  -- no other. An inclusive stop would attribute every boundary byte twice.
  ensureEq "a unit's stop belongs to the next unit" (some 1) (commandOf? units 20)
  ensureEq "the last unit's last byte" (some 2) (commandOf? units 39)
  ensureEq "the terminal tail is not a command" none (commandOf? units 40)
  ensureEq "past the end of the file" none (commandOf? units 4096)
  ensureEq "a file with no commands owns no offset" none (commandOf? #[] 10)

/-- The other half of attribution: which source offset a node divergence is at.

A node count mismatch is the one structural failure whose own node usually carries no range -- it
lands on an empty optional slot -- so reading `nodes[index].range.start` yields `0`, which
`testCommandOf` above proves is unattributable. That combination silently disabled the retry on
every count mismatch, and the two functions only compose because this one walks back to a node that
has a position. -/
private def testNodeDivergenceSource : IO Unit := do
  let source := fixtureLosslessSource
  let siteOf (nodes : Array Node) (index : Nat) : Option Nat :=
    Validator.nodeDivergenceSource? { source with nodes := nodes } index
  -- Kinds and parents are not read here; only the ranges are.
  let nodes : Array Node :=
    #[{ kind := 0, range := ⟨0, 64⟩ }, { kind := 0, range := ⟨10, 30⟩ },
      { kind := 0, range := ⟨0, 0⟩ }, { kind := 0, range := ⟨0, 0⟩ },
      { kind := 0, range := ⟨40, 52⟩ }]
  ensureEq "a node that carries a range names itself" (some 10) (siteOf nodes 1)
  ensureEq "an empty slot takes the nearest earlier positioned node" (some 10) (siteOf nodes 2)
  ensureEq "a run of empty slots walks back past all of them" (some 10) (siteOf nodes 3)
  ensureEq "the walk stops at the first positioned node, not the outermost" (some 40)
      (siteOf nodes 4)
  -- Nothing earlier carries a position, so there is no source site to name and the failure is
  -- unattributable -- a refusal, which is what the pre-Stage-2 behaviour was for every mismatch.
  ensureEq "an empty slot with no positioned predecessor" none
      (siteOf #[{ kind := 0, range := ⟨0, 0⟩ }, { kind := 0, range := ⟨0, 0⟩ }] 1)
  ensureEq "no enumeration at all" none (siteOf #[] 0)

/-- Which source offsets a set of divergent output rows blames, for the second render's gate.

The caller degrades one command per round against a bound of two rounds, so naming only the first
divergent row costs a round per extra command:
`Mathlib/RepresentationTheory/Homological/GroupHomology/Functoriality.lean` moved three commands on
its second render, needed three rounds, and refused against a bound of two. Reporting the set
converges it in one.

Two properties carry that, and both are here. Rows inside one command collapse to one offset -- a
command is degraded once however many of its rows moved -- and the walk is a merge over two ascending
sequences rather than a map scan per row, because a draft that shifts wholesale diverges on every row
it has. -/
private def testIdempotenceSources : IO Unit := do
  -- Seven rows of four rendered bytes each ("abc\n"), so row `i` starts at output byte `4 * i`.
  -- Three commands own two rows apiece; row 6 is past all of them.
  let rows := List.replicate 7 "abc"
  let marks : Array Mark :=
    #[{ source := ⟨0, 10⟩, output := ⟨0, 8⟩ }, { source := ⟨10, 25⟩, output := ⟨8, 16⟩ },
      { source := ⟨25, 40⟩, output := ⟨16, 24⟩ }]
  let sourcesOf (divergent : List Nat) := Validator.idempotenceSources marks rows divergent
  ensureEq "one row names the command that produced it" #[10] (sourcesOf [2])
  ensureEq "rows in three commands name all three" #[0, 10, 25] (sourcesOf [0, 2, 4])
  -- Rows 2 and 3 are both inside mark 1. A caller that saw `#[10, 10]` would count one degradation
  -- as two and burn a retry on a command it had already forced.
  ensureEq "two rows in one command name it once" #[10] (sourcesOf [2, 3])
  ensureEq "no divergence names nothing" #[] (sourcesOf [])
  -- The map tiles the *output*, and a row past its end belongs to no command -- the verbatim tail is
  -- the usual reason. Blaming the last command for it would degrade something that did not move.
  ensureEq "a row past the map's end is unattributable" #[0] (sourcesOf [0, 6])
  -- Rows and divergent indices come from the same comparison, so an index with no row is a caller
  -- bug rather than a shape; it is skipped rather than shifting every later row onto a wrong mark.
  ensureEq "an index with no row is skipped" #[0] (sourcesOf [0, 99])

/-- Where a token's leading trivia begins, when the parser's own bookkeeping left a hole.

The projection's tiling invariant is what makes it lossless, and a file that breaks it is refused
outright before anything is formatted. `hygieneInfoFn` breaks it on ordinary mathlib source by
stealing an already-pushed leaf's trailing whitespace and then being backtracked, which strands a
byte on no leaf at all. Deriving the leading run from contiguity closes that hole; these cases pin
that it closes *only* that hole, because widening the run any further would hand a token bytes the
previous one already spelled. -/
private def testLeadingStart : IO Unit := do
  let recorded : String.Pos.Raw := ⟨64⟩
  let startOf (previous? : Option Token) : Nat :=
    (LosslessSource.leadingStart previous? recorded).byteIdx
  -- The parser is well behaved: it spelled the gap on the previous token's trailing run, so the
  -- cursor already is this token's own start and the derived run is empty, exactly as before.
  ensureEq "a contiguous predecessor changes nothing" 64
      (startOf (some { node := 0, start := 50, stop := 60, trailing := #[⟨.whitespace, 64⟩] }))
  -- The defect: `have`'s trailing run was truncated to nothing, so one byte belongs to no leaf.
  ensureEq "a truncated predecessor's stolen bytes are reclaimed" 60
      (startOf (some { node := 0, start := 50, stop := 60 }))
  -- The first token in the file has no predecessor; its recorded start is the header stop, which is
  -- a position both producers can see and the only one available here.
  ensureEq "no predecessor keeps the parser's answer" 64 (startOf none)
  -- Never widen past what the parser recorded. A predecessor whose trailing run already runs past
  -- this token's start is an overlap, and reading it as a leading start would spell those bytes
  -- twice; the overlap stays visible to `validationError?` instead.
  ensureEq "an overrunning predecessor is not trusted" 64
      (startOf (some { node := 0, start := 50, stop := 60, trailing := #[⟨.whitespace, 70⟩] }))
  -- A predecessor the projection will reject anyway carries no usable cursor: a `.missing` leaf
  -- sits at 0, and scanning from there would read the whole file as this token's leading trivia.
  ensureEq "a leaf with no original position is not a cursor" 64
      (startOf (some { node := 0, start := 0, stop := 0, info := .missing }))

/-- The cases this module contributes to the unit runner, in run order. -/
public def cases : Array Case :=
  #[{ name := "testLosslessSource", run := testLosslessSource },
    { name := "testRangeSelection", run := testRangeSelection },
    { name := "testCommandOf", run := testCommandOf },
    { name := "testNodeDivergenceSource", run := testNodeDivergenceSource },
    { name := "testIdempotenceSources", run := testIdempotenceSources },
    { name := "testLeadingStart", run := testLeadingStart },
    { name := "testSuppression", run := testSuppression }]

end LeanFmt.Test.Unit.Source
