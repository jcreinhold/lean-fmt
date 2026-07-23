/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.LosslessSource

import Lean

namespace LeanFmt.Internal

/-- A conservative replacement. Applying edits is deliberately not part of the compiler plugin. -/
structure Edit where
  range : SourceRange
  replacement : String
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- How safe it is to apply a fix, following ruff's `Applicability`.

- `safe`: the rule's stated evidence guarantees the intended runtime/proof meaning is preserved.
  Applied by default.
- `unsafe`: the fix is plausibly intended, but the rule cannot prove it preserves behavior, comments,
  or intent. Shown by default; applied only under explicit opt-in (`--unsafe-fixes`, or a per-rule
  `extend-safe-fixes` promotion).
- `displayOnly`: never applied. It illustrates the finding for a reader or an editor; configuration
  cannot promote it, because the rule itself declined to make the edit applicable.

"Safe" is a claim under the rule's evidence and is tied to the rule's tier — never merely "it
reparses". -/
inductive Applicability where
  | safe
  | «unsafe»
  | displayOnly
  deriving Inhabited, BEq, DecidableEq, Repr

/-- The wire spelling. Explicit and kebab-cased to match the product's config vocabulary
(`extend-safe-fixes`, `per-file-ignores`) rather than relying on a derived enum encoding. -/
def Applicability.toWire : Applicability → String
  | .safe => "safe"
  | .unsafe => "unsafe"
  | .displayOnly => "display-only"

instance : ToString Applicability := ⟨Applicability.toWire⟩

/-- Whether a fix of this applicability is applied under the current opt-in. Safe always; unsafe only
with `--unsafe-fixes`; display-only never. This is the one admission rule the whole product uses, so
`format`, `diff`, and `fix` agree on what a run would apply. -/
def Applicability.admitted (unsafeFixes : Bool) : Applicability → Bool
  | .safe => true
  | .unsafe => unsafeFixes
  | .displayOnly => false

instance : Lean.ToJson Applicability := ⟨fun a => .str a.toWire⟩

instance : Lean.FromJson Applicability := ⟨fun json => do
  match ← json.getStr? with
  | "safe" => .ok .safe
  | "unsafe" => .ok .unsafe
  | "display-only" => .ok .displayOnly
  | other => .error s!"unknown applicability: {other}"⟩

/-- A proposed transformation attached to a finding: one applicability governing the whole edit set.

Several edits form one atomic fix — they never overlap — so applicability is a property of the
fix and not of any single `Edit`, which is a byte fact carrying no judgment. `notes/01-model.md` §1
records why this is a structure rather than a field on `Edit` or on `Finding`. -/
structure Fix where
  applicability : Applicability
  edits : Array Edit
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
  fix? : Option Fix := none
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- One compiler diagnostic the exact frontend emitted, normalized into immutable data a semantic-tier
rule reads. A *fact*, never a *finding*: only the frontend could produce it (it ran the linters and
the elaborator), and a reader cannot recompute it from the bytes it holds; the rule that surfaces it
concludes the lean-fmt code, applicability, and reporting shape. Carried in the artifact only when a
consumer demanded the `.semantic` tier (`ruff-11` RMR-SPEC `notes/01-authority.md` §4).

- `kind` is the message's top-level tag (`Lean.Message.kind`) — the linter's option name
  (`linter.unusedVariables`) or the deprecation attribute (`Lean.Linter.deprecatedAttr`). It is the
  **stable** identity a rule keys on; the message *text* is version-volatile and is preserved as
  `message` detail, never asserted as the rule's own claim.
- `range` is normalized-source byte offsets, recovered from the message's `Position` through the exact
  frontend's `FileMap` (which `mkInputContext` builds on `crlfToLf`-normalized source), so it shares
  the projection's one coordinate system. Clamped to the module's own byte span at capture, so a
  macro-reattributed position never yields a finding off the file. -/
structure Diagnostic where
  kind : String
  range : SourceRange
  severity : Severity
  message : String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One use of a `@[deprecated]` declaration, re-derived from the whole-file info trees where the
elaborator recorded the resolved constant at each source occurrence. A *fact*, never a *finding*: only
the frontend, having elaborated the module, knows which constant a bare identifier resolved to; a
reader holding only bytes cannot. Carried in the artifact only when a run demanded the **occurrences**
capability (a rendering mode selecting the owned FMT012 rule), so the whole-file info-tree fold is paid
only when the fix is asked for (`ruff-11b` `notes/01-model.md` §§2-5).

The owned analog of `Diagnostic`: FMT012's report is a `Diagnostic` (surfaced, always cheap), but its
`unsafe` rename fix needs the *resolved constant and its replacement*, which only the info tree carries.

- `range` is normalized-source byte offsets of the occurrence identifier token, from
  `Info.range? (canonicalOnly := true)` through the exact frontend's `FileMap` — the same coordinate
  system as `Diagnostic.range` and the projection.
