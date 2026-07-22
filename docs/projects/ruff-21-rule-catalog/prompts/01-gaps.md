---
claim_id: RCT-SPEC
status: planned
depends_on: []
---

# Mine the audit and rank the candidate rules

## Task

Deliver **RCT-SPEC**: Read `ruff-20-acceptance`'s audit and corpus evidence, measure candidate idioms
over the corpus, and produce a ranked candidate list carrying frequency, tier, false-positive risk,
fix availability, and prior art for every entry. Select the target set and record what was rejected
and why.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- `results/01-gaps.md` holds the ranked list. Everything downstream draws from it, so an entry that
  is not there cannot be authored without amending it.
- **Measure, do not brainstorm.** Each candidate's frequency comes from a recorded query over the
  corpus. A candidate nobody can count is recorded as uncountable and why, and it does not rank. The
  failure mode this guards against is a plausible-sounding rule list that no evidence supports and
  that nobody notices is unsupported, because every entry reads reasonably.
- **The tier assignment is a cost decision and belongs here, not in the authoring prompt.** For each
  candidate, name the cheapest tier that can decide it and say what makes the cheaper tier
  insufficient. `ruff-19` measured a syntax-tier rule at ~820 ms/module of frontend children on an
  ordinary build against 105 ms integrated; a candidate pushed one tier up for convenience is a
  candidate that costs every user that difference forever.
- **False-positive risk is the field most likely to be filled in optimistically.** For each
  candidate, write down what legitimate Lean looks like that resembles the violation, then say
  whether the rule's tier can distinguish them. A high count with no separation is the most dangerous
  candidate on the list, because the count makes it look justified. The ranking must be able to
  reject it, and if nothing on the list is rejected that is itself a sign the field was filled in
  optimistically.
- Prior art: what ruff, clippy, or an existing Lean tool (`std`'s linters, mathlib's own
  `Mathlib.Tactic.Linter`, `#lint`) does with the equivalent. Where mathlib already lints something,
  say why lean-fmt should too, or drop the candidate — duplicating a linter the corpus already runs
  is work with no user.
- Select roughly eight to ten. Record the rejected candidates and the reason, because the next stack
  to consider this question should not have to rediscover them.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim.
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Do not author any rule in this prompt.
- Do not rank a candidate missing any of the five fields; record it as unrankable and why.
- `ruff-20`'s recorded complete-corpus evidence may be read freely. Re-running the complete corpus
  requires that stack's authorization and is not development evidence here.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-21-rule-catalog`.
- Run `git diff --check` and read all output before marking RCT-SPEC verified.
