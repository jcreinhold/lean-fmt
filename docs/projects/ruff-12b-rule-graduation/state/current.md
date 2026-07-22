---
kind: state
first_unresolved: none
---

# Current state

> **The rule codes in this file and in this stack's result notes are pre-renumbering.** The catalog
> was renumbered to start at `FMT001` after `RGR-FINAL` was verified (`docs/rules/MIGRATION.md`):
> subtract two from every code below. `FMT013`, this stack's one graduation, is `FMT011` today.

**RGR-SPEC is verified.** `results/01-criteria.md` freezes the criteria: four outcomes (§1),
the false-positive budget and audit method (§2), the fix standard (§3), the documentation standard
(§4), the default-path cost policy (§5), and the named corpus (§6). Three things it decided that
change the shape of the remaining work:

- **`stable-optional` is the fourth outcome** — `lifecycle := .stable` with `defaultEnabled := false`.
  It needs no new machinery: `LeanFmt/Config.lean:668-671` already expands `all` and category to
  every `.stable` rule regardless of `defaultEnabled`, so the state is implemented and merely
  unoccupied. It is the landing spot for a rule that is correct but too expensive for the default path.
- **"Default when integrated, optional otherwise" is refused** (§1.4), because it would make findings
  depend on build state the user cannot see and would make the catalog unprintable without a workspace.
- **CP-2 (§5.3) was expected to bind, and it does — far harder than projected.** §5.3 predicted ~2×
  from `ruff-19`'s ~408 ms/module. `RGR-EVIDENCE` measured **33×** (4,832 ms/module on real mathlib
  modules). The projection was wrong by ~11×; the 1.25× budget itself is unchanged.

`results/01-criteria.md` §0 discloses that its author had already read `ruff-12`'s aggregate firing
count (ten preview rules, 62 modules, one true-positive FMT013, zero false positives) and names
§2.2's exposure threshold as the criterion that exposure could have contaminated.

**RGR-EVIDENCE is verified.** What it established:

- **85 real mathlib modules produced 2 findings.** Both true positives, zero false positives, zero
  broken modules, zero infrastructure failures. Eight of the ten rules never fired at all.
- **No rule graduates to default.** §2.2's bar is 10 audited true positives; the highest any rule
  reached is 1. The bar was not moved, and `results/02-evidence.md` carries a section saying which
  criteria were *not* revised so a reader can check.
- **FMT013 → `stable-optional`;** the other nine → `preview-with-path`, each with a §1.5 condition
  naming the corpus that would exercise it. Nothing is retired.
