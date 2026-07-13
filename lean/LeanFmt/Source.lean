import Lean

/-!
# LeanFmt.Source

The byte-accurate coordinate and span substrate for the formatter. Every source
location the worker reports is anchored to a **byte range** (`String.Pos` offsets into
the UTF-8 source), and the human-facing line/column is derived from Lean's own
`FileMap` — never recomputed by hand — so column counting stays codepoint-based and
identical to the compiler's.

Lean's `Position` is 1-based in `line` and 0-based in `column`, where a column counts
Unicode codepoints from the start of the line (not bytes). This module preserves that
convention verbatim: consumers that want byte offsets read `range.start`/`range.end`,
and consumers that want display coordinates read the `line_column` pair. The Rust
`lean-fmt-edit` `SourceMap` reproduces the same codepoint-based counting so the two
sides agree on every position.

The public surface is one function, `commandRegion`, that turns a parsed command's
`Syntax` into a JSON `SyntaxRegion`:

```json
{ "kind": "Lean.Parser.Command.declaration",
  "range": { "start": 13, "end": 32 },
  "line_column": { "start": { "line": 3, "column": 0 },
                   "end":   { "line": 3, "column": 18 } } }
```

A synthetic node with no source position yields `none` (no zero-width region), matching
the stop rule "every span must carry a byte range."
-/

namespace LeanFmt.Source

open Lean

/-- Render a `String.Pos.Raw` byte offset as a JSON number. -/
private def posJson (p : String.Pos.Raw) : Json :=
  toJson p.byteIdx

/-- Render a `FileMap`-derived `Position` as `{ "line", "column" }` (1-based line,
    0-based codepoint column, exactly as Lean reports it). -/
private def positionJson (p : Position) : Json :=
  Json.mkObj [("line", toJson p.line), ("column", toJson p.column)]

/-- A byte `TextRange`: `{ "start", "end" }` half-open `String.Pos` offsets. -/
def textRangeJson (r : Syntax.Range) : Json :=
  Json.mkObj [("start", posJson r.start), ("end", posJson r.stop)]

/-- The `line_column` display range for a byte range, computed through the `FileMap`. -/
def lineColumnRangeJson (fileMap : FileMap) (r : Syntax.Range) : Json :=
  Json.mkObj
    [ ("start", positionJson (fileMap.toPosition r.start))
    , ("end", positionJson (fileMap.toPosition r.stop)) ]

/-- Extract the `SyntaxRegion` JSON for a parsed command: its kind plus a byte
    `range` and the derived `line_column` display range. Returns `none` for a node
    without a source position (a synthetic node), so every emitted region carries a
    real byte range. -/
def commandRegion (fileMap : FileMap) (stx : Syntax) : Option Json :=
  match stx.getRange? with
  | some r =>
    some <| Json.mkObj
      [ ("kind", Json.str stx.getKind.toString)
      , ("range", textRangeJson r)
      , ("line_column", lineColumnRangeJson fileMap r) ]
  | none => none

/-!
## Trivia model

