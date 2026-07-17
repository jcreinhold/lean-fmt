---
kind: state
first_unresolved: 02-transaction
---

# Current state

`RFX-SPEC` is **verified**. The design is `notes/01-model.md`; what was run is `results/01-model.md`,
and the characterization is `evidence/01-no-applicability.txt`. The external prerequisite stacks
`ruff-04-formatter-product` and `ruff-05-rule-engine` are both verified, and their live implementation
was re-read here rather than trusted — every claim in the note cites a file and line.

`RFX-IMPL` and `RFX-FINAL` remain planned.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-model | RFX-SPEC | verified | — |
| 02-transaction | RFX-IMPL | planned | RFX-SPEC |
| 03-acceptance | RFX-FINAL | planned | RFX-IMPL |

## What is frozen

- **Applicability is three-valued** — safe / unsafe / display-only — following ruff. "Safe" means
  meaning-preserving under the rule's stated evidence, tied to tier; it is never "reparses". It lives
  on a new `Fix` structure (`fix? : Option Edit` → `Option Fix`), not on `Edit` or `Finding`.
- **Default `fix` applies safe fixes only.** Unsafe fixes are shown and withheld; `--unsafe-fixes` opts
  in; display-only is never applied and cannot be promoted.
- **Per-rule reclassification** is `extend-safe-fixes`/`extend-unsafe-fixes`, resolved as a `RulePlan`
  projection so no rule reads its own reclassification. Display-only is a floor; a rule in both lists
  is a config error.
- **Conflicts reject the whole file** with rule-code + finding-range provenance for both sides; no edit
  is dropped and no fix wins.
- **File atomicity is the transaction unit**; the project result is the deterministic aggregate of
  per-file transactions with no partial write. No cross-file two-phase commit.
- **Formatter composition**: rule fixes apply to canonical text in canonical coordinates; a syntax-tier
  fix composes by re-projecting canonical text, not by translating edits onto moved bytes.

## Blockers and prerequisites

- No blocker is currently recorded beyond the (verified) named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
