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
reparses". See `docs/projects/ruff-06-fix-safety/notes/01-model.md` §1. -/
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
capability (a rendering mode selecting the owned FMT014 rule), so the whole-file info-tree fold is paid
only when the fix is asked for (`ruff-11b` `notes/01-model.md` §§2-5).

The owned analog of `Diagnostic`: FMT014's report is a `Diagnostic` (surfaced, always cheap), but its
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

/-- Which semantic sub-facts a run demanded, or a captured projection provides. The capability axis
Design B adds beside the tier (`ruff-11` `notes/01-authority.md` §6, `ruff-11b` `notes/01-model.md`
§4): `Tier.satisfies` gates the tier lattice; `SemanticCaps.subset` gates the sub-facts within
`.semantic`, orthogonally. `notations` and `diagnostics` are the two cheap sub-facts captured together
whenever `.semantic` is demanded (Design A for those two, unchanged); `occurrences` is the one
info-tree-backed sub-fact captured only on demand, so the walk is not forced onto every render. A
cached `.semantic` entry serves a demand only when `demanded.subset provided` — a monolithic-era entry
without the occurrence cap therefore misses a fixable-FMT014 demand rather than serving a false clean. -/
structure SemanticCaps where
  notations : Bool := false
  diagnostics : Bool := false
  occurrences : Bool := false
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- `demanded ⊆ provided`: every capability the run demanded is present in the entry. Total (never a
`satisfies`-style partial), so it composes with `Tier.satisfies` as a plain conjunction in
`cacheHitServes`. -/
def SemanticCaps.subset (demanded provided : SemanticCaps) : Bool :=
  (!demanded.notations || provided.notations) &&
    (!demanded.diagnostics || provided.diagnostics) &&
    (!demanded.occurrences || provided.occurrences)

/-- The declared inter-atom spacing of one notation/atom syntax kind: the untrimmed declared atom
strings, in source order (`" + "` for infix add, `"-"` for prefix neg). A leading or trailing ASCII
space in a string is the notation's declared breakable gap on that side; its absence is tight. This
is the pretty-printing hint the parser trims away (`Init/Prelude.lean:5389`,
`Lean/Parser/Basic.lean:1114`), recovered as data from the notation's `ParserDescr` where the
`Environment` is live. Keyed by `kind` (the `SyntaxNodeKind` string, matching the projection's node
kinds), never by bare token — one token declares different gaps in different kinds (`ruff-05b`
`notes/01-semantic-facts.md` §2-3). -/
structure NotationSpacing where
  kind : String
  atoms : Array String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The semantic facts for one module, captured from the live exact frontend and carried in the
artifact only when a consumer demanded the `.semantic` tier. `notations` and `diagnostics` are
captured together (monolithic, `ruff-11` `notes/01-authority.md` §6): a demanded `.semantic` artifact
carries both, so `Tier.satisfies` stays a sound cache gate and a notations-only entry never silently
under-serves a rule.

- `notations` (`ruff-05b`, formatter fact): declared spacing for every notation kind present, one
  entry per distinct kind (Design B).
- `diagnostics` (`ruff-11`, rule fact, new in `v5`): the compiler's own diagnostics with a stable
  `kind` tag and exact range, which the semantic-tier rules FMT014–FMT017 surface.
- `occurrences?` (`ruff-11b`, fix fact, new in `v6`): the owned deprecation-occurrence facts, present
  (`some`, possibly empty) only when the run demanded the **occurrences** capability, and `none`
  otherwise. `none` means *not captured* (a demand for it must miss the cache); `some #[]` means
  *captured, none found* (a clean hit). This `Option` is the capability record inside the projection:
  `notations`/`diagnostics` are always captured together at `.semantic` (cheap), but the info-tree fold
  behind `occurrences?` is paid only when the fix is asked for (`ruff-11b` `notes/01-model.md` §4). -/
structure SemanticProjection where
  notations : Array NotationSpacing
  diagnostics : Array Diagnostic := #[]
  occurrences? : Option (Array DeprecatedOccurrence) := none
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The capabilities a captured projection provides. `notations` and `diagnostics` are always captured
together when the projection exists (a `.semantic` capture, Design A for the two cheap facts);
`occurrences` is present iff the info-tree fold ran (`occurrences?.isSome`). Derived, not stored twice:
the projection's shape *is* its capability record, so the two cannot disagree. -/
def SemanticProjection.caps (projection : SemanticProjection) : SemanticCaps := {
  notations := true
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
second decider: `check` never reads an artifact, so it decided FMT001 for itself and disagreed. The
long version is that the rules were in the compiler plugin's import closure, which put one lint
rule's message text inside every module's compiled bytes. Both are gone: there is nothing here to
disagree with, and the plugin has no reason to link a rule.

`ruff-11` adds further semantic facts beside `source`. They are facts too, and the same rule applies:
elaboration evidence belongs here because only the frontend can make it; what a rule concludes from
it does not. -/
structure ModuleArtifact where
  schema : String
  source : LosslessSource
  /-- The semantic projection (`v5`): declared notation spacing and normalized compiler diagnostics,
  `none` unless a consumer demanded it. Optional because the two producers differ — the always-on
  compiler plugin emits `none` (no capture in an integrated build), and the on-demand `analyzeExact`
  emits `some` only when the run's tier reaches `.semantic` (a `format` run, or a run selecting a
  `.semantic` rule). See `ruff-05b` `notes/01-semantic-facts.md` §1, `ruff-11` `notes/01-authority.md`
  §6. -/
  semantic : Option SemanticProjection := none
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The capabilities a whole artifact provides: the projection's caps when a `.semantic` projection was
captured, all-`false` otherwise (a syntax-only artifact provides no semantic sub-fact). -/
def ModuleArtifact.caps (artifact : ModuleArtifact) : SemanticCaps :=
  match artifact.semantic with
  | some projection => projection.caps
  | none => {}

/-- Bumped from `v1` when the command-kind/range projection became `LosslessSource`, from `v2` when
findings and their rule configuration left the artifact, from `v3` when the optional `semantic`
projection was added (`ruff-05b` `RSF-IMPL`), from `v4` when that projection gained `diagnostics`
(`ruff-11` `RMR-IMPL`), and from `v5` when it gained the optional `occurrences?` deprecation-occurrence
fact (`ruff-11b` `ROS-IMPL`). A stale payload must miss, never read as captured-and-empty: a `v5` full
`semantic` (notations + diagnostics, no `occurrences?` key) *does* decode under `v6` — `occurrences?`
is an `Option` and defaults to `none` on a missing key — but `none` is exactly *not captured*, so a run
demanding the occurrence capability misses through the caps gate (`SemanticCaps.subset`,
`cacheHitServes`) rather than reading a false "no deprecations". The schema tag still moves so no `v5`
entry is silently reinterpreted; the caps gate is what makes the `Option` default safe, the same way
the tier gate made the earlier defaults safe. A `v4` full `semantic` (no `diagnostics` key) still fails
to decode outright — the derived `FromJson` does not default an absent *array* field, it errors
(verified, v4.32.0) — a harder backstop for the older shape. -/
def artifactSchema : String := "lean-fmt.module-artifact.v6"

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