Comments and blank lines survive parsing as `SourceInfo` trivia (the `leading`/
`trailing` substrings of `SourceInfo.original`), not as syntax nodes, and every source
byte is either inside a parsed **token** (an atom/ident with `original` info) or inside
that inter-token trivia. Rather than ship every token, this module ships the **trivia
runs** — the maximal byte ranges *between* tokens — which are exactly the complement of
the token spans. The `lean-fmt-edit` crate then classifies each run's text into line
comments, block comments, blank-line clusters, and whitespace, and checks that the
classification tiles the run losslessly. Because a run is the gap between two tokens, a
run attaches to the token ending at its start (Lean's trailing-trivia convention).

Docstrings are the exception: `/-- … -/` and `/-! … -/` parse to `docComment` **nodes**
(their bytes are token spans, not trivia), so they are reported separately.
-/

/-- Collect the byte spans `(startByte, endByte)` of every parsed token (atom/ident
    carrying `original` source info) under `stx`, in no particular order. Synthetic
    tokens contribute nothing (they occupy no source bytes). -/
partial def tokenSpans (stx : Syntax) (acc : Array (Nat × Nat) := #[]) : Array (Nat × Nat) :=
  let push (info : SourceInfo) (a : Array (Nat × Nat)) : Array (Nat × Nat) :=
    match info with
    | .original _ pos _ endPos => a.push (pos.byteIdx, endPos.byteIdx)
    | _ => a
  match stx with
  | .atom info _ => push info acc
  | .ident info .. => push info acc
  | .node _ _ args => args.foldl (fun a s => tokenSpans s a) acc
  | .missing => acc

/-- The trivia runs: maximal `[start, end)` byte ranges that lie *between* tokens (the
    complement of `spans` within `[0, byteSize)`), emitted as `{ "start", "end" }`
    objects in source order. Overlapping/adjacent tokens are absorbed, so the result is
    always disjoint and ordered. -/
def triviaRunsJson (byteSize : Nat) (spans : Array (Nat × Nat)) : Array Json := Id.run do
  let sorted := spans.qsort (fun a b => a.1 < b.1)
  let mut runs : Array Json := #[]
  let mut cursor : Nat := 0
  for (s, e) in sorted do
    if s > cursor then
      runs := runs.push (Json.mkObj [("start", toJson cursor), ("end", toJson s)])
    cursor := max cursor e
  if cursor < byteSize then
    runs := runs.push (Json.mkObj [("start", toJson cursor), ("end", toJson byteSize)])
  return runs

/-- Collect one record per `import` statement under `stx`: its `module` name and the
    byte `range` of the whole statement — the `import` keyword through the module ident,
    including any `meta`/`runtime`/`public` modifiers (they are children of the node, so
    the node range spans them). The leading comment/blank-line trivia *before* an import
    is deliberately excluded from the range; the Rust import rule recovers comment
    attachment from the source text and the trivia runs. Emitted in source order. -/
partial def importSpans (stx : Syntax) (acc : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind args =>
    let acc :=
      if kind == ``Lean.Parser.Module.import then
        match stx.getRange? with
        | some r =>
          let moduleName :=
            (args.findSome? fun a => if a.isIdent then some a.getId.toString else none).getD ""
          acc.push (Json.mkObj [("module", Json.str moduleName), ("range", textRangeJson r)])
        | none => acc
      else acc
    args.foldl (fun a s => importSpans s a) acc
  | _ => acc

/-!
## Declaration header spans

A rule that normalizes spacing around a declaration header (the gap after the kind
keyword, around the return-type `:`, around `:=`/`where`, and between binders) needs the
byte positions of those *specific* delimiter tokens — information the whole-command
region and the inter-token trivia runs do not carry. `declHeaderSpans` walks each parsed
`Lean.Parser.Command.declaration` and emits one record per declaration naming the byte
range of each header role, recovered **purely from the parse tree** (no elaboration):

```json
{ "kind": "Lean.Parser.Command.definition",
  "range": { "start": 0, "end": 26 },
  "keyword": { "start": 0, "end": 3 },
  "name": { "start": 4, "end": 5 },
  "binders": [ { "range": {…}, "open": {…}, "close": {…}, "colon": {…} } ],
  "sig_colon": { "start": 16, "end": 17 },
  "assign": { "start": 22, "end": 24 } }
```

Optional roles (`name`, `sig_colon`, `assign`, `where`, a binder `colon`) are omitted
when the parse tree has no such token — an `example` has no name, a `structure` has no
`:=`, an `instBinder` has no `:` — so a consumer never sees a zero-width or guessed span.
-/

/-- The byte range of the first `atom` under `stx` in pre-order, if any (identifiers are
    skipped). Used for the kind keyword and a binder's opening delimiter. -/
partial def firstAtomRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .atom .. => stx.getRange?
  | .node _ _ args => args.findSome? firstAtomRange?
  | _ => none

/-- The byte range of the last `atom` under `stx` in pre-order, if any. Used for a
    binder's closing delimiter. -/
partial def lastAtomRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .atom .. => stx.getRange?
  | .node _ _ args => args.foldl (fun acc a => (lastAtomRange? a).orElse (fun _ => acc)) none
  | _ => none

/-- The byte range of the first `ident` under `stx` in pre-order, if any. Used for the
    declaration name inside `declId`. -/
partial def firstIdentRange? (stx : Syntax) : Option Syntax.Range :=
  match stx with
  | .ident .. => stx.getRange?
  | .node _ _ args => args.findSome? firstIdentRange?
  | _ => none

/-- The byte range of the first `atom` under `stx` whose text equals `val`, in pre-order.
    Used to locate the binder `:` separator (the first `:` precedes the type, so
    first-occurrence is the separator even if the type itself contained a colon). -/
partial def atomRangeWithVal? (stx : Syntax) (val : String) : Option Syntax.Range :=
  match stx with
  | .atom _ v => if v == val then stx.getRange? else none
  | .node _ _ args => args.findSome? (atomRangeWithVal? · val)
  | _ => none

/-- The first `node` under `stx` (including `stx`) whose kind is `kind`, in pre-order. -/
partial def nodeWithKind? (stx : Syntax) (kind : Name) : Option Syntax :=
  match stx with
  | .node _ k args =>
    if k == kind then some stx
    else args.findSome? (nodeWithKind? · kind)
  | _ => none

/-- Emit the `binders` array for one declaration's kind node: one record per
    `Term.{explicit,implicit,strictImplicit,inst}Binder`, in source order, each carrying
    the whole-binder `range`, its `open`/`close` delimiter atoms, and the `colon`
    separator when present (absent for an `instBinder` like `[Add α]`). Does not descend
    into a binder once matched. -/
partial def binderRecords (stx : Syntax) (acc : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind args =>
    if kind == ``Lean.Parser.Term.explicitBinder || kind == ``Lean.Parser.Term.implicitBinder
        || kind == ``Lean.Parser.Term.strictImplicitBinder || kind == ``Lean.Parser.Term.instBinder then
      match stx.getRange? with
      | some r =>
        let fields : List (String × Json) :=
          [("range", textRangeJson r)]
            ++ (match firstAtomRange? stx with | some a => [("open", textRangeJson a)] | none => [])
            ++ (match lastAtomRange? stx with | some a => [("close", textRangeJson a)] | none => [])
            ++ (match atomRangeWithVal? stx ":" with | some a => [("colon", textRangeJson a)] | none => [])
        acc.push (Json.mkObj fields)
      | none => acc
    else
      args.foldl (fun a s => binderRecords s a) acc
  | _ => acc

/-- Collect one header record per top-level `Command.declaration` under `stx`. The kind
    node is the declaration's non-`declModifiers` child (`Command.definition`,
    `Command.theorem`, `Command.structure`, …); each header role is read from it by node
    kind or atom text. Non-declaration commands contribute nothing. Emitted in source
    order. -/
partial def declHeaderSpans (stx : Syntax) (acc : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind args =>
    if kind == ``Lean.Parser.Command.declaration then
      -- The kind node is the child that is not the (possibly synthetic) declModifiers.
      match args.find? (fun a => a.getKind != ``Lean.Parser.Command.declModifiers) with
      | some declKind =>
        match declKind.getRange? with
        | some r =>
          -- The signature node holds the header binders and the return-type `:` only;
          -- scoping binders/`sig_colon` to it keeps a `structure` field's `:` or a value
          -- lambda's binder out of the header roles (the role-ambiguity stop-rule).
          let sigNode? :=
            (nodeWithKind? declKind ``Lean.Parser.Command.optDeclSig).orElse fun _ =>
              nodeWithKind? declKind ``Lean.Parser.Command.declSig
          let binders := match sigNode? with | some s => binderRecords s | none => #[]
          let name? := (nodeWithKind? declKind ``Lean.Parser.Command.declId).bind firstIdentRange?
          let sigColon? := sigNode?.bind fun s =>
            (nodeWithKind? s ``Lean.Parser.Term.typeSpec).bind firstAtomRange?
          let assign? := (nodeWithKind? declKind ``Lean.Parser.Command.declValSimple).bind firstAtomRange?
          let where? := atomRangeWithVal? declKind "where"
          let fields : List (String × Json) :=
            [ ("kind", Json.str declKind.getKind.toString)
            , ("range", textRangeJson r) ]
              ++ (match firstAtomRange? declKind with | some a => [("keyword", textRangeJson a)] | none => [])
              ++ (match name? with | some a => [("name", textRangeJson a)] | none => [])
              ++ [("binders", Json.arr binders)]
              ++ (match sigColon? with | some a => [("sig_colon", textRangeJson a)] | none => [])
              ++ (match assign? with | some a => [("assign", textRangeJson a)] | none => [])
              ++ (match where? with | some a => [("where", textRangeJson a)] | none => [])
          acc.push (Json.mkObj fields)
        | none => acc
      | none => acc
    else
      args.foldl (fun a s => declHeaderSpans s a) acc
  | _ => acc

/-!
## Tactic block spans

A rule that normalizes the *intra-line* spacing inside a `by` block (the gap after `by`
for a same-line tactic, and the gap after a `·`/`case` bullet marker) needs the byte
positions of those anchors — not the whole-command region and not the inter-token trivia
runs. `tacticBlockSpans` walks every `Lean.Parser.Term.byTactic` and emits one record per
block, recovered **purely from the parse tree** (no elaboration):

```json
{ "by": { "start": 18, "end": 20 },
  "seq": { "start": 23, "end": 40 },
  "base_column": 2,
  "first_step": { "start": 23, "end": 34 },
  "bullets": [ { "kind": "cdot", "range": { "start": 54, "end": 56 } } ] }
```

`by` (always present) is the `by` atom. `seq` is the enclosing `Tactic.tacticSeq` range;
it is **absent** when the sequence parsed synthetically (an unrecognized tactic token
collapses the sequence — the token-table-dependent degradation), in which case
`base_column`/`first_step` are absent and `bullets` is empty: a consumer never sees a
wrong or zero-width span. `base_column` is the 0-based codepoint column of the sequence
start (the block's indentation), so the rule can tell a leading-indentation gap from an
intra-line one. `first_step` is the first top-level tactic step (for the `by`→step gap).
`bullets` are every `·` (`cdotTk`) and `case` marker atom in the block, at any nesting
depth, so the rule can normalize the space after each marker.
-/

/-- Every `·` (`Lean.cdotTk`) and `case` (`Tactic.case`) marker atom under `stx`, as
    `{ "kind": "cdot"|"case", "range": {…} }` in source order. Does **not** descend into a
    nested `by` block — that block gets its own record — so a marker is reported exactly
    once by the innermost enclosing block. -/
partial def bulletMarkers (stx : Syntax) (acc : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind args =>
    if kind == ``Lean.Parser.Term.byTactic then acc
    else
      let acc :=
        if kind == ``Lean.cdotTk then
          match stx.getRange? with
          | some r => acc.push (Json.mkObj [("kind", Json.str "cdot"), ("range", textRangeJson r)])
          | none => acc
        else if kind == ``Lean.Parser.Tactic.case then
          match atomRangeWithVal? stx "case" with
          | some r => acc.push (Json.mkObj [("kind", Json.str "case"), ("range", textRangeJson r)])
          | none => acc
        else acc
      args.foldl (fun a s => bulletMarkers s a) acc
  | _ => acc

/-- The byte range of the first top-level tactic step of a `Tactic.tacticSeq` — the first
    ranged **node** child of its `tacticSeq1Indented`'s step list (the `;`/newline
    separators are atoms, skipped). `none` for a synthetic or bracketed sequence. -/
def firstStepRange? (seqNode : Syntax) : Option Syntax.Range :=
  match nodeWithKind? seqNode ``Lean.Parser.Tactic.tacticSeq1Indented with
  | some indented =>
    (indented.getArgs.foldl (fun a nn => a ++ nn.getArgs) #[]).findSome? fun c =>
      match c with
      | .node .. => c.getRange?
      | _ => none
  | none => none

/-- Collect one record per `Term.byTactic` block under `stx`, in source order. Each record
    names the `by` atom, the enclosing `tacticSeq` range and its indentation column, the
    first top-level step, and every `·`/`case` marker — all recovered parse-only. A block
    whose sequence parsed synthetically emits just the `by` atom and an empty `bullets`
    array (never a wrong span). -/
partial def tacticBlockSpans (fileMap : FileMap) (stx : Syntax) (acc : Array Json := #[]) :
    Array Json :=
  match stx with
  | .node _ kind args =>
    let acc :=
      if kind == ``Lean.Parser.Term.byTactic then
        match firstAtomRange? stx with
        | some byR =>
          let seqNode? := nodeWithKind? stx ``Lean.Parser.Tactic.tacticSeq
          let seqRange? := seqNode?.bind (·.getRange?)
          let firstStep? := seqNode?.bind firstStepRange?
          let baseCol? := seqRange?.map fun r => (fileMap.toPosition r.start).column
          let bullets := match seqNode? with | some s => bulletMarkers s | none => #[]
          let fields : List (String × Json) :=
            [("by", textRangeJson byR)]
              ++ (match seqRange? with | some r => [("seq", textRangeJson r)] | none => [])
              ++ (match baseCol? with | some c => [("base_column", toJson c)] | none => [])
              ++ (match firstStep? with | some r => [("first_step", textRangeJson r)] | none => [])
              ++ [("bullets", Json.arr bullets)]
          acc.push (Json.mkObj fields)
        | none => acc
      else acc
    args.foldl (fun a s => tacticBlockSpans fileMap s a) acc
  | _ => acc

/-- Collect the byte ranges of `docComment` nodes (`/-- … -/`, `/-! … -/`) under `stx`
    as `{ "start", "end" }` objects. These are syntax, not trivia; they are reported so
    a downstream formatter can treat docstrings distinctly from ordinary comments. -/
partial def docCommentSpans (stx : Syntax) (acc : Array Json := #[]) : Array Json :=
  match stx with
  | .node _ kind args =>
    let acc :=
      if kind == ``Lean.Parser.Command.docComment then
        match stx.getRange? with
        | some r => acc.push (textRangeJson r)
        | none => acc
      else acc
    args.foldl (fun a s => docCommentSpans s a) acc
  | _ => acc

end LeanFmt.Source
