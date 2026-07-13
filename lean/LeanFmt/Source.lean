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

end LeanFmt.Source
