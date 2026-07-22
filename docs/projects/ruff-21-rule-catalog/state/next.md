# Next Proof Packet

- Stack: ruff-21-rule-catalog
- First unresolved: 01-gaps
- Claim ID: RCT-SPEC
- Prompt: 01-gaps
- Module: (docs only)
- Target file: `results/01-gaps.md`

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCT-SPEC**: Read `ruff-20-acceptance`'s audit and corpus evidence, measure candidate idioms over the corpus, and produce a ranked candidate list carrying frequency, tier, false-positive risk, fix availability, and prior art for every entry. Select the target set and record what was rejected and why.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- **Confirm `ruff-20-acceptance` has run before starting.** This stack is audit-driven; without that audit there is nothing to be driven by.
- Measure, do not brainstorm. Each candidate's frequency comes from a recorded query over the corpus; a candidate nobody can count is recorded as uncountable and does not rank.
- Assign each candidate to the **cheapest tier that can decide it**, and say what makes the cheaper tier insufficient. `ruff-19` measured a syntax-tier rule at ~820 ms/module of frontend children on an ordinary build against 105 ms integrated; a candidate pushed one tier up for convenience costs every user that difference forever.
- False-positive risk is the field most likely to be filled in optimistically. Write down what legitimate Lean resembles the violation, then say whether the tier can distinguish them. **If nothing on the list is rejected, treat that as evidence the field was filled in optimistically.**
- Where mathlib already lints something (`Mathlib.Tactic.Linter`, `#lint`, `std`'s linters), say why lean-fmt should too, or drop the candidate.
- Do not author any rule in this prompt. Select roughly eight to ten, and record the rejected candidates with reasons.
- `ruff-20`'s recorded complete-corpus evidence may be read freely; re-running the complete corpus requires that stack's authorization.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
