module

import all LeanFmt.Analysis
import all LeanFmt.Suppression

namespace LeanFmt.Internal

/-- A module's canonical layout, and the source-rule findings that index **it** rather than the file.

Both halves are needed and neither can be recovered from the other side of a cache hit. `text` is what
`format` prints and what `fix` publishes. `findings` exists because canonical text is *not* lint-clean:
the printer keeps a command's trailing trivia run verbatim (`Printer.lean:208-222`), so it strips no
trailing whitespace and adds no final newline — `RFP-SPEC` §6 checked this rather than assuming it.
Re-running the rules is therefore mandatory, and it cannot be deferred to the caller, because
canonicalizing moves bytes: `namespace     Alpha` loses four of them, and every `findings` offset past
that point would land in the wrong column. The two arrays are the same rules in two coordinate
systems, and mixing them corrupts files.

Both are selection-independent — `runRules` produces every rule's findings and `RulePlan.findings`
projects afterwards — so one cache entry still serves any `--select`. -/
structure CanonicalText where
  text : String
  findings : Array Finding
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticResult where
  schema : String
  source : Digest
  sourceBytes : Nat
  findings : Array Finding
  /-- `none` when this result was produced without a projection to render — the source-only shortcut
  in `availableAnalysis` takes no artifact, so a `check` run caches an entry a later `format` cannot
  use. Such an entry is a miss for a rendering mode rather than an answer, which is why this is an
  `Option` and not a `String`. -/
  canonical? : Option CanonicalText := none
  /-- The parsed source-suppression directives and malformed-directive diagnostics for this module.
  These are facts — pure functions of the source — computed only where the projection is available
  (`ofEnvelope?`), so the source-only shortcut carries the default empty value. Empty is *correct* for
  a shortcut entry, not a stale under-population, because the shortcut is taken only when the source
  contains no directive sigil (`Suppression.mayContainDirective`), so there is nothing to parse. -/
  suppression : SuppressionFacts := {}
  /-- The tier of facts that produced `findings`. `.source` when the source-only shortcut ran (source
  rules only), `.syntax` when the artifact/exact path ran the whole registry against the projection.
  An entry serves a run only when `tier.satisfies plan.requiredTier` (`cacheHitServes`): a `.source`
  entry is complete for a source-only selection but **not** for one that selects a syntax rule, whose
  findings it never computed. Before any syntax rule shipped this was moot — "source findings" was
  "all findings" — and shipping FMT008–FMT013 is exactly what makes it load-bearing. Defaults `.source`
  (the narrow value); the schema bump below makes every pre-tier entry miss rather than read as this
  default and get mis-served. -/
  tier : Tier := .source
  deriving BEq, Lean.ToJson, Lean.FromJson

structure SemanticAnalysis where
  result? : Option SemanticResult
  diagnostics : Array String := #[]
  deriving BEq, Lean.ToJson, Lean.FromJson

/-- `v2` adds `canonical?`. `validFor` compares this exactly, so every `v1` entry on disk is a miss
rather than a silently under-populated hit — a `v1` entry deserialized under `v2` would carry
`canonical? := none` from the field default and read as "this file needs no canonical text", which is
the stale-output bug `RFP-SPEC` §7 named. The schema is what makes the default safe.

`v3` (`RFX-IMPL`): `Finding.fix?` changed from `Option Edit` to `Option Fix`, carrying applicability.
A `Finding` round-trips through *this* cache entry (never through the `.olean`, which holds only facts),
so the on-disk shape moved and every `v2` entry must miss. `RFX-SPEC`'s note §7 said no bump was needed
because it read "not in the artifact" as "not serialized"; the result cache is the second place a
`Finding` is serialized, and the same discipline that versions `canonical?` versions this.

`v4` (`RSP-IMPL`): adds `suppression`. A `v3` entry read as `v4` would default `suppression := {}` and
read as "this file has no directives", which for a directive-bearing file is the stale-suppression
bug — so the schema guard makes every `v3` entry miss, the same discipline that versioned `canonical?`.
The default stays safe only for shortcut entries, which by construction have no directives.

