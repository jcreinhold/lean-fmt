/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.SyntaxArtifact

import Lean

/-! What a rule reports, and what a module artifact is.

`Finding`, `Fix`, and `Applicability` are what leaves the engine; `ModuleArtifact` is what the engine
reads. They share a module because they meet at one boundary, and because the property that matters
is about both at once: the artifact holds facts and no findings.

It carries no rule configuration, no findings, and no canonical bytes, and is a function of the
module and its source alone — so turning a rule on cannot rebuild or re-elaborate anything. -/

namespace LeanFmt.Internal

/-- A conservative replacement. Applying edits is deliberately not part of the compiler plugin. -/
structure Edit where
  range : SourceRange
  replacement : String
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- How safe it is to apply a fix, following ruff's `Applicability`.

- `safe`: the rule's stated evidence guarantees the intended runtime/proof meaning is preserved.
  Applied by default.
- `unsafe`: plausibly intended, but the rule cannot prove it preserves behavior, comments, or
  intent. Shown by default; applied only under explicit opt-in (`--unsafe-fixes` or a per-rule
  `extend-safe-fixes` promotion).
- `displayOnly`: never applied. It illustrates the finding for a reader or an editor; configuration
  cannot promote it, because the rule itself declined to make the edit applicable.

"Safe" is a claim under the rule's evidence, tied to the rule's tier — never merely "it reparses". -/
inductive Applicability where
  | safe
  | «unsafe»
  | displayOnly
  deriving Inhabited, BEq, DecidableEq, Repr

/-- Wire spelling, explicit and kebab-cased to match config vocabulary
(`extend-safe-fixes`, `per-file-ignores`), not a derived enum encoding. -/
def Applicability.toWire : Applicability → String
  | .safe => "safe"
  | .unsafe => "unsafe"
  | .displayOnly => "display-only"

instance : ToString Applicability :=
  ⟨Applicability.toWire⟩

/-- The one admission rule the product uses: safe always, unsafe only with `--unsafe-fixes`,
display-only never — so `format`, `diff`, and `fix` agree on what a run would apply. -/
def Applicability.admitted (unsafeFixes : Bool) : Applicability → Bool
  | .safe => true
  | .unsafe => unsafeFixes
  | .displayOnly => false

instance : Lean.ToJson Applicability :=
  ⟨fun a => .str a.toWire⟩

instance : Lean.FromJson Applicability :=
  ⟨fun json => do
    match ← json.getStr? with
    | "safe" =>
      .ok .safe
    | "unsafe" =>
      .ok .unsafe
    | "display-only" =>
      .ok .displayOnly
    | other =>
      .error s!"unknown applicability: {other}"⟩

/-- A proposed transformation attached to a finding: one applicability governing the whole edit set.

Edits in one fix are atomic and never overlap, so applicability belongs to the fix, not to a single
`Edit`, which is a byte fact carrying no judgment. This is a
structure rather than a field on `Edit` or on `Finding`. -/
structure Fix where
  applicability : Applicability
  edits : Array Edit
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

inductive Severity where
  | information
  | warning
  | error
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- What a rule concluded. Rules run outside the compiler, so nothing here produces it; this is a
finding's shape in a report and in a fix. -/
structure Finding where
  code : String
  severity : Severity
  message : String
  range : SourceRange
  fix? : Option Fix := none
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- One compiler diagnostic the exact frontend emitted, as immutable data a semantic-tier rule reads.
A *fact*, never a *finding*: only the frontend could produce it (it ran the linters and elaborator),
and a reader cannot recompute it from these bytes; the surfacing rule concludes the lean-fmt code,
applicability, and reporting shape. Carried in the artifact only when a consumer demanded the
`.semantic` tier.

- `kind` is the message's top-level tag (`Lean.Message.kind`) — the linter's option name
  (`linter.unusedVariables`) or the deprecation attribute (`Lean.Linter.deprecatedAttr`). It is the
  **stable** identity a rule keys on; the message *text* is version-volatile and stays `message`
  detail, never the rule's own claim.