- `declName`/`newName?` are the **user-facing** display spellings (the module-private mangling stripped
  at capture where the `Environment` is live), so no `Name` or `Environment` crosses into a rule. The
  rename fix substitutes `newName?`.
- `fixable` is decided at capture from the bare-identifier predicate (`notes/01-model.md` §5): a
  non-binder occurrence resolving to a bare `.const` with a `newName?` whose display is a single
  identifier. Every non-qualifying occurrence stays `fixable := false` and report-only; the output
  re-elaboration validator backstops a rename that does not resolve. -/
structure DeprecatedOccurrence where
  range : SourceRange
  declName : String
  newName? : Option String
  since? : Option String
  text? : Option String
  fixable : Bool
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Semantic rule capabilities. Diagnostics are captured with every semantic projection; occurrences
are captured only when a selected fix needs the whole-file info-tree fold. -/
structure SemanticCaps where
  diagnostics : Bool := false
  occurrences : Bool := false
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- `demanded ⊆ provided`: every capability the run demanded is present in the entry. Total (never a
`satisfies`-style partial), so it composes with `Tier.satisfies` as a plain conjunction in
`cacheHitServes`. -/
def SemanticCaps.subset (demanded provided : SemanticCaps) : Bool :=
  (!demanded.diagnostics || provided.diagnostics) &&
    (!demanded.occurrences || provided.occurrences)

/-- Semantic facts for one module. `occurrences? = none` means the expensive fold was not requested;
`some #[]` means it ran and found no owned deprecation occurrences. -/
structure SemanticProjection where
  diagnostics : Array Diagnostic := #[]
  occurrences? : Option (Array DeprecatedOccurrence) := none
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Capabilities derived from the projection's shape, never stored a second time. -/
def SemanticProjection.caps (projection : SemanticProjection) : SemanticCaps := {
  diagnostics := true
  occurrences := projection.occurrences?.isSome
}

/- The artifact is stored inside the successful module's `.olean`; exact toolchain, options,
plugins, ordered imports, and dependency identity therefore belong to the module artifact itself
rather than to a parallel cache identity.

`source` carries both the projection and the artifact's whole identity. There is no second module
name or source digest beside it: a duplicate identity is one that can disagree with itself.

**Facts, never findings.** This carries what a reader cannot recompute — the exact frontend's
projection — and nothing a reader could derive from bytes it already holds. It held `findings` and a
`trailingWhitespace` flag until `RRE-IMPL`; `notes/01-rule-facts.md` §6 has the argument and §2-3
have the two measured defects that made it. The short version is that a conclusion in here is a
second decider: `check` never reads an artifact, so it decided the trailing-whitespace question for
itself and disagreed. The
long version is that the rules were in the compiler plugin's import closure, which put one lint
rule's message text inside every module's compiled bytes. Both are gone: there is nothing here to
disagree with, and the plugin has no reason to link a rule.

`ruff-11` adds further semantic facts beside `source`. They are facts too, and the same rule applies:
elaboration evidence belongs here because only the frontend can make it; what a rule concludes from
it does not. -/
structure ModuleArtifact where
  schema : String
  source : LosslessSource
  /-- Semantic rule facts, `none` unless a consumer demanded them. The always-on
  compiler plugin emits `none` (no capture in an integrated build), and the on-demand `analyzeExact`
  emits `some` only when selected rules reach `.semantic`. -/
  semantic : Option SemanticProjection := none
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The capabilities a whole artifact provides: the projection's caps when a `.semantic` projection was
captured, all-`false` otherwise (a syntax-only artifact provides no semantic sub-fact). -/
def ModuleArtifact.caps (artifact : ModuleArtifact) : SemanticCaps :=
  match artifact.semantic with
  | some projection => projection.caps
  | none => {}

/-- `v7` deletes the formatter-only notation database. Old artifact shapes miss rather than being
reinterpreted as semantic rule facts. -/
def artifactSchema : String := "lean-fmt.module-artifact.v7"

/-- Build the artifact for one accepted module.

This is the only artifact producer. Exact analysis and the compiler plugin reach it with the same
arguments, so they cannot drift into emitting different artifacts for the same module — which is
what makes the facet a sound cache of the exact frontend rather than a second opinion.

It takes no rule configuration, deliberately: an artifact is a function of the module and its source
alone, so turning a rule on cannot rebuild or re-elaborate anything. The optional `semantic` projection is likewise a function of the module and its environment;
it defaults to `none` so the always-on plugin producer stays on the syntax-only path, and only
`analyzeExact` passes `some` under demand. -/
def ModuleArtifact.ofParsedModule (mainModule normalized : String)
    (commands : Array Lean.Syntax) (terminal? : Option Lean.Syntax)
    (semantic : Option SemanticProjection := none) : ModuleArtifact := {
  schema := artifactSchema
  source := LosslessSource.ofSource mainModule normalized commands terminal?
  semantic
}

def artifactLinter : Lean.Name := `leanFmt.semanticArtifact

end LeanFmt.Internal
