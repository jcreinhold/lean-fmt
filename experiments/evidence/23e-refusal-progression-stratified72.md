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
| corpus content | sha256 `71d462334bc3be7bc7d62cf64925955aedb1e5a923c05b575162c1d2436f6620`, from `cat $(cat <manifest>)` in the mathlib checkout, manifest order |
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
| `3671d63` | D19, D20 — two separators a document spelled that the adapter already owns | **71** | **1** |

Final pass, aggregated over the three chunks:

```
files=72  changed=71  infrastructure_failures=1
broken=0  rejected=0  written=0  suppressed=0  withheld_unsafe=0  withheld_redundant=29  findings=38
```

D19 and D20 change no verdict — both are style defects in candidates that already validated — so the
last two rows are identical in every count the gates produce. What they change is the bytes, and that
is the next section.

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

Final pass (`3671d63`), per chunk:

| chunk | hard_stop | peak rss | swap delta | peak pressure |
| --- | --- | --- | --- | --- |
| c1 | none | 4.26 GiB | −243 MiB | 1 |
| c2 | none | 4.45 GiB | −152 MiB | 1 |
| c3 | none | 4.08 GiB | −1,697 MiB | 1 |

Eleven chunk attempts were stopped by the guard at `hard_stop=pressure`, most while an unrelated
process on the machine held several GiB. They are discarded, not reported: a run the guard stopped measured nothing.
Wall time is in the `.meta` files and is deliberately not compared across rows — the same 24 paths on
the same binary measured 96 s and 208 s depending only on what else the machine was doing.

## Style of the accepted candidates

The gates say a candidate elaborates; they say nothing about whether it reads well. This is that
inspection, run over the concatenated text of all 71 accepted candidates rather than over a sample of
diffs, because the properties worth asserting are countable.

| property | at `800bacc` | at `3671d63` |
| --- | --- | --- |
| lines | 22,031 | 21,893 |
| top-level declaration lines | 1,883 | 1,883 |
| …of those, indented rather than at column zero | 0 | 0 |
| lines ending in whitespace | 1 | **0** |
| runs of two consecutive blank lines | 139 | **2** |
| …in the corresponding sources | 10 | 10 |

The two findings behind the last two rows are D19 (`moduleDoc` ends with `ppLine`, so every module
docstring gained a blank line below it) and D20 (`docComment` ends with `ppLine` too, so a doc comment
used as a tactic's own syntax left a line holding nothing but its list's indent). Both are recorded in
`experiments/native-layout-defects/README.md`. Neither was caught by any gate, and neither could have
been: a blank line and a trailing space change no token, so the structural, comment, diagnostics and
source-map gates all pass, and the candidate is byte-stable under a second pass because the second pass
reproduces the same extra bytes.

After the repairs no candidate holds more blank-line runs than its own source, and the two that remain
are in files whose sources hold more.

Documentation, structure fields, records and offside blocks keep their hierarchy by construction here:
the offside constraints are what `tests/native-layout/run.sh` §6 asserts per construct, and §1b renders
every fixture at widths 20 and 40. Narrow-width output is not pathological — the width-20 and width-40
renders of all four fixture modules validate, and the suite reads named columns out of them rather than
only checking that they parse.

## Changes and width-driven reflow, per named construct family

The acceptance bar asks for nonzero changes *and* width-driven reflow across every construct family the
corpus was built to cover. This is that measurement, in two parts.

**Coverage and change** is a grep over the 72 sources — a syntactic predicate per family, not a parse,
so read `paths` as "sources whose text matches", not as a parser's answer. `changed` excludes
`MathlibTest/Linter/LongFile.lean`, the single refusal, and is otherwise equal to `paths` because 71 of
72 changed.

**Width-driven reflow** is a second run of the smallest covering path per family through
`format - --stdin-filename <path> --root <mathlib>` at `line-width` 100 and 60, comparing candidate
bytes. Ten distinct paths cover eighteen families. A family is satisfied by any covering path whose
candidate differs from its source *and* differs between the two widths; the table names the one used.