- `range` is normalized-source byte offsets, recovered from the message's `Position` through the
  exact frontend's `FileMap` (which `mkInputContext` builds on `crlfToLf`-normalized source), sharing
  the projection's one coordinate system. Clamped to the module's byte span at capture, so a
  macro-reattributed position never yields a finding off the file. -/
structure Diagnostic where
  kind : String
  range : SourceRange
  severity : Severity
  message : String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- One use of a `@[deprecated]` declaration, re-derived from the whole-file info trees, where the
elaborator recorded the resolved constant at each source occurrence. A *fact*, never a *finding*:
only the frontend, having elaborated the module, knows which constant a bare identifier resolved to;
a reader holding only bytes cannot. Carried in the artifact only when a run demanded the
**occurrences** capability (a rendering mode selecting the owned FMT012 rule), so the whole-file
info-tree fold is paid only when the fix is asked for.

The owned analog of `Diagnostic`: FMT012's report is a `Diagnostic` (surfaced, always cheap), but its
`unsafe` rename fix needs the *resolved constant and its replacement*, which only the info tree
carries.

- `range` is normalized-source byte offsets of the occurrence identifier token, from
  `Info.range? (canonicalOnly := true)` through the exact frontend's `FileMap` — the same coordinate
  system as `Diagnostic.range` and the projection.
- `declName`/`newName?` are the **user-facing** display spellings (module-private mangling stripped at
  capture while the `Environment` is live), so no `Name` or `Environment` crosses into a rule. The
  rename fix substitutes `newName?`.
- `fixable` is decided at capture from the bare-identifier predicate: a
  non-binder occurrence resolving to a bare `.const` with a `newName?` whose display is a single
  identifier. Non-qualifying occurrences stay `fixable := false` and report-only; the output
  re-elaboration validator backstops a rename that does not resolve. -/
structure DeprecatedOccurrence where
  range : SourceRange
  declName : String
  newName? : Option String
  since? : Option String
  text? : Option String
  fixable : Bool
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The optional semantic sub-capability beyond `Tier.semantic`. Diagnostics are inherent in that
tier; occurrences are captured only when a selected fix needs the whole-file info-tree fold. -/
structure SemanticCaps where
  occurrences : Bool := false
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- `demanded ⊆ provided`: every demanded capability is present in the entry. Total (never
`satisfies`-style partial), so it composes with `Tier.satisfies` as a plain conjunction in
`analysisServes`. -/
def SemanticCaps.subset (demanded provided : SemanticCaps) : Bool :=
  !demanded.occurrences || provided.occurrences

/-- Semantic facts for one module. `occurrences? = none` means the expensive fold was not requested;
`some #[]` means it ran and found no owned deprecation occurrences. -/
structure SemanticProjection where
  diagnostics : Array Diagnostic := #[]
  occurrences? : Option (Array DeprecatedOccurrence) := none
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Capabilities derived from the projection's shape, never stored a second time. -/
def SemanticProjection.caps (projection : SemanticProjection) : SemanticCaps :=
  { occurrences := projection.occurrences?.isSome }

/- The artifact is stored inside the successful module's `.olean`, so exact toolchain, options,
plugins, ordered imports, and dependency identity belong to the module artifact itself, not to a
parallel cache identity.

