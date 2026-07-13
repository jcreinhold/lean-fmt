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
