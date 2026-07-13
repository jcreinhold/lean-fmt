import Lean

/-!
# LeanFmt.Protocol

The Lean side of the versioned **edit protocol**: JSON constructors for the formatter
diagnostics and edits that Lean-side (syntax-tree) rules will emit back across the worker
boundary, in the exact wire shape the Rust `lean-fmt-edit` crate decodes.

Byte offsets are the currency (`{ "start", "end" }` half-open ranges), matching
`LeanFmt.Source`. The schema is versioned by `LeanFmt.Protocol.schema`, which must equal
the Rust `lean_fmt_edit::SCHEMA` constant; a mismatch is how the two sides detect drift.

An edit carries the `expected` source text at its range so the Rust patch engine can
reject a stale edit rather than rewrite the wrong bytes; a diagnostic optionally carries a
`fix` edit set. This module only *builds* the JSON — sorting, conflict/staleness checking,
and application all live on the Rust side that owns patching.
-/

namespace LeanFmt.Protocol

open Lean

/-- The edit-protocol schema version. Must match Rust `lean_fmt_edit::SCHEMA`. -/
def schema : String := "lean-fmt.edit.v1"

/-- A half-open byte range `{ "start", "end" }`. -/
def rangeJson (startByte endByte : Nat) : Json :=
  Json.mkObj [("start", toJson startByte), ("end", toJson endByte)]

/-- A `TextEdit`: replace `[startByte, endByte)` — which currently holds `expected` — with
    `newText`. An insertion uses `startByte = endByte` and `expected = ""`. -/
def textEditJson (startByte endByte : Nat) (expected newText : String) : Json :=
  Json.mkObj
    [ ("range", rangeJson startByte endByte)
    , ("expected", Json.str expected)
    , ("new_text", Json.str newText) ]

/-- An `EditSet`: a bundle of edits applied together. -/
def editSetJson (edits : Array Json) : Json :=
  Json.mkObj [("edits", Json.arr edits)]

/-- A `Diagnostic`: a rule finding at a byte range, with an optional `fix` edit set.
    `applicability` is one of `"safe"`, `"unsafe"`, `"display_only"` (the Rust
    `Applicability` snake-case encoding). The `fix` key is omitted when there is none. -/
def diagnosticJson (rule message : String) (startByte endByte : Nat)
    (applicability : String) (fix : Option Json) : Json :=
  let base :=
    [ ("rule", Json.str rule)
    , ("message", Json.str message)
    , ("range", rangeJson startByte endByte)
    , ("applicability", Json.str applicability) ]
  let withFix := match fix with
    | some f => base ++ [("fix", f)]
    | none => base
  Json.mkObj withFix

/-- The diagnostics response envelope: the schema version plus the findings. This is the
    shape a future `lean_fmt_diagnostics` command returns and Rust decodes. -/
def diagnosticsJson (diagnostics : Array Json) : Json :=
  Json.mkObj [("schema", Json.str schema), ("diagnostics", Json.arr diagnostics)]

end LeanFmt.Protocol
