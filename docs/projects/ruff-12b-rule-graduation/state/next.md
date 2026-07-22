# Next Proof Packet

- Stack: ruff-12b-rule-graduation
- First unresolved: 01-criteria
- Claim ID: RGR-SPEC
- Prompt: 01-criteria
- Module: (docs only)
- Target file: `results/01-criteria.md`

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RGR-SPEC**: Write the false-positive budget, the fix safety and idempotence standard, the documentation standard, and the default-path cost policy that the ten preview rules will be judged against. Name the evidence corpus and the audit method. Fix the set of available outcomes.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- **Write the criteria before running any rule over any corpus.** Criteria chosen after seeing which rules would pass are not criteria; if you have already seen firing counts, say so and treat them as suspect.
- Do not measure any rule's firing behaviour in this prompt, and do not decide any rule's outcome, including one that seems obvious. That is `RGR-EVIDENCE` and `RGR-IMPL`.
- The cost policy must answer in numbers what an `ordinary-built` project may pay for a default rule above source tier. `ruff-19` measured ~820 ms/module of frontend children against 105 ms for one facet fetch when integrated; both belong in the policy.
- "Default when integrated, optional otherwise" is either an available outcome or an explicitly refused one — decide which, and if available, say how a user discovers which they are getting.
- A rule that stays optional must record the condition that would graduate it. "Not yet" without a condition is how a preview rule becomes permanent.
- No full mathlib run; that licence is `ruff-20-acceptance`'s alone.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