- **The corpus, not the rules, is what got measured.** mathlib enforces most of these rules itself
  (`linter.style.setOption` is FMT012's near-equivalent). FMT013 is the one rule with no mathlib
  counterpart and the one rule that fired on the sample.
- **CP-1 holds and its untested prediction is now tested** (`evidence/02-cp1-warm-serve.md`): the
  content-keyed cache does serve a tier above source on a warm hit. Shown non-vacuously — the all-ten
  arm emitted 17 findings on a warm, fully-served, zero-`exact_child` run, byte-identical to cold.
- **CP-2 fails by 26×** (`results/02-evidence.md`): baseline 9,068 ms median vs 299,608 ms with one
  syntax rule, **1 frontend child vs 62** — a fixed cost against a per-module linear one. That
  structural difference, not the wall time, is why it is not a tuning problem. CP-4's predicted 101 ms
  tax measured **0 ms** and is corrected rather than dropped; CP-3 was not measured and is recorded as
  an explicit gap, since no rule reaches default and nothing binds it.
- **`ruff-10b` Design B does not fire.** Its trigger needs a syntax rule at *default*; `stable-optional`
  is off the default path by construction. But this stack can now say what `ruff-19` could not: **had
  it fired, Design A would have missed the budget by 26×**, so `RGR-IMPL` records that measurement in
  place of a bare re-check.

**RGR-IMPL is verified.** The verdicts are the built catalog (`results/03-graduate.md`):

- **FMT013 is `lifecycle := .stable`, `defaultEnabled := false`** — the `stable-optional` outcome,
  occupied for the first time. No selector machinery was added; the state was already implemented.
  Confirmed against the built binary: FMT013 fires under `--select FMT013`, `--select redundancy`,
  and `--select all` with **no** `--preview`, and stays silent under `--select default` and a bare run.
- **`RuleInfo.previewPath?` implements DOC-3**, rendered by `explain`, the generated page, and the
  JSON, and pinned by a **bidirectional** catalog invariant: nonempty iff `lifecycle == .preview`.
  The backward direction matters as much as the forward one — a stale path on a graduated rule is a
  documentation lie that reads as current.
- **Nothing is retired.** `reservedCodes` is untouched.
- **`ruff-10b` Design B is refused with a measurement, not a re-check.** The trigger is unfired (no
  syntax rule reaches default), but the cost of firing it was measured: **33.0× against a 1.25×
  budget, 1 frontend child versus 62**. Had it fired, Design A would have missed by 26×.
- **`ruff-19`'s gates pass unchanged and were not re-derived.** The default set did not change, so
  §1c's derivation still holds for the original reason. `tests/performance/run.sh` §0 (`negative.sh`)
  proved all 16 gates discriminate before the suite reported that none failed.
- **Three unit assertions that encoded the old catalog were rewritten**, including one whose stated
  premise ("every stable rule is default-on") is exactly what this stack broke. Its replacement
  carries a guard so it cannot pass vacuously if `stable-optional` is ever vacated.

**RGR-FINAL is verified. The stack is complete.** `results/04-final.md` is the standalone catalog
`ruff-20-acceptance` audits against — readable without the three notes before it, by design.

- **The shipped catalog was run, not asserted.** Three arms over the frozen 62-module sample,
  `ordinary-built`, cold: `default` **27** findings (reproducing CP-2's baseline exactly — the control),
  `all` without `--preview` **28** (the extra one is FMT013), `all --preview` **28** (unchanged). Zero
  broken, zero rejected, zero infrastructure failures in every arm.
- **The one-finding gap is `stable-optional`, observed end to end.** Before this stack those first two
  arms were byte-identical, because every stable rule was default-on. A user can now see the state
  with two commands on real source.
- **`--preview` adds nothing on this manifest**, and that *reproduces* RGR-EVIDENCE rather than
  contradicting it: its second finding (FMT009) is in a module outside the 62-file manifest. The
  uncomfortable reading stands — nine rules unlocked against 62 real mathlib modules found nothing.
- **Two documentation defects found and fixed.** `explain FMT900` answered `unknown rule` for a code
  the product prints in reports; the cause was reading absence from `ruleRegistry` (never *selectable*)
  as non-existence. And `docs/adding-a-rule.md` had never documented `lifecycle` at all, so a
  contributor setting `.preview` would hit invariant 3b with no guidance.
- **A real gate fired.** The two declarations added for `explain` moved this repository's own command
  count 1,035 → 1,037, and this repository is the printer's corpus. `ruff-03`'s `RLF-FINAL` chain
  caught it and named its own remedy; both links were re-run, both edited modules re-probed
  individually (Rules.lean 90/90, Cli.lean 80/80), and 21 stale prose figures updated. 927/926 →
  929/928 over the same 28 modules, gap still +1 for the two documented causes.
- **All 21 suites pass**, plus `lake build`, `lake lint`, `lean-fmt-tests`, and `docs --check`.

Two defects recorded for later owners, not repaired here (prompt 02 forbids repairing a rule to make
it pass): FMT009 does not carve out a whole-file *named* namespace though it carves out the whole-file
*anonymous* section, and lean-fmt's own 34 modules violate FMT008.

This stack was opened against `ruff-12-rule-lifecycle`, which built
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
| 01-criteria | RGR-SPEC | **verified** (`results/01-criteria.md`) | — |
| 02-evidence | RGR-EVIDENCE | **verified** (`results/02-evidence.md`) | RGR-SPEC |
| 03-graduate | RGR-IMPL | **verified** (`results/03-graduate.md`) | RGR-EVIDENCE |
| 04-final | RGR-FINAL | **verified** (`results/04-final.md`) | RGR-IMPL |

## The catalog as it stands, 2026-07-22

From `lean-fmt rules` against the built binary, not from a record. Re-read after `RGR-IMPL`: FMT013's
lifecycle is now `stable` with default still off, and that one row is the whole of what this stack
changed in the catalog.

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
| FMT013 | redundancy | **syntax** | **stable** | no | **yes** |
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
- **The KanProofs structural checkers no longer pass on any lean-fmt stack.** `check_stack.py` reports
  five `implementation_route` errors here *and* on the closed, verified `ruff-06-fix-safety` and
  `ruff-12-rule-lifecycle`, whose own result notes record "0 warnings" from the same script;
  `write_next.py --check` fails earlier on a missing "formalization policy". The tooling acquired a
  convention after these stacks were written and no lean-fmt stack adopts it. Settled by recording it
  (`results/01-criteria.md` §"Structural checker disagreement"), not by adding a route block to one
  stack. The stack-shaped assertions — frontmatter, `depends_on`, `first_unresolved` — do pass. Not a
  blocker; adopting or discarding the convention repo-wide belongs with `docs/projects/AGENTS.md`.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; that licence belongs to `ruff-20-acceptance` alone. A
  graduation decision that can only be made with the complete corpus is a decision to defer to
  `ruff-20`, and it should say so rather than guess.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
