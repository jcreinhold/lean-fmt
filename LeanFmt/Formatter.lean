/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/- The actual-syntax adapter for Lean's registered formatter.

This module deliberately pins one small portion of Lean's pretty-printer API. `formatCategory` runs
`categoryFormatter`, which asks `formatterAttribute` for an explicit formatter before deriving one
from a `ParserDescr`; both run against the supplied syntax traverser under the current `CoreM`
environment and options. `formatCategory` also obtains the current environment's token table.

The returned `Std.Format` remains one opaque `Doc.registered` leaf. This module never copies its
tree, renders it early, reparses text, or substitutes source bytes on failure.

Lean's formatter emits comments from `SourceInfo` in `pushToken`. It is the sole emitter here:
Prompt 06 ownership is used for logical accounting, not to emit a second copy. Boundary trivia may
be stored on the preceding command even when its logical owner is in the next command, so ordered
whole-module composition—not an isolated leaf's count—is the exact-once boundary. The focused
adapter fixture is the upgrade tripwire for these private implementation assumptions. -/

import Lean.PrettyPrinter
import all LeanFmt.Comments
import all LeanFmt.Doc

namespace LeanFmt.Internal

/-- The parser category whose registered formatter must handle the actual syntax node. -/
inductive FormatterCategory where
  | command
  | term
  | tactic
  | named (name : Lean.Name)
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace FormatterCategory

def name : FormatterCategory → Lean.Name
  | .command => `command
  | .term => `term
  | .tactic => `tactic
  | .named value => value

end FormatterCategory

/-- How Lean resolved the outer syntax kind's formatter. Nested kinds resolve independently during
the same registry traversal. -/
inductive FormatterResolution where
  | explicit (registrations : Nat)
  | descriptor
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Compact evidence about the registry call, retained without exposing Lean's formatter closure. -/
structure FormatterTrace where
  category : FormatterCategory
  kind : Lean.Name
  resolution : FormatterResolution
  commentOwners : Nat
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- A hard registry failure. There is intentionally no source-text fallback constructor. -/
structure FormatterFailure where
  category : FormatterCategory
  kind : Lean.Name
  range : SourceRange
  trace : FormatterTrace
  detail : String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One successful registry call. `document` contains exactly one opaque native leaf; across an
ordered module, native formatter leaves are the sole comment emitters. -/
structure RegisteredDocument where
  document : Doc
  trace : FormatterTrace
  deriving Inhabited

namespace Formatter

private def sourceRange (stx : Lean.Syntax) : SourceRange :=
  match stx.getRange? with
  | some range => ⟨range.start.byteIdx, range.stop.byteIdx⟩
  | none => ⟨0, 0⟩

private def resolution (kind : Lean.Name) : Lean.CoreM FormatterResolution := do
  let registrations := Lean.PrettyPrinter.formatterAttribute.getValues (← Lean.getEnv) kind |>.length
  return if registrations == 0 then .descriptor else .explicit registrations

/-- Resolve and run Lean's formatter registry against `stx` in the current frontend context. Errors
remain typed refusals and never become verbatim output. -/
def registered (ownership : CommentOwnership) (category : FormatterCategory)
    (stx : Lean.Syntax) : Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  let kind := stx.getKind
  let trace : FormatterTrace := {
    category
    kind
    resolution := ← resolution kind
    commentOwners := (Comments.subtree ownership stx).size }
  try
    let native ← Lean.PrettyPrinter.formatCategory category.name stx
    return .ok { document := Doc.registered native, trace }
  catch exception =>
    let detail ← exception.toMessageData.toString
    return .error {
      category
      kind
      range := sourceRange stx
      trace
      detail }

end Formatter

end LeanFmt.Internal
