---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RRE-SPEC` and `RRE-IMPL` are **verified**. The design is `notes/01-rule-facts.md`; what was run is
`results/01-design.md` and `results/02-engine.md`. Both defects `RRE-SPEC` measured are closed,
re-measured (`evidence/03-both-defects-closed.txt`), and pinned by gates. The external prerequisite
stack `ruff-01-lossless-source` is verified and its live implementation still matches recorded state;
`ruff-02`, `ruff-03`, and `ruff-04` are verified as well, and this stack re-read their live code
rather than trusting it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-design | RRE-SPEC | verified | — |
| 02-engine | RRE-IMPL | verified | RRE-SPEC |
| 03-acceptance | RRE-FINAL | planned | RRE-IMPL |

## Known evidence

- **Both `RRE-SPEC` defects are closed.** There is now one spelling of "turn FMT001 off" (`--ignore`),
  and `check` and `format` report the same findings for one unchanged file. Editing a rule's message
  string leaves `LocalSyntax.olean` (`ee41d3ed...`) and its Lake trace depHash (`863b0469...`)
  byte-identical — both moved before. `evidence/03-both-defects-closed.txt`.
- **The artifact carries facts, not findings.** `ModuleArtifact` is `{ schema, source }` at schema
  `lean-fmt.module-artifact.v3`. A finding is computed by the process that reports it, from facts
  `validFor` has already matched to the bytes in hand, so its range is in range by construction
  rather than by audit.
- **The plugin's exposure has two channels, not one.** Removing `import all LeanFmt.Rules` from
  `CompilerPlugin.lean` is *not sufficient*: `lean_lib LeanFmtCompilerPlugin` also globbed
  `LeanFmt.Rules`, and a Lake library links every module it globs regardless of imports. Both had to
  go. `notes/01-rule-facts.md` §3 is amended with this; `tests/boundary/run.sh` pins both.
- **A rule's tier is its `RuleImpl` constructor, not a field.** `RuleInfo.input` is deleted. It was a
  claim no code had to honor, which is why `RulePlan.requiresSyntax` answered `false` for the
  product's whole life. `RulePlan.requiredTier` folds `Tier.max` over the registry.
- **`Tier` has `source` and `syntax` only.** No `semantic` case, deliberately, against the prompt's
  own task text — `ruff-11`'s `RMR-SPEC` owns semantic-fact characterization and `ruff-11` depends on
  this stack. A tier nothing can produce is a tier nothing tests, which is how `RuleInfo.input`
  rotted. `results/02-engine.md` records this as a deliberate under-delivery, not an oversight.
- Lean's own linter registry is a function table — a record with a `run` field and a `name`, in an
  `IO.Ref (Array Linter)` (`Lean/Elab/Command.lean:64-70,110-111`) — not an attribute and not a
  typeclass. Its one concession to dynamism is bought by plugin loadability
  (`Lean/Elab/Command.lean:108-109`), which this roadmap forbids.
- `RulePlan` selection was already correct and already selection-independent. The design kept it and
  deleted the other mechanism rather than reconciling the two.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Open questions carried into `RRE-FINAL`

- **`Tier.syntax` has no rule.** Both live rules are source-tier, so `RulePlan.requiredTier` is
  `.source` for every possible selection and `Tier.satisfies .source .syntax = false` is unreachable
  from the product. The mixed-tier planning is real code on a branch nothing takes yet. `ruff-06`'s
  `RFX-SPEC` owns the first syntax-tier fixable rule, and
  `Application.renderCanonicalText`'s docstring names it as the trigger.
- **The agreement test asserts the invariant, not the original defect.** The trigger is deleted, so
  the old divergence is unspellable and no test can prove it would have caught the old one.
- **`RRE-FINAL` owes the fanout measurement.** `notes/01-rule-facts.md` §11 records that §3 measured
  invalidation on one module, not on a project; the frozen sample is 62 modules.
- The redundant-import rule (`ruff-09`) needs the exact Lake module graph and does not fit the three
  tiers. Its module-local half is `semantic`; the cross-module half is not any of them. `RIR-SPEC`
  owns the question; `notes/01-rule-facts.md` §11 records that the model does not silently cover it.
- `ruff-08`'s BOM and mixed-line-ending rules are about the bytes normalization erased, and every
  tier indexes the normalized string. `SourceFacts` does not carry the raw shape.
- Removing `leanFmt.trailingWhitespace` is a product behavior change, not a refactor, for any project
  that set it. No deprecation window exists in this repository and none was invented.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
