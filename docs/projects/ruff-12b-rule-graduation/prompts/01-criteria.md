---
claim_id: RGR-SPEC
status: verified
depends_on: []
---

# Freeze the graduation criteria and the default-path cost policy

## Task

Deliver **RGR-SPEC**: Write the false-positive budget, the fix safety and idempotence standard, the
documentation standard, and the default-path cost policy that the ten preview rules will be judged
against. Name the evidence corpus and the audit method. Fix the set of available outcomes.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

**Write this prompt's criteria before running any rule over any corpus.** Criteria chosen after
seeing which rules would pass are not criteria, and the temptation to tune them is strongest exactly
when a rule you like is about to fail. If you have already seen firing counts when you write this,
say so in the result and treat the criteria as suspect.

## Target

- `results/01-criteria.md` holds the frozen criteria. Everything downstream cites it by section.
- Write the criteria as things that can be *checked*, not as sentiments. "Low false-positive rate" is
  not a criterion; "zero false positives in a hand-audited sample of N findings, where N is stated per
  rule and chosen before the audit" is.
- The cost policy must answer, in numbers: what may an `ordinary-built` project pay, per module and
  per run, for a default rule above source tier? `ruff-19` measured ~820 ms/module of frontend
  children for a syntax-tier rule on an ordinary build against 105 ms for one facet fetch when
  integrated (`ruff-19-performance/results/02-optimize.md`). Both numbers belong in the policy.
- The policy must also say what happens when the answer differs by build state. A rule that is cheap
  when integrated and expensive when not is the normal case here, not the exception, so "default when
  integrated, optional otherwise" must be either an available outcome or an explicitly refused one.
  If it is available, say how a user discovers which they are getting.
- Name the corpus: the frozen mathlib sample, the named stress files, and any focused fixture a rule
  needs to exercise a case the corpus does not contain. State the audit sample size per rule and how
  findings are sampled, before any are read.
- Fix the available outcomes. The roadmap names three — default, optional with a stated path out,
  retired — and a fourth may be added here if it is defined precisely. A rule that stays optional
  must record what would change that; "not yet" without a condition is how a preview rule becomes
  permanent.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim: read `LeanFmt/Rules.lean`'s
   lifecycle and `defaultEnabled` handling, `ruff-12`'s results on preview/stable/deprecated, and the
   retirement machinery (`reservedCodes`, and how `FMT001`/`FMT002` were retired).
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Do not measure any rule's firing behaviour in this prompt. That is `RGR-EVIDENCE`, and the
  separation is the point.
- Do not decide any rule's outcome here, including one that seems obvious.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-12b-rule-graduation`.
- Run `git diff --check` and read all output before marking RGR-SPEC verified.
