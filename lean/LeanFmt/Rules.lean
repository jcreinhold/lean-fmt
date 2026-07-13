import Lean

/-!
# LeanFmt.Rules

The Lean-side mirror of the Rust rule registry (`lean_fmt_diagnostics`). Lean-side
(syntax-tree) rules emit diagnostics tagged with a `rule` id; those ids must be exactly
the stable strings the Rust registry owns, or selection and reporting would disagree
across the worker boundary.

This module holds only the id constants and their ordered list — the single Lean-visible
copy of the identities. The ids are hand-assigned `category/slug` strings; they are never
derived from display text, so renaming a summary can never renumber a rule. A cross-side
Rust test decodes [`allRuleIdsJson`] and asserts it equals `lean_fmt_diagnostics`'s
`all_rule_ids()`. Rule *logic* (what each rule flags) lands in later prompts.
-/

namespace LeanFmt.Rules

open Lean

/-- Trailing whitespace at end of line. -/
def textTrailingWhitespace : String := "text/trailing-whitespace"

/-- File ends with exactly one trailing newline. -/
def textFinalNewline : String := "text/final-newline"

/-- Import statements are sorted and deduplicated. -/
def importsSorted : String := "imports/sorted"

/-- Excess consecutive blank lines between commands. -/
def layoutBlankLines : String := "layout/blank-lines"

/-- A bare `end` closing a named block carries the block's name. -/
def layoutEndName : String := "layout/end-name"

/-- Spacing around declaration headers and binders. -/
def declarationHeaderSpacing : String := "declaration/header-spacing"

/-- Tactic block indentation is consistent. -/
def tacticBlockIndent : String := "tactic/block-indent"

/-- Formatting never drops or reorders comments. -/
def safetyPreserveComments : String := "safety/preserve-comments"

/-- File exceeds the size where formatting is skipped by default. -/
def performanceLargeFile : String := "performance/large-file"

/-- Every rule id, in the same order as the Rust registry. -/
def allRuleIds : List String :=
  [ textTrailingWhitespace
  , textFinalNewline
  , importsSorted
  , layoutBlankLines
  , layoutEndName
  , declarationHeaderSpacing
  , tacticBlockIndent
  , safetyPreserveComments
  , performanceLargeFile ]

/-- The rule id list as a JSON array of strings, for the cross-side identity check. -/
def allRuleIdsJson : Json :=
  Json.arr (allRuleIds.map Json.str).toArray

end LeanFmt.Rules