The payload holds facts a reader cannot recompute: the parser's reconstructible syntax and, when
demanded, frontend semantic evidence. It contains no formatter policy, findings, rule selection, or
canonical bytes. Rules stay outside the compiler plugin and derive conclusions from these facts. -/
structure ModuleArtifact where
  schema : String
  mainModule : String
  normalizedBytes : Nat
  normalizedDigest : Digest
  syntaxData : ModuleSyntax
  /-- Semantic rule facts, `none` unless a consumer demanded them. The always-on
  compiler plugin emits `none` (no capture in an integrated build), and the on-demand `analyzeExact`
  emits `some` only when selected rules reach `.semantic`. -/
  semantic : Option SemanticProjection := none
  /-- What this module contributes to every downstream elaboration, hashed (`moduleInterfaceHash`
  in `LeanFmt.ArtifactStore`): own declarations' names, kinds, universe parameters, types,
  reducibility, and the bodies of definitions visible at reducible transparency — exported
  syntax reaches the hash through the parser/macro declarations `notation`/`macro` generate.

  `some` only from the facet extractor, which reads the module's own environment; transient
  in-run artifacts (`ofParsedModule`) carry `none`, never a fabricated value. The result cache's
  interface closure mode reads this; a theorem's proof term is deliberately outside it (kernel
  `isDefEq` can unfold any definition — the documented hole behind `[cache] closure`'s opt-in). -/
  interfaceHash : Option Digest := none
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The capabilities a whole artifact provides: the projection's caps when a `.semantic` projection was
captured, all-`false` otherwise (a syntax-only artifact provides no semantic sub-fact). -/
def ModuleArtifact.caps (artifact : ModuleArtifact) : SemanticCaps :=
  match artifact.semantic with
  | some projection => projection.caps
  | none => { }

/-- Current policy-free module artifact shape. The version is checked before any artifact is trusted. -/
def artifactSchema : String :=
  "lean-fmt.module-artifact.v11"

/-- Build the artifact for one accepted module.

Exact analysis reaches this aggregate builder directly. The compiler plugin emits the same
`CommandArtifactRecord` values independently and the facet extractor performs the same
`ModuleSyntax.ofRecords` compaction, avoiding an async process-global accumulator.

It takes no rule configuration, deliberately: an artifact is a function of the module and its source
alone, so turning a rule on cannot rebuild or re-elaborate anything. The optional `semantic`
projection is likewise a function of the module and its environment; it defaults to `none` so the
always-on plugin producer stays on the syntax-only path, and only `analyzeExact` passes `some` under
demand. -/
def ModuleArtifact.ofParsedModule (mainModule normalized : String) (commands : Array Lean.Syntax)
    (terminal : Lean.Syntax) (semantic : Option SemanticProjection := none) :
    Except String ModuleArtifact := do
  let records := commands.map (CommandArtifactRecord.ofSyntax mainModule normalized false ·)
  let records := records.push <| CommandArtifactRecord.ofSyntax mainModule normalized true terminal
  let syntaxData ← ModuleSyntax.ofRecords records
  return {
      schema := artifactSchema
      mainModule
      normalizedBytes := normalized.utf8ByteSize
      normalizedDigest := Digest.ofString normalized
      syntaxData
      semantic }

/-- Marks the one materialization failure that is a limit of this tool rather than a mismatch: the
parse is real and the bytes are right, but no lossless projection can hold it. Callers classify on
this prefix (`unrepresentableProjection?`), so it is part of the contract, not a message. -/
def unrepresentablePrefix : String :=
  "lean-fmt cannot represent this file losslessly: "

structure MaterializedArtifact where
  source : LosslessSource
  commands : Array Lean.Syntax
  terminal : Lean.Syntax

def ModuleArtifact.materialize (artifact : ModuleArtifact) (raw : String) :
    Except String MaterializedArtifact := do
  let (normalized, _) := LosslessSource.normalize raw
  unless
    artifact.schema == artifactSchema && artifact.normalizedBytes == normalized.utf8ByteSize &&
        artifact.normalizedDigest == Digest.ofString normalized &&
      artifact.syntaxData.structurallyValid artifact.normalizedBytes do
    throw "module artifact identity or structure is invalid"
  let materialized ← artifact.syntaxData.materialize normalized
  let sourceProjection :=
    LosslessSource.ofSource artifact.mainModule normalized materialized.commands
      (some materialized.terminal)
  if let some reason := sourceProjection.validationError? then
    throw s!"{unrepresentablePrefix}{reason}"
  unless sourceProjection.validFor raw do
    throw "the reconstructed projection does not describe these bytes"
  return {
      source := sourceProjection
      commands := materialized.commands
      terminal := materialized.terminal }

def commandArtifactLinter : Lean.Name :=
  `leanFmt.commandSyntaxArtifact

end LeanFmt.Internal
