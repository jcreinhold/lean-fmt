---
kind: state
first_unresolved: 02-engine
---

# Current state

`RRE-SPEC` is **verified**. The design is `notes/01-rule-facts.md`; what was run is
`results/01-design.md`. No product behavior changed and `LeanFmt/` is untouched, which is the
correct footprint for a spec prompt. The external prerequisite stack `ruff-01-lossless-source` is
verified and its live implementation still matches recorded state; `ruff-02`, `ruff-03`, and
`ruff-04` are verified as well, and this stack re-read their live code rather than trusting it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-design | RRE-SPEC | verified | — |
| 02-engine | RRE-IMPL | planned | RRE-SPEC |
| 03-acceptance | RRE-FINAL | planned | RRE-IMPL |

## Known evidence

- **Rule enablement has two spellings and they disagree.** `--ignore FMT001` is honored by every
  mode; `leanFmt.trailingWhitespace=false` is honored by `format` and silently dropped by `check`
  (`evidence/01-two-spellings-disagree.txt`). The source-only shortcut in `availableAnalysis`
  (`Application.lean:383-389`) calls `runRules normalized true` with the flag as a literal, and that
  shortcut is the path every plain `check` on a current module takes. `verify-official-facet`
  (`LeanFmtTest.lean:483-485`) compares the artifact path against itself and could not see it.
- **One rule's message text is inside every module's compiled bytes.** Editing one space into
  FMT001's message changed `LocalSyntax.olean` from `4cdeb8c8...` to `4e707288...` and invalidated
  its Lake trace (`evidence/02-rule-text-in-every-olean.txt`). The trace cost is unconditional — any
  rule edit re-elaborates the whole target project — because `CompilerPlugin.lean:4` imports
  `LeanFmt.Rules` and every plugin-using module depends on the plugin.
- Both defects have one cause: the artifact carries **findings**, which are conclusions. It should
  carry **facts**. `ModuleArtifact.findings` has exactly one production consumer
  (`Semantic.lean:98`), and that consumer holds the raw bytes and could recompute them.
- `RuleInfo.input` is a claim no code has to honor. `RulePlan.requiresSyntax` (`Config.lean:199-200`)
  has therefore answered `false` for the product's whole life, which `Application.lean:126-133`
  already recorded as the reason a real stale-module hazard "could not have been caught".
- Lean's own linter registry is a function table — a record with a `run` field and a `name`, in an
  `IO.Ref (Array Linter)` (`Lean/Elab/Command.lean:64-70,110-111`) — not an attribute and not a
  typeclass. Its one concession to dynamism is bought by plugin loadability
  (`Lean/Elab/Command.lean:108-109`), which this roadmap forbids.
- `RulePlan` selection is already correct and already selection-independent (`Semantic.lean:18-19`).
  The design keeps it and deletes the other mechanism rather than reconciling the two.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Open questions carried into `RRE-IMPL`

- The redundant-import rule (`ruff-09`) needs the exact Lake module graph and does not fit the three
  tiers. Its module-local half is `semantic`; the cross-module half is not any of them. `RIR-SPEC`
  owns the question; `notes/01-rule-facts.md` §11 records that the model does not silently cover it.
- `ruff-08`'s BOM and mixed-line-ending rules are about the bytes normalization erased, and every
  tier indexes the normalized string. `SourceFacts` as specified does not carry the raw shape.
- Removing `leanFmt.trailingWhitespace` is a product behavior change, not a refactor, for any project
  that sets it. No deprecation window exists in this repository and the note does not invent one.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
