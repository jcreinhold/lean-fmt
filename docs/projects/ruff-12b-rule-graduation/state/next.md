# Next Proof Packet

- Stack: ruff-12b-rule-graduation
- First unresolved: 02-evidence
- Claim ID: RGR-EVIDENCE
- Prompt: 02-evidence
- Module: (measurement and audit; no production module change)
- Target file: `results/02-evidence.md`, with audited findings under `evidence/`

## Target Declarations

- (no decls; `RGR-IMPL` owns every catalog edit)

## Read Before Editing

Read this file, `prompts/02-evidence.md`, **`results/01-criteria.md` in full**, `roadmap.md`, and the
named source/manifest ranges only.

`results/01-criteria.md` is the frozen standard. Cite it by section in every verdict. Its §0 discloses
prior exposure to an aggregate firing count and names §2.2 as the criterion that exposure could have
contaminated — read it before judging whether a threshold is fair.

## Proof Task

- Deliver **RGR-EVIDENCE**: run FMT008–FMT017 over the §6 corpus, record firing counts, hand-audit the
  §2.3 sample per rule, exercise the four fixable rules against §3, measure the default-path cost delta
  on both build states against §5, and write a per-rule verdict naming one of §1's four outcomes.
- Each verdict is applied by `RGR-IMPL` without re-deciding anything, so it must name the outcome, the
  criteria sections it cleared and failed, and — for `preview-with-path` — the §1.5 graduation condition
  in the checkable form §4 DOC-3 will render.

## Known Starting Points

- **Runner:** `experiments/run-lifecycle-precision-sample.sh` is the existing harness `ruff-12`'s
  RRL-FINAL used over all ten preview rules on this sample (§6.5). Reuse it; fix it if it is wrong.
- **Corpus:** `experiments/workloads/mathlib-v4.32.0-{sample,stress-largest,tactic,attr,batch-8,remainder}.txt`
  and `lean-fmt-self.txt`. Pins in `experiments/select-mathlib-workload.sh:7-12`.
- **Revision drift (§6.1):** the 62-file list is frozen at mathlib `783ccda4…`/`v4.32.0`, but `ruff-19`
  and `ruff-12` both measured at `8c79cb4f…`/`v4.33.0-rc1`. Record which revision you ran; a
  cross-revision comparison is same-shape, not same-run.
- **`ruff-12`'s precision run wrote raw outputs to a gitignored directory**, so they are not citable.
  §2.3 requires this prompt's audited findings land in `evidence/` with `path:line`, message, and verdict.
- **Integrated workload:** `tests/compiler/LocalSyntax.lean` and `tests/check/{Clean,Findings,Layout}.lean`,
  built with `LeanFmtCompilerPlugin` (`ruff-19/evidence/01-workloads.md` §3.1).

## The two things most likely to decide this prompt

1. **CP-1 (§5.2) rests on an untested prediction** — that the aggregate result cache serves a tier above
   source on a warm hit, so `exact_child == 0` and `exact_setup == 0` survive graduation. No default rule
   has ever demanded a tier above source, so this has never been exercised. Test it early: if it is false,
   the graduation question changes shape and this prompt should stop and say so rather than work around it.
2. **§2.2's exposure threshold may be unreachable by all ten rules.** mathlib is exceptionally clean and
   runs its own linters, which makes it close to the worst available corpus for showing that a hygiene
   rule fires correctly. If that happens it is a finding *about the corpus*, reported as such, not ten
   failures — and the remedy is §6.4 fixtures plus a `preview-with-path` condition naming the corpus that
   would exercise the rule. Lowering the threshold is not a remedy.

## Reuse

- §3's fix audit reuses `ruff-10b`'s composition tests and `tests/syntax/run.sh`, and the existing output
  re-elaboration validator. Do not build parallel machinery.
- §5's cost measurement reuses `ruff-19`'s profile channel and phase names (`gates.sh:16-20`), its
  variance policy, and `tests/performance/gates.sh` predicates.

## Lean Work

This prompt measures and audits; it does not change production Lean. Where it must build a harness or a
focused fixture, inspect the live goal, search relevant declarations, test plausible steps, and verify
completed declarations. Any change to `LeanFmt/Rules.lean` beyond a fixture is out of scope and belongs
to `RGR-IMPL`.

## Stop Rules

- **Do not revise `results/01-criteria.md` to fit a rule.** If a criterion is *wrong* — not inconvenient —
  record the disagreement and how you settled it, per `CLAUDE.md`. A criterion loosened between reading a
  rule's counts and writing its verdict is worse than none, because it carries the appearance of a standard.
- Do not change any rule's implementation to make it pass. A rule needing a repair gets a verdict of
  "not yet, and here is the defect".
- Do not change `defaultEnabled` or `lifecycle` on any rule. That is `RGR-IMPL`.
- Report a zero-firing rule as a finding, not a pass (§2.2).
- Report `phase.exact_child_ms` and its count, `phase.exact_setup_ms`, `phase.official_artifacts_ms`, and
  `cache.index_hits` — not wall time alone. `ruff-19` recorded the same binary on the same warm corpus at
  3,977 ms and 19,968 ms on machine load alone.
- No full mathlib run; that licence is `ruff-20-acceptance`'s alone (§6.6).
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- `LEAN_NUM_THREADS=1 lake build` and the focused suites named by touched modules.
- `tests/boundary/run.sh`; inspect every changed module boundary manually.
- `tests/performance/run.sh` and the suites covering the rules exercised.
- `git diff --check`, read in full, before marking RGR-EVIDENCE verified.
- The KanProofs structural checkers currently fail repo-wide on an `implementation_route` convention no
  lean-fmt stack adopts (`state/current.md`, Blockers). Run them, confirm the failures are that same set
  and no new stack-shaped failure, and record it.