`v5` (`RYR-IMPL`): adds `tier`. A `v4` entry read as `v5` would default `tier := .source` and, if it
had been a full artifact-path entry, read as "source findings only" — narrowing a complete entry, which
would only *under*-serve (a miss, never a false clean), but the same schema discipline that versions
`suppression` versions this so no `v4` entry is silently reinterpreted. -/
def semanticResultSchema : String := "lean-fmt.semantic-result.v6"

/-- `normalized` must be `(LosslessSource.normalize raw).1`, the string every finding indexes.
`suppression` defaults empty for the source-only shortcut; `ofEnvelope?` passes the collected facts.
`tier` records which facts produced `findings` — `.source` for the shortcut (source rules only),
`.syntax` for the artifact/exact path (whole registry over the projection) — so a narrow shortcut entry
cannot serve a run that selects a syntax rule (`cacheHitServes`). -/
def SemanticAnalysis.success (normalized : String) (findings : Array Finding)
    (tier : Tier := .source) (suppression : SuppressionFacts := {}) : SemanticAnalysis := {
  result? := some {
    schema := semanticResultSchema
    source := Digest.ofString normalized
    sourceBytes := normalized.utf8ByteSize
    findings
    suppression
    tier
  }
}

/-- Attach a rendered canonical layout to an already-validated result.

Separate from `success` because rendering needs `IO` (`Printer.format` parses the header) while every
other step here is pure, and because it must happen *after* `ofEnvelope?` has checked
`structurallyValid` and `validFor`: rendering a projection that does not match its own source would
produce canonical text for a file that does not exist. Applying this to a `broken` analysis is a
no-op — there is nothing to render and nothing to attach it to. -/
def SemanticAnalysis.withCanonical (analysis : SemanticAnalysis)
    (canonical : CanonicalText) : SemanticAnalysis :=
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

/- Project a compiler protocol response into the product result. The projection remains compiler
evidence; source-only product rules never receive a fabricated syntax projection.

**The findings are computed here, from the artifact's facts.** They used to travel inside the
artifact, and this comment used to defend that: recomputing them would be "a second opinion about a
module this process never elaborated, and could disagree with the artifact under different options".
The second clause was the only thing holding the first up, and it was circular — findings could
disagree under different options only because a rule's enablement *was* an option. It is not any
more. A rule is a pure total function of its facts, and `validFor` on the line above has just proved
this artifact describes exactly these bytes, so there is one input and one function and no second
opinion available to have.

The empirical version is shorter. Carrying findings in the artifact did not prevent disagreement; it
caused the one `notes/01-rule-facts.md` §2 measured, where `check` reported a rule the artifact said
was off. Two deciders disagreed, so there is now one. -/
def SemanticAnalysis.ofEnvelope? (raw : String)
    (envelope : AnalysisEnvelope) : Option SemanticAnalysis :=
  match envelope.artifact? with
  | none =>
    if envelope.diagnostics.isEmpty then none else some (.broken envelope.diagnostics)
  | some artifact =>
    if structurallyValid artifact && artifact.source.validFor raw &&
        envelope.diagnostics.isEmpty then
      let normalized := (LosslessSource.normalize raw).1
      -- The projection is in hand here (and only here), so this is where directives are parsed:
      -- syntax-tier, exactly like the syntax facts the findings are computed from.
      --
      -- The tier the facts reach is the tier the artifact was captured at. A `.semantic` artifact
      -- (captured under demand by a render or a `.semantic`-rule selection) carries the compiler
      -- diagnostics, so the whole registry — including FMT014–FMT017 — runs against `.semantic` facts
      -- and the result is tagged `.semantic`, complete for any run (monolithic capture, `ruff-11`
      -- `notes/01-authority.md` §6). An artifact without the projection runs the source/syntax
      -- registry against `.syntax` facts and is tagged `.syntax`, exactly as before — a `.syntax`
      -- entry then misses a `.semantic` selection through `cacheHitServes` rather than a false clean.
      let (facts, tier) := match artifact.semantic with
        | some projection =>
          (Facts.semantic (SemanticFacts.of normalized artifact.source projection.diagnostics), Tier.semantic)
        | none =>
          (Facts.syntax (SyntaxFacts.of normalized artifact.source), Tier.syntax)
      some (.success normalized (runRules facts)
        (tier := tier) (suppression := Suppression.collect artifact.source normalized))
    else
      none

end LeanFmt.Internal