| family | paths | changed | width representative | lines 100 → 60 |
| --- | --- | --- | --- | --- |
| command | 70 | 69 | `Mathlib/Algebra/Divisibility/Hom.lean` | 38 → 41 |
| term | 59 | 59 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| tactic | 63 | 62 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| `do` | 15 | 15 | `Mathlib/FieldTheory/Galois/Notation.lean` | 54 → 64 |
| offside | 45 | 45 | `Mathlib/Algebra/Divisibility/Hom.lean` | 38 → 41 |
| records | 48 | 48 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| declarations | 67 | 67 | `Mathlib/Algebra/Divisibility/Hom.lean` | 38 → 41 |
| comments | 39 | 38 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| docstrings | 61 | 60 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| quotations | 24 | 24 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| antiquotations | 14 | 14 | `Mathlib/FieldTheory/Galois/Notation.lean` | 54 → 64 |
| parser definitions | 7 | 7 | `Mathlib/FieldTheory/Galois/Notation.lean` | 54 → 64 |
| interpolated literals | 3 | 3 | `Mathlib/Tactic/Linter/ValidatePRTitle.lean` | 165 → 196 |
| custom notation | 2 | 2 | `Mathlib/FieldTheory/Galois/Notation.lean` | 54 → 64 |
| explicit/descriptor formatters | 2 | 2 | `Mathlib/FieldTheory/Galois/Notation.lean` | 54 → 64 |
| macro density (≥3 syntax-defining commands) | 3 | 3 | `Mathlib/Logic/ExistsUnique.lean` | 171 → 216 |
| Unicode | 70 | 69 | `Mathlib/Algebra/Divisibility/Hom.lean` | 38 → 41 |
| large files (≥800 lines) | 2 | 2 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` | 1395 → 1874 |
| `choice` | see below | | `Mathlib/Util/DischargerAsTactic.lean` | 33 → 38 |
| `#exit` | 1 | **0** | — see below | |

Two families are not greppable and are measured or attributed separately.

**`choice`.** A `choice` node is a parse, not a spelling, so no predicate over the text finds one. It
was measured instead with `__analyze-exact` over the ten width representatives, reading
`artifact.syntaxData.kinds` — the same field `tests/lossless/run.sh` reads to prove its own `choice`
fixture non-vacuous. One of the ten, `Mathlib/Util/DischargerAsTactic.lean`, holds a `choice` node; it
changed and it reflows (33 → 38 lines). One in ten agrees with the rate `CLAUDE.md` already records
(1 of 5 sampled modules), and it means the corpus exercised `NativeLayout.command`'s
`choiceDisagreement?` gate on real input rather than only on the synthetic case.

**`#exit`.** Exactly one manifest path contains `#exit`, and it is `MathlibTest/Linter/LongFile.lean`,
the single refusal — so the corpus contributes *no* changed `#exit` candidate, and this row is a
genuine gap in the corpus rather than a passing measurement. The family's durable evidence is
elsewhere and predates this prompt: `tests/module-formatter/run.sh` builds a module whose commands
precede a `#exit` with a deliberately unparseable tail, drafts it at **width 72**, and asserts
`nativeDocuments == commands`, `alignedTokens > commands`, `terminalStop < sourceBytes`, that the
candidate ends with the raw tail byte-for-byte, and that the source map tiles source and output with no
gap. That is reflow at a narrow width over a `#exit` module through this adapter; the corpus adds
nothing to it. A second case in the same suite covers a terminal-only module (`commands == 0`,
`headerStop == terminalStop`, candidate identical to source).

**exact/artifact equality** is not applicable to this corpus: mathlib is not formatter-integrated, so
every path here took the exact route and there is no artifact route to compare it against. Where it
*is* applicable it is gated durably rather than measured here — `tests/compiler/run.sh` `cmp`s the
artifact-route and exact-route diffs of `tests/compiler/ArtifactLayout.lean` byte-for-byte while
proving the two took different routes (`cache.path_artifact_render=1` versus
`cache.path_exact_render=1`), and `tests/performance/run.sh` §1e asserts the two reports are
byte-identical while the artifact route launches zero exact-source children.

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
