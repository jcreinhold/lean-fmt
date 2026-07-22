---
kind: roadmap
topic: "Preview rule graduation on corpus evidence"
main_results: [RGR-FINAL]
prereq_stacks: [ruff-10b-syntax-fix-composition, ruff-11-semantic-rules, ruff-12-rule-lifecycle, ruff-19-performance]
blueprint_tracked: false
---

# Preview rule graduation on corpus evidence

## Goal

Decide, for each of the ten rules parked in preview, whether it becomes a default rule, stays
optional, or is retired — and pay whatever the decision costs on the default run path rather than
declaring the decision free.

## The defect this stack exists to fix

`lean-fmt rules` lists fifteen rules. **Five are on by default. Ten are not.**

```
stable / default (5)   FMT003 FMT004 (security)   FMT005 FMT006 FMT007 (imports)
preview / optional (10) FMT008 … FMT017
```

Stacks 08–11 built those ten and `ruff-12` gave them a lifecycle, but nothing has ever decided
whether they are good enough to run by default. Two thirds of the catalog is therefore shipped and
invisible: a user who does not pass `--preview` gets a linter with five rules, and nothing in the
product tells them the other ten exist and were judged unready — because they were never judged at
all. Graduation is not a new capability. It is the unfinished half of the stacks that built them.

## The cost that makes this hard, and why it is not a footnote

**Every one of the ten is syntax tier or semantic tier. None is source tier.**

| Tier | Rules | What it needs |
| --- | --- | --- |
| syntax | FMT008 FMT009 FMT010 FMT011 FMT012 FMT013 | the compiler artifact, or the exact frontend |
| semantic | FMT014 FMT015 FMT016 FMT017 | `Environment` capture |
| source | — | nothing |

The five default rules are source and import tier, which is exactly why a warm default `check` is
fully cache-served with **zero `exact_child` and zero `exact_setup`** (`ruff-19`
`tests/performance/run.sh` §1). Graduating *any* rule from this set puts a tier above source on the
default path for the first time.

`ruff-19` measured what that costs. On an *ordinary-built* project, one syntax-tier rule over four
modules spent **3,283 ms in four frontend children** — about 820 ms per module — where the same rule
on a plugin-integrated project spent **105 ms** in one facet fetch and never ran the frontend at all
(`ruff-19-performance/results/02-optimize.md`). So the honest statement of this stack's problem is:

> Graduating a rule is a decision about correctness *and* a decision to make every default run of
> every non-integrated project pay for a compiler artifact it does not have.

This stack owns both halves. It may not graduate a rule and leave the cost for `ruff-20` to discover.

## What this stack inherits, and must therefore decide

**`ruff-10b`'s Design B decision comes due here.** `ruff-10b` rejected Design B — a parse-only
projection of rendered canonical text in place of full re-elaboration — and named its own revisit
condition precisely: *"if a syntax rule graduates to default and the gated re-projection lands on the
default run cost budget"* (`ruff-10b-syntax-fix-composition/results/03-final.md`). `ruff-19` checked
that trigger and found it unfired, because every syntax rule was still preview
(`ruff-19-performance/results/02-optimize.md`). **This stack is the event that fires it.** If any of
FMT008–FMT013 graduates and carries a fix, Design B is adopted or it is refused with a measurement.

## Completion contract

- Freeze graduation criteria **before** looking at per-rule results: a false-positive budget, a fix
  safety and idempotence standard, a documentation standard, and an explicit default-path cost
  policy. Criteria chosen after seeing which rules would pass are not criteria.
- Every rule is judged on measured corpus behaviour — firing counts and hand-audited findings over
  the frozen mathlib sample and named stress files — not on the plausibility of its description.
- A rule that fires wrongly even once on audited real code does not graduate. A default rule is
  read by people who did not choose it, so its false-positive budget is stricter than an optional
  rule's, and the asymmetry is stated rather than assumed.
- The default-path cost of the graduated set is measured on **both** `ordinary-built` and
  `formatter-integrated-built` projects, under `ruff-19`'s workload definitions, and reported as a
  before/after on the same workloads. `ruff-19`'s gates must still pass, or the graduation is
  rejected or the gates are re-derived with a recorded reason.
- Adopt `ruff-10b` Design B, or record the measurement that refuses it, if a syntax rule with a fix
  graduates.
- A rule that neither graduates nor is retired records **why it stays optional and what would change
  that** — a preview rule with no stated path out of preview is a rule nobody will ever revisit.
- Retirement is a permitted and expected outcome. `ruff-12`'s retirement notice machinery and
  `reservedCodes` already exist (`FMT001`, `FMT002` are retired that way); a rule that cannot earn a
  default slot and has no optional constituency should use it.
- `docs/`, `lean-fmt explain`, the generated rule docs, and `docs/adding-a-rule.md`'s tier guidance
  agree with the resulting catalog.

## Work order

1. **RGR-SPEC — Freeze the graduation criteria and the cost policy.** Write the false-positive
   budget, fix standard, documentation standard, and the default-path cost policy, including what an
   ordinary-built project is allowed to pay for a tier above source. Name the evidence corpus and the
   audit method. Decide, in advance, what outcomes are available to a rule: default, optional with a
   stated path, or retired.
2. **RGR-EVIDENCE — Measure all ten rules against the criteria.** Run each rule over the frozen
   sample and the named stress files; record firing counts; hand-audit a stated sample of findings per
   rule for true/false positives; exercise each fix for safety and idempotence; measure the default
   path cost delta per candidate set on both build states. Write per-rule verdicts against the frozen
   criteria, and do not revise the criteria to fit a rule.
3. **RGR-IMPL — Graduate, park, or retire, and pay the cost.** Apply the verdicts to the catalog and
   the lifecycle. Adopt Design B or refuse it with the measurement. Update the default rule set,
   documentation, `explain` output, and the generated docs. Re-derive `ruff-19`'s performance gates
   if the default path changed, with the derivation recorded.
4. **RGR-FINAL — Accept the new catalog.** Re-run the corpus with the shipped defaults, confirm the
   cost policy holds on both build states, confirm every remaining preview rule has a stated path out
   of preview, and record the catalog that `ruff-20` will accept.

## Evidence and verification

Every prompt writes a `results/` note with commands, raw measurements or evidence locators, changed
design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative mathlib
sample, and named stress files. **Do not run complete mathlib in this stack** — that licence belongs
to `ruff-20-acceptance` alone, and a graduation decision that can only be made with the full corpus
is a decision to defer to `ruff-20` and say so.

Run the affected Lean build/tests, `tests/boundary/run.sh`, `tests/performance/run.sh`, this stack's
structural checker, generated-next check, and `git diff --check`. Performance records name workload,
profile, cache/build state, machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and
swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Do not graduate a rule to pad the default count. A five-rule default set that is always right is a
  better product than a fifteen-rule set that is sometimes wrong, and the second is much harder to
  walk back.
- Do not weaken the criteria after seeing the evidence. Record the rule that failed and why.
- Do not put a tier above source on the default path without measuring both build states.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation
  identity, private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- No public `-j`, pinning, or strategy flag; `ruff-19` rejected private concurrency on measurement
  and nothing here reopens it.
