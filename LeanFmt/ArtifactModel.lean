module

import all LeanFmt.Digest
import Lean

namespace LeanFmt.Internal

/-- Half-open UTF-8 byte range in the exact source snapshot. -/
structure SourceRange where
  start : Nat
  stop : Nat
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- A conservative replacement. Applying edits is deliberately not part of the compiler plugin. -/
structure Edit where
  range : SourceRange
  replacement : String
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

inductive Severity where
  | information
  | warning
  | error
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- A rule result computed while Lean owns the exact frontend environment. -/
structure Finding where
  code : String
  severity : Severity
  message : String
  range : SourceRange
  fix? : Option Edit := none
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- The compact syntax projection needed by current rules, not a serialized Lean syntax tree. -/
structure CommandShape where
  kind : String
  range? : Option SourceRange
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/- The artifact is stored inside the successful module's `.olean`; exact toolchain, options,
plugins, ordered imports, and dependency identity therefore belong to the module artifact itself
rather than to a parallel cache identity. -/
structure ModuleArtifact where
  schema : String
  source : Digest
  sourceBytes : Nat
  mainModule : String
  trailingWhitespace : Bool
  commands : Array CommandShape
  findings : Array Finding
  deriving BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

def artifactSchema : String := "lean-fmt.module-artifact.v1"

def artifactLinter : Lean.Name := `leanFmt.semanticArtifact

end LeanFmt.Internal
