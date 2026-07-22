---
kind: state
first_unresolved: 01-criteria
---

# Current state

This stack is planned and has not begun. It was opened against `ruff-12-rule-lifecycle`, which built
the stable/preview/deprecated machinery but was never asked to decide which rules belong in which
state. Its external prerequisite stacks are `ruff-10b-syntax-fix-composition`,
`ruff-11-semantic-rules`, `ruff-12-rule-lifecycle`, and `ruff-19-performance`. Before starting,
confirm those roadmaps are verified and their live implementation still matches recorded state.

**It runs before `ruff-20-acceptance`**, so that acceptance covers the catalog as intended rather
than one with two thirds of its rules gated off. Recorded here because the number does not say it:
a `12b` suffix marks a stack opened against `ruff-12`, and `ruff-13` through `ruff-19` are already
verified.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-criteria | RGR-SPEC | planned | — |
| 02-evidence | RGR-EVIDENCE | planned | RGR-SPEC |
| 03-graduate | RGR-IMPL | planned | RGR-EVIDENCE |
| 04-final | RGR-FINAL | planned | RGR-IMPL |

## The catalog as it stands, 2026-07-22

From `lean-fmt rules` against the built binary, not from a record:

| Code | Category | Tier | Lifecycle | Default | Fixable |
| --- | --- | --- | --- | --- | --- |
| FMT003 | security | source | stable | yes | no |
| FMT004 | security | source | stable | yes | no |
| FMT005 | imports | import | stable | yes | **yes** |
| FMT006 | imports | import | stable | yes | no |
| FMT007 | imports | import | stable | yes | no |
| FMT008 | docs | **syntax** | preview | no | no |
| FMT009 | structure | **syntax** | preview | no | no |
| FMT010 | redundancy | **syntax** | preview | no | **yes** |
| FMT011 | redundancy | **syntax** | preview | no | **yes** |
| FMT012 | debug | **syntax** | preview | no | no |
| FMT013 | redundancy | **syntax** | preview | no | **yes** |
| FMT014 | deprecation | **semantic** | preview | no | **yes** |
| FMT015 | unused | **semantic** | preview | no | no |
| FMT016 | unused | **semantic** | preview | no | no |
| FMT017 | naming | **semantic** | preview | no | no |

Fifteen live rules; `FMT001` and `FMT002` are retired into `reservedCodes` because line-boundary and
trailing-newline normalization became part of canonical formatting. `FMT900`/`FMT901` are meta
self-diagnostics of the suppression engine, always active and never selectable.

## The two facts that shape this stack

**All ten preview rules are syntax tier (6) or semantic tier (4). None is source tier.** All five
default rules are source or import tier. So graduating anything from this set puts a tier above
source on the default path for the first time, and that is a cost decision as much as a correctness
one.

**`ruff-19` measured that cost.** One syntax-tier rule over four modules: **3,283 ms in four frontend
children** on an ordinary build, against **105 ms in one facet fetch and no frontend at all** when
the project is plugin-integrated (`ruff-19-performance/results/02-optimize.md`). The gap is the whole
reason the compiler plugin exists, and graduation is the first thing that would make ordinary users
feel it.

## Inherited, and coming due here

- **`ruff-10b`'s Design B decision.** `ruff-10b` rejected a parse-only re-projection for v1 and named
  its revisit condition: *"if a syntax rule graduates to default and the gated re-projection lands on
  the default run cost budget"* (`ruff-10b-syntax-fix-composition/results/03-final.md`). `ruff-19`
  checked and found the trigger unfired, because every syntax rule was still preview. **This stack is
  the event that can fire it**, and `RGR-IMPL` owns adopting or refusing Design B with a measurement.
- **`ruff-19`'s §1c gate encodes today's tier structure.** `tests/performance/run.sh` asserts zero
  `exact_child` and zero `exact_setup` on a served workload. That is true because every default rule
  is source or import tier. A graduation that breaks it requires the gate to be *re-derived with its
  derivation recorded*, not relaxed — and re-proven to discriminate via `tests/performance/negative.sh`.
- **`ruff-19` rejected private concurrency on measurement.** No public `-j`, pinning, or strategy
  flag is available to pay for a more expensive default path.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; that licence belongs to `ruff-20-acceptance` alone. A
  graduation decision that can only be made with the complete corpus is a decision to defer to
  `ruff-20`, and it should say so rather than guess.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
