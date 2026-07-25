# Refusal progression over the frozen 72-path stratified mathlib sample

Measured 2026-07-24 and 2026-07-25. This is a measurement with a date, not a decision. Regenerate it
rather than arguing with it.

| | |
| --- | --- |
| workload | formatter-cache-cold, ordinary-project-built |
| command | `format --check --json`, paths passed explicitly via `run-check-workload.sh` |
| mathlib4 | `3de5ed81cc71b9ea62597b865ba0baaeb5eb0ea9`, clean |
| toolchain | `leanprover/lean4:v4.33.0-rc1` |
| manifest | `experiments/workloads/mathlib-v4.33.0-rc1-stratified.txt`, 72 paths, sha256 `228161c7c359a4b3352b873b649da113e6cf61d1619eaa772732d61da1b1a073` |
| split | three contiguous 24-path thirds in manifest order; concatenating them reproduces that digest |
| guard | `profile-run.sh`, rss 8 GiB / swap 256 MiB / pressure level 1 |

The first third is the same 24 paths `23c` measured
(`experiments/evidence/23c-reflow-refusal-first24.md`, sha256 `3de69dde…3847aea`), so the two runs are
comparable on it.

`profile-run.sh` digests `$1` as the measured binary and the command here is `bash
run-check-workload.sh`, so every `.meta` records `binary=bash` and `binary_digest=unavailable`.
Provenance holds through `lean_fmt_revision`.

## The progression

Each row is one complete pass over all 72 paths. `changed` is `would-format`; `refused` is
`infrastructure-failure`. `written=0` is the mode, not a result — `--check` never writes. `broken=0` in
every pass, so no input was already failing and every refusal is the candidate's fault.

| lean-fmt | what it added | changed | refused |
| --- | --- | --- | --- |
| `2641bb6` | D8, D9 — the two defects 23c measured on the first 24 | 48 | 24 |
| `4d209fc` | D10 — a comment in the one boundary spelled as a forced `align` | 63 | 9 |
| `04b14c0` | D11, D12 — dynamic and twice-escalated quotations as exact islands | 67 | 5 |
| `e4e71ed` | D13, D14, D15 — nested command column; a doc comment's line side; a break in front of a newline | 68 | 4 |
| `3aaa89a` | D16 — a boundary collected inside an exact island | 69 | 3 |
| `800bacc` | D17, D18 — a comment closing an inner block; D9's ungrouped test read off the carrier | **71** | **1** |

Final pass, aggregated over the three chunks:

```
files=72  changed=71  infrastructure_failures=1
broken=0  rejected=0  written=0  suppressed=0  withheld_unsafe=0  withheld_redundant=29  findings=38
```

71 + 1 = 72, so every path is accounted for. Zero rejected and zero broken means no candidate reached
publication that should not have, and no source was already failing.

## What each refusal was

Gate as reported at `2641bb6`, the stack's entry revision.

| path | gate | resolved by |
| --- | --- | --- |
| `Archive/Arithcc.lean` | diagnostics | D18 |
| `Mathlib/AlgebraicTopology/MooreComplex.lean` | diagnostics | D10 |
| `Mathlib/Analysis/Convex/Cone/InnerDual.lean` | diagnostics | D10 |
| `Mathlib/Analysis/InnerProductSpace/l2Space.lean` | diagnostics | D10 |
| `Mathlib/Analysis/SpecialFunctions/Exponential.lean` | diagnostics | D10 |
| `Mathlib/Computability/AkraBazzi/SumTransform.lean` | diagnostics | D10 |
| `Mathlib/Geometry/Manifold/MFDeriv/UniqueDifferential.lean` | diagnostics | D10 |
| `Mathlib/LinearAlgebra/Matrix/Adjugate.lean` | diagnostics | D10 |
| `Mathlib/Logic/ExistsUnique.lean` | formatter | D11/D12 |
| `Mathlib/MeasureTheory/Integral/IntervalIntegral/AbsolutelyContinuousFun.lean` | diagnostics | D10 |
| `Mathlib/MeasureTheory/Integral/SetToL1.lean` | diagnostics | D10 |
| `Mathlib/NumberTheory/LSeries/HurwitzZetaEven.lean` | diagnostics | D10, then D18's second half |
| `Mathlib/NumberTheory/PythagoreanTriples.lean` | diagnostics | D10 |
| `Mathlib/Order/Filter/AtTopBot/Tendsto.lean` | comments | D14 |
| `Mathlib/Probability/Kernel/Composition/IntegralCompProd.lean` | diagnostics | D10 |
| `Mathlib/RingTheory/Jacobson/Ring.lean` | diagnostics | D10 |
| `Mathlib/Tactic/CrossRefAttribute.lean` | formatter | D11/D12 |
| `Mathlib/Tactic/Linter/ValidatePRTitle.lean` | diagnostics | D13, then D17 |
| `Mathlib/Tactic/WLOG.lean` | formatter | D11/D12 |
| `Mathlib/Topology/Algebra/Nonarchimedean/Completion.lean` | diagnostics | D10 |
| `Mathlib/Topology/Order/LeftRightNhds.lean` | diagnostics | D10 |
| `Mathlib/Util/ParseCommand.lean` | formatter | D11/D12, then D16 |
| `Mathlib/Util/Superscript.lean` | comments | D14 |
| `MathlibTest/Linter/LongFile.lean` | diagnostics | not repaired — see below |

