/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Comments
import all LeanFmt.Doc

import Lean.PrettyPrinter

/-! The actual-syntax adapter for Lean's registered formatter.

This module deliberately pins a small portion of Lean's pretty-printer API. `formatCategory` runs
`categoryFormatter`, which asks `formatterAttribute` for an explicit formatter before deriving one
from a `ParserDescr`; both run against the supplied syntax traverser under the current `CoreM`
environment and options. `formatCategory` also obtains the current environment's token table.

The returned `Std.Format` stays one opaque `Doc.registered` leaf. This module never copies its tree,
renders it early, reparses text, or substitutes source bytes on failure.

Lean's formatter emits comments from `SourceInfo` in `pushToken`, and it is the sole emitter here:
comment ownership does logical accounting, not a second copy. Boundary trivia may be stored on the
preceding command even when its logical owner is in the next command, so ordered whole-module
composition — not an isolated leaf's count — is the exact-once boundary. The focused adapter fixture
is the upgrade tripwire for these private implementation assumptions. -/

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

/-- A registry failure. There is still no source-text fallback *constructor*: a formatter reports
what it could not lay out and never substitutes bytes for a layout, because whether a hole in the
output is acceptable is a decision about the file, which the formatter cannot see. -/
structure FormatterFailure where
  category : FormatterCategory
  kind : Lean.Name
  range : SourceRange
  trace : FormatterTrace
  detail : String
  /-- Whether this syntax's own source bytes would be an admissible substitute for the layout that
  failed: the bytes reparse and re-elaborate to exactly what the file already held, so every gate
  downstream still holds over them and only the layout is lost.

  Evidence, not a decision. The caller is what knows whether it may spend a hole in the output --
  `LEAN_FMT_STRICT_LAYOUT=1` says it may not, and a caller with no range to slice cannot anyway.
  False is the safe default and the answer for every failure that is a defect rather than a gap in
  the toolchain's printer. -/
  verbatimAdmissible : Bool := false
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One successful registry call. `document` contains exactly one opaque native leaf; across an
ordered module, native formatter leaves are the sole comment emitters. -/
structure RegisteredDocument where
  document : Doc
  trace : FormatterTrace
  deriving Inhabited

/-- Deterministic whole-module formatter counters. A draft is produced by one already-running
frontend and contains no live frontend object. -/
structure FormatMetrics where
  frontendRuns : Nat
  commands : Nat
  nativeDocuments : Nat
  alignedTokens : Nat
  nativeCommentLeaves : Nat
  normalizedTokens : Nat
  exactIslands : Nat
  exactIslandBytes : Nat
  /-- Commands emitted as their own source bytes because the toolchain's formatter could not lay
  them out. See `NativeLayout.command`. -/
  verbatimCommands : Nat
  offsideConstraints : Nat
  commentConstraints : Nat
  registryNodes : Nat
  explicitDocuments : Nat
  descriptorDocuments : Nat
  commentOwners : Nat
  documentNodes : Nat
  renderSteps : Nat
  nativeEvents : Nat
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Unvalidated whole-module rendering. `Validator.admit` is the only operation allowed to accept one
as a canonical layout. -/
structure FormatDraft where
  text : String
  sourceMap : Array Mark
  headerContract : Array String
  commentContract : Array CommentContractEntry
  metrics : FormatMetrics
  sourceDigest : String
  sourceBytes : Nat
  headerStop : Nat
  terminalStop : Nat
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

namespace Formatter

private def sourceRange (stx : Lean.Syntax) : SourceRange :=
  match stx.getRange? with
  | some range => ⟨range.start.byteIdx, range.stop.byteIdx⟩
  | none => ⟨0, 0⟩

private def resolution (kind : Lean.Name) : Lean.CoreM FormatterResolution := do
  let registrations :=
    Lean.PrettyPrinter.formatterAttribute.getValues (← Lean.getEnv) kind |>.length
  return if registrations == 0 then .descriptor else .explicit registrations

/-- Record how the registry resolves a syntax root without invoking its formatter. The one caller
that builds a document itself — the module header, parsed before any environment exists — uses this
so its trace cannot be confused with a registry execution. -/
def trace (ownership : CommentOwnership) (category : FormatterCategory) (stx : Lean.Syntax) :
    Lean.CoreM FormatterTrace := do
  let kind := stx.getKind
  return {
      category
      kind
      resolution := ← resolution kind
      commentOwners := (Comments.subtree ownership stx).size }

/-- Resolve and run Lean's formatter registry against `stx` in the current frontend context. Errors
remain typed refusals and never become verbatim output. -/
def registeredAs (ownership : CommentOwnership) (category : FormatterCategory)
    (traceSyntax formatSyntax : Lean.Syntax) :
    Lean.CoreM (Except FormatterFailure RegisteredDocument) := do
  let kind := traceSyntax.getKind
  let trace ← trace ownership category traceSyntax
  try
    let native ← Lean.PrettyPrinter.formatCategory category.name formatSyntax
    return .ok { document := Doc.registered native, trace }
  catch exception =>
    let detail ← exception.toMessageData.toString
    return .error
        { category
          kind
          range := sourceRange traceSyntax
          trace
          detail }

private def stripBoundaryInfo (start stop : Nat) : Lean.SourceInfo → Lean.SourceInfo
  | .original leading position trailing endPos =>
    let leading :=
      if leading.startPos.byteIdx < start then { leading with stopPos := leading.startPos }
      else leading
    let trailing :=
      if stop < trailing.stopPos.byteIdx then { trailing with stopPos := trailing.startPos }
      else trailing
    .original leading position trailing endPos
  | info => info

private partial def stripBoundaryTriviaFrom (start stop : Nat) : Lean.Syntax → Lean.Syntax
  | .node info kind children =>
    .node (stripBoundaryInfo start stop info) kind
      (children.map (stripBoundaryTriviaFrom start stop))
  | .atom info value => .atom (stripBoundaryInfo start stop info) value
  | .ident info raw value preresolved =>
    .ident (stripBoundaryInfo start stop info) raw value preresolved
  | .missing => .missing

/-- Remove trivia outside a syntax root while retaining every comment between its first and last
token. Structural parents own that boundary trivia; an opaque registered leaf owns only its interior. -/
def withoutBoundaryTrivia (stx : Lean.Syntax) : Lean.Syntax :=
  let start := stx.getRange?.map (·.start.byteIdx) |>.getD 0
  let stop := stx.getRange?.map (·.stop.byteIdx) |>.getD start
  stripBoundaryTriviaFrom start stop stx

end Formatter

end LeanFmt.Internal
