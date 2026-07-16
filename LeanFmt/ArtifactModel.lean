module

import all LeanFmt.LosslessSource
import Lean

namespace LeanFmt.Internal

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

/- The artifact is stored inside the successful module's `.olean`; exact toolchain, options,
plugins, ordered imports, and dependency identity therefore belong to the module artifact itself
rather than to a parallel cache identity.

`source` carries both the projection and the artifact's whole identity. There is no second module
name or source digest beside it: a duplicate identity is one that can disagree with itself, and
`findings` index the same normalized string `source` does. -/
structure ModuleArtifact where
  schema : String
  trailingWhitespace : Bool
  source : LosslessSource
  findings : Array Finding
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Bumped from `v1` when the command-kind/range projection became `LosslessSource`. A `v1` payload
left in an `.olean` or a facet output describes a different shape and must miss, not decode. -/
def artifactSchema : String := "lean-fmt.module-artifact.v2"

def artifactLinter : Lean.Name := `leanFmt.semanticArtifact

end LeanFmt.Internal