## Two repairs regressed a file the sample had already cleared

Both were found only by the whole-sample pass, not by the fixture the repair was written against, and
both are recorded here because that is the argument for running the whole sample after each repair.

- **`Mathlib/Util/ParseCommand.lean`.** Cleared by D11/D12, refused again at `e4e71ed` with
  `applied 0/2 boundaries`. D13's nested-command rule collected a boundary start inside a
  `` `(command| …) `` quotation, which is an exact island that spells its own bytes and lets no boundary
  through — and every collected boundary must be applied or the command is refused. Repaired as D16.
- **`Mathlib/NumberTheory/LSeries/HurwitzZetaEven.lean`.** Cleared by D10, refused again at the first
  D18 commit (`368eb16`) with D9's original signature. That commit read D9's ungrouped test off the
  sequence's immediate parent; `show T by tac; tac` reaches its sequence through `Term.byTactic'`,
  which owns no group, so the test declined a boundary the `show`'s group needed. Repaired in
  `800bacc`.

## Guard readings

Every pass reported in the table above completed with `hard_stop=none`, `peak_pressure_level=1`, and
non-positive `swap_delta_kib`. Peak RSS per chunk ranged 3.91–4.80 GiB against the 8 GiB limit.
`exit_status=2` on any pass with a refusal is the documented infrastructure-failure code
(`docs/ci.md:62`), not a crash.

Final pass, per chunk:

| chunk | hard_stop | peak rss | swap delta | peak pressure |
| --- | --- | --- | --- | --- |
| c1 | none | 3.91 GiB | −24 MiB | 1 |
| c2 | none | 4.46 GiB | −72 MiB | 1 |
| c3 | none | 4.08 GiB | −24 MiB | 1 |

Five chunk attempts were stopped by the guard at `hard_stop=pressure` while an unrelated process on the
machine held several GiB. They are discarded, not reported: a run the guard stopped measured nothing.
Wall time is in the `.meta` files and is deliberately not compared across rows — the same 24 paths on
the same binary measured 96 s and 208 s depending only on what else the machine was doing.

## `MathlibTest/Linter/LongFile.lean` is not a formatter defect

It is a `#guard_msgs` test for mathlib's own `linter.style.longFile`, and the message it asserts names
the file's line count. Any reflow changes the line count, which changes the linter's message, which
makes the candidate's own `#guard_msgs` fail — so the diagnostics gate refuses. The gate is right: the
candidate does not elaborate cleanly, and publishing it would break the file.

This is the *unrelated frontend/project failure* class the prompt's execution discipline names. There is
no adapter invariant to fix; a formatter that reflowed the file and passed would be the defect.

## What this does and does not say

It says 71 of 72 stratified mathlib paths now reflow and validate under the exact module setup, that
nothing was written, that no candidate was rejected or already broken, and that the one refusal is a
file whose own test asserts its line count.

It does not say the adapter is finished. It is a count over 72 files chosen for stratification, not a
rate over mathlib, and the one full run it authorizes is Prompt 24's.
