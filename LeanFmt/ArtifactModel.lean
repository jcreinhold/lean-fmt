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

/-- What a rule concluded. Rules run outside the compiler, so this is never produced here; it is the
shape a finding takes in a report and in a fix. -/
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
name or source digest beside it: a duplicate identity is one that can disagree with itself.

**Facts, never findings.** This carries what a reader cannot recompute — the exact frontend's
projection — and nothing a reader could derive from bytes it already holds. It held `findings` and a
`trailingWhitespace` flag until `RRE-IMPL`; `notes/01-rule-facts.md` §6 has the argument and §2-3
have the two measured defects that made it. The short version is that a conclusion in here is a
second decider: `check` never reads an artifact, so it decided FMT001 for itself and disagreed. The
long version is that the rules were in the compiler plugin's import closure, which put one lint
rule's message text inside every module's compiled bytes. Both are gone by construction now, because
there is nothing here to disagree with and no reason for the plugin to link a rule.

`ruff-11` adds semantic facts beside `source`. They are facts too, and the same rule applies to them:
elaboration evidence belongs here because only the frontend can make it; what a rule concludes from
it does not. -/
structure ModuleArtifact where
  schema : String
  source : LosslessSource
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Bumped from `v1` when the command-kind/range projection became `LosslessSource`, and from `v2`
when findings and their rule configuration left the artifact. A stale payload must miss, not decode:
a `v2` payload read as `v3` would drop its findings silently through the field defaults and describe
a module with nothing wrong with it, which is the same class of bug `semanticResultSchema` names. -/
def artifactSchema : String := "lean-fmt.module-artifact.v3"

/-- Build the artifact for one accepted module.

This is the only artifact producer. Exact analysis and the compiler plugin reach it with the same
arguments, so they cannot drift into emitting different artifacts for the same module — which is
what makes the facet a sound cache of the exact frontend rather than a second opinion.

It takes no rule configuration, and that is the point rather than an omission: an artifact is a
function of the module and its source alone, so turning a rule on cannot rebuild or re-elaborate
anything. -/
def ModuleArtifact.ofParsedModule (mainModule normalized : String)
    (commands : Array Lean.Syntax) (terminal? : Option Lean.Syntax) : ModuleArtifact := {
  schema := artifactSchema
  source := LosslessSource.ofSource mainModule normalized commands terminal?
}

def artifactLinter : Lean.Name := `leanFmt.semanticArtifact

end LeanFmt.Internal
