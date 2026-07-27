/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.ArtifactStore
import all LeanFmt.Rules
import all LeanFmt.Suppression
import all LeanFmt.Validator

namespace LeanFmt.Internal

structure SemanticResult where
  schema : String
  source : Digest
  sourceBytes : Nat
  findings : Array Finding
  /-- `none` when this result was produced without a projection to render — the source-only shortcut
  in `availableAnalysis` takes no artifact, so a `check` run caches an entry a later `format` cannot
  use. Such an entry is a miss for a rendering mode, not an answer — which is why this is an `Option`,
  not a `String`. -/
  canonical? : Option CanonicalLayout := none
  /-- The parsed source-suppression directives and malformed-directive diagnostics for this module.
  Facts — pure functions of the source — computed only where the projection is available
  (`ofArtifact?`), so the source-only shortcut carries the default empty value. Empty is *correct* for
  a shortcut entry, not a stale under-population: the shortcut is taken only when the source contains
  no directive sigil (`Suppression.mayContainDirective`), so there is nothing to parse. -/
  suppression : SuppressionFacts := {}
  /-- The tier of facts that produced `findings`. A cache entry serves only demands satisfied by this
  tier, so a source-only shortcut cannot answer a syntax or semantic selection. -/
  tier : Tier := .source
  /-- Semantic sub-facts captured by this entry. Source and syntax entries provide none; semantic
  entries always provide diagnostics and provide occurrences only when requested. -/
  caps : SemanticCaps := {}
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticAnalysis where
  result? : Option SemanticResult
  diagnostics : Array String := #[]
  deriving BEq, Lean.ToJson, Lean.FromJson

/-- The current cache shape stores the complete admitted `CanonicalLayout` with its source map and
formatter/validation metrics. The version is part of cache identity; older result shapes miss. -/
def semanticResultSchema : String := "lean-fmt.semantic-result.v12"

/-- `normalized` must be `(LosslessSource.normalize raw).1`, the string every finding indexes.
`suppression` defaults empty for the source-only shortcut; `ofArtifact?` passes the collected facts.
`tier` records which facts produced `findings` — `.source` for the shortcut (source rules only),
`.syntax` for the artifact/exact path (whole registry over the projection) — so a narrow shortcut entry
cannot serve a run that selects a syntax rule (`cacheHitServes`). -/
def SemanticAnalysis.success (normalized : String) (findings : Array Finding)
    (tier : Tier := .source) (suppression : SuppressionFacts := {})
    (caps : SemanticCaps := {}) : SemanticAnalysis := {
  result? := some {
    schema := semanticResultSchema
    source := Digest.ofString normalized
    sourceBytes := normalized.utf8ByteSize
    findings
    suppression
    tier
    caps
  }
}

/-- Attach an already admitted canonical layout to a source-validated semantic result.

Separate from `success` because the frontend admission is an independently fallible operation and
because this must happen *after* `ofArtifact?` checks `structurallyValid` and `validFor`. Applying it
to a broken analysis is a no-op. -/
def SemanticAnalysis.withCanonical (analysis : SemanticAnalysis)
    (canonical : CanonicalLayout) : SemanticAnalysis :=
  { analysis with result? := analysis.result?.map ({ · with canonical? := some canonical }) }

def SemanticAnalysis.broken (diagnostics : Array String) : SemanticAnalysis := {
  result? := none
  diagnostics
}

/-- `raw` is the file as the caller read it; identity is normalized, so normalize before comparing.
Every `validFor` in the product takes raw bytes and normalizes, so no caller has to remember which
coordinate system a given identity lives in. -/
def SemanticAnalysis.validFor (analysis : SemanticAnalysis) (raw : String) : Bool :=
  match analysis.result? with
  | none => !analysis.diagnostics.isEmpty
  | some result =>
    let normalized := (LosslessSource.normalize raw).1
    analysis.diagnostics.isEmpty && result.schema == semanticResultSchema &&
      result.source == Digest.ofString normalized &&
      result.sourceBytes == normalized.utf8ByteSize

/- Project a compiler protocol response into the product result. The projection stays compiler
evidence; source-only product rules never receive a fabricated syntax projection.

**The findings are computed here, from the artifact's facts.** They used to travel inside the
artifact, and this comment used to defend that: recomputing them would be "a second opinion about a
module this process never elaborated, and could disagree with the artifact under different options".
The second clause was the only thing holding the first up, and it was circular — findings could
disagree under different options only because a rule's enablement *was* an option. It is not any
more. A rule is a pure total function of its facts, and `validFor` on the line above has just proved
this artifact describes exactly these bytes: one input, one function, no second opinion to have.

Empirically: carrying findings in the artifact did not prevent disagreement; it caused the one
`notes/01-rule-facts.md` §2 measured, where `check` reported a rule the artifact said was off. Two
deciders disagreed, so there is now one. -/
def SemanticAnalysis.ofArtifact? (raw : String) (artifact? : Option ModuleArtifact)
    (diagnostics : Array String := #[]) : Option SemanticAnalysis :=
  match artifact? with
  | none =>
    if diagnostics.isEmpty then none else some (.broken diagnostics)
  | some artifact =>
    if diagnostics.isEmpty then
      let normalized := (LosslessSource.normalize raw).1
      match artifact.materialize raw with
      | .error _ => none
      | .ok materialized =>
      -- The projection is in hand here (and only here), so directives are parsed here:
      -- syntax-tier, exactly like the syntax facts the findings are computed from.
      --
      -- The tier the facts reach is the tier the artifact was captured at. A `.semantic` artifact
      -- (captured under demand by a render or a `.semantic`-rule selection) carries the compiler
      -- diagnostics, so the whole registry — including FMT012–FMT015 — runs against `.semantic`
      -- facts and the result is tagged `.semantic`, complete for any run (monolithic capture,
      -- `ruff-11` `notes/01-authority.md` §6). An artifact without the projection runs the
      -- source/syntax registry against `.syntax` facts and is tagged `.syntax`, exactly as before —
      -- a `.syntax` entry then misses a `.semantic` selection through `cacheHitServes` rather than
      -- reporting a false clean. The caps a `.semantic` entry provides are the projection's own
      -- (`diagnostics` always, `occurrences` iff the info-tree fold ran); a syntax entry provides
      -- none. `occurrences` flow into the facts so the owned FMT012 rule can attach its rename fix —
      -- empty when the capability was not demanded, keeping the report byte-identical to the
      -- surfaced-only path.
        let (facts, tier, caps) := match artifact.semantic with
          | some projection =>
            (Facts.semantic (SemanticFacts.of normalized materialized.source projection.diagnostics
              (projection.occurrences?.getD #[])), Tier.semantic, projection.caps)
          | none =>
            (Facts.syntax (SyntaxFacts.of normalized materialized.source), Tier.syntax,
              ({} : SemanticCaps))
        some (.success normalized (runRules facts) (tier := tier)
          (suppression := Suppression.collect materialized.source normalized) (caps := caps))
    else
      none

end LeanFmt.Internal
