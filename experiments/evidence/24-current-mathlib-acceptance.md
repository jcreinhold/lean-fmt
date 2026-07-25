# Current-mathlib acceptance over a budgeted stratified sample

Measured 2026-07-24 and 2026-07-25. This is a measurement with a date, not a decision. Regenerate it
rather than arguing with it.

Prompt 24 (`LFF-MATHLIB`). Cache-cold passes of `format --check` over a frozen stratified sample of
the current mathlib checkout, reported against the ten acceptance dimensions of
`notes/02-contract-and-corpus.md`, kept separate rather than compressed into a pass rate.

Two passes are reported. The **audit pass** at lean-fmt `34b89e6c` is what found the defects; the
**confirmation pass** at `2192d066c7171bea51abc006500a4426d2b62741` is the one pass taken after the
repairs, which the stack's stop rule allows exactly once. Both are the same manifest and the same
command.

## Run identity

| | |
| --- | --- |
| mathlib4 | `3de5ed81cc71b9ea62597b865ba0baaeb5eb0ea9` |
| toolchain | `leanprover/lean4:v4.33.0-rc1` |
| lean-fmt, audit pass | `34b89e6c51ef2c8ca3f627a69037be1684a0b655` |
| lean-fmt, confirmation pass | `2192d066c7171bea51abc006500a4426d2b62741` |
| confirmation-pass binary digest | `742f0ce0288ec363fad3560a338a0858a175e4bc91b8674f84b1f7f578ce66b5` |
| workload | formatter-cache-cold, ordinary-project-built |
| command | `format --check --json --no-cache --max-memory 6 --statistics`, `LEAN_FMT_PROFILE_PHASES=1` |
| driver | `experiments/profile-run.sh` → `experiments/run-check-workload.sh`, six chunks of 44 |
| guard | 8 GiB aggregate RSS, 256 MiB new swap, pressure level 1 |

The confirmation-pass revision is `2192d06`; the binary is the one built at `3bfeafe`, since
`2192d06` edits only a markdown file. The binary digest is recorded rather than inferred from the
revision, which is why that distinction is visible at all.

**mathlib was not written to, before or after.** `git diff --stat` over tracked files is empty and
no `.lean` file appears in `git status --porcelain`; the single status entry is the product's own
untracked cache directory, `?? .lean-fmt-cache/`. mathlib's `HEAD` was captured before and after each
pass and compared: a checkout move during a run is a stop condition, and only the before/after pair
can show one did not happen.

## The corpus is a sample, and why

The full checkout is 8,815 files / 99,775,104 bytes and the frozen full manifest
`experiments/workloads/mathlib-v4.33.0-rc1-full.txt` (path digest `7478847b…a948fd`, content digest
`568c0b9c…ab52da`) remains in the tree for it. The cache-cold exact path costs, measured from a
50-path reference chunk (231,125 B, 304 s wall, `phase.exact_child_ms=293685` over 50 children,
`phase.child_analyze_ms=152835` over the 45 that reached analysis):

    fixed   = (293685 - 152835) / 50 = 2.82 s per file    child spawn + import-closure load
    analyze = 206452 B / 152.835 s   = 1351 B/s           exact frontend

    8815 x 2.82 s + 99,775,104 B / 1351 B/s = 27.4 h

That is mathlib being elaborated one module at a time, not a defect, and neither available lever
closes it: a second concurrent child needs its own 4–6 GiB import closure and would breach the 8 GiB
aggregate stop rule, and the artifact path is unavailable because mathlib is not built under the
compiler plugin — `cache.official_artifact_miss` equals the target count on every chunk. The run was
capped at 60 minutes at the user's direction, so it takes a sample.

`experiments/workloads/mathlib-v4.33.0-rc1-audit.txt` — 264 paths / 2,641,584 bytes, path digest
`41c6db5bfa8a6ca7c0c356c127b8c5a0092066e22c656063a87b33e6b9348eb0`, content digest
`cd965e36c1564aa39fd983bcec7903a6ffd4926e2d9eb4ca91c3d6b9b89c8d32`. It is built deterministically
(sha256 of the path as the within-group order; no RNG, so a rerun reproduces it byte for byte) with
coverage **front-loaded**, so any executed prefix is a valid audit set rather than an arbitrary
truncation:

| block | n | content |
| --- | --- | --- |
| A | 72 | 23e's verified stratified manifest, entire — the direct comparison |
| B | 72 | four covering paths per construct family from *outside* A, smallest first, so no family is tested only on files already known clean |
| C | 11 | one path per size decile of the full corpus, plus the largest file in the checkout |
| D | 109 | proportional round-robin over top-level mathlib directories |

All 19 construct families are covered, the top directories appear in corpus proportion (Algebra 50,
CategoryTheory 29, Data 26, Tactic 24, Analysis 21, Topology 20, RingTheory 19, …), and block A is
contained exactly. The manifest file itself is byte-sorted, because `profile-run.sh:71` requires
every source manifest to pass `LC_ALL=C sort -c`; chunk *membership* still follows the sample order,
so chunk k holds sample items 44k..44k+43 and a truncated run keeps the front-loaded coverage. Order
within a chunk cannot change a result — each file is analyzed by its own child.

### What the sample does not establish

264 of 8,815 files is 3.0% by count and 2.6% by bytes. These runs can show that no sampled construct
refuses and that the style properties hold over what ran. They **cannot** show that no file among
the remaining 8,551 refuses. That is a reduction against the prompt's "run the full selected project
once", made at the user's explicit direction after the 27.4 h measurement, and it is recorded here
rather than papered over. The full manifest and its digests are frozen, so the full run can be made
later with no new setup.

### The envelope is 6 GiB, and 4 GiB manufactured a 78% refusal rate

The first landed chunk invalidated itself. At `--max-memory 4`, 39 of 50 files came back
`infrastructure-failure`, every one reading

    resource envelope exhausted during exact frontend child (4215840 KiB > 4194304 KiB)

and every measurement clustered between 4.003 and 4.17 GiB against a 4.0 GiB envelope. A
mathlib-importing module carries a ~4 GiB baseline environment into the exact frontend, so a 4 GiB
envelope fails on the *environment* before the file's own cost is reached. Not one of the 39 named a
validation gate. Reported as-is that would have been a 78% refusal rate against a formatter that
scored 71 of 72 on the stratified sample. The envelope is 6 GiB: above the observed baseline, still
below the guard's 8 GiB aggregate limit. The 4 GiB chunk's outputs were deleted rather than kept — a
report that measures the harness is not evidence about the product — and its progress log is
retained.

## The ten dimensions

### 1. Frontend success and diagnostics

264 of 264 manifest paths reported in both passes; nothing left the run without a verdict.

| | audit pass | confirmation pass |
| --- | ---: | ---: |
| would-format | 235 | 241 |
| clean | 6 | 8 |
| infrastructure-failure | 23 | 15 |
| — of those, envelope exhaustion (a harness limit) | 12 | 12 |
| — of those, formatter verdicts | 11 | **3** |

The audit pass's eleven formatter verdicts split by gate as `formatter` 6, `diagnostics` 4, `tokens`
1. The confirmation pass's three are `diagnostics` 2, `formatter` 1, and they are exactly the three
the repairs did not claim to fix:

| path | gate | why it is not a defect |
| --- | --- | --- |
| `MathlibTest/FindDeprecations.lean` | `diagnostics` | its `#guard_msgs` asserts message *positions* (`info: [134, 170, 171]`), which any reformat moves |
| `MathlibTest/Linter/LongFile.lean` | `diagnostics` | its `#guard_msgs` asserts this file's own line count |
| `MathlibTest/Tactic/SolveByElim/DummyLabelAttr.lean` | `formatter` | D21, a `_root_` component in a node kind — upstream, diagnosed, refused by name |

Every verdict in both passes refused rather than published: `written` is 0 on every chunk of both
passes, so no defect this audit found ever reached a file.

The twelve envelope exhaustions are the harness, not the formatter, and they are the **same twelve
paths in both passes**. Every one is an import-heavy module — `Mathlib.lean`,
`MathlibTest/ImportAll`, `MathlibTest/LibrarySearch/mathlib`, `DownstreamTest/DownstreamTest`,
`MathlibTestExecutable`, `symbolFrequency`, the four `MathlibTest/Tactic/Grind/*`,
`InstanceDiamonds/…/WithAbs`, `Instances/ComputableShortcuts` — so the cost is the baseline
environment rather than the file.

Each names both numbers, and every one lands within 0.16 GiB of the 6.00 GiB bound: the largest is
`MathlibTest/LibrarySearch/mathlib.lean` at 6.10 (audit) and 6.16 (confirmation), the smallest sit
exactly at 6.00. The spread between passes on the same file is the environment's own variance, which
is the shape of a bound just barely exceeded rather than a file that needs much more.

#### Raising the envelope to 7 GiB does not admit them, and the reason is in the accounting

The twelve were re-measured on their own manifest at `--max-memory 7`, the largest envelope that
still leaves the run under the 8 GiB aggregate stop rule (`experiments/workloads` has no manifest
for this; it is `audit/manifests/heavy12.txt`, source digest `df41c1f1…f0d885`, 213 s, peak RSS 7.07
GiB, swap delta **−90,112 KiB**, `hard_stop=none`).

**All twelve exhausted again, and each landed just above the new bound**: 7.00 to 7.15 GiB against
7.00 GiB, the same shape as 6.00–6.16 against 6.00 GiB. The trip point tracks the *bound*, not the
file. So the 6 GiB numbers are not a per-file requirement, and there is no envelope inside the 8 GiB
budget that admits these modules — a conclusion the 6 GiB run alone could not distinguish from "they
need 6.2 GiB".

The accounting explains it. `--max-memory` is used twice with the same number:

- the child is told it may use all of it — `Lean.Internal.setMaxMemory maxBytes.toUSize`, at every
  child entry point (`LeanFmt/Application.lean:2015`, `:2036`, `:2108`, `:2124`);
- the parent trips on **parent RSS + the child's process-group RSS** against that same `maxBytes`
  (`:354-357`).

The child therefore grows toward a ceiling the parent has already spent part of, and the overshoot
at trip time — 0.00 to 0.16 GiB in both runs — is the parent's own footprint plus one 50 ms poll's
growth. Any module whose child legitimately needs close to the envelope trips, at every envelope.

This is a product observation, not a formatter defect: it refuses loudly, publishes nothing, and its
twelve files are the corpus's import-heaviest. It is **handed to Prompt 26** (final performance
audit) as a named finding rather than repaired here, because changing envelope accounting is a
product-behaviour change outside this prompt's scope. Recorded so 26 starts from a measurement.

### 2. Unsupported formatter nodes

**Zero, in both passes.** `unsupported` is 0 on every chunk. No node reached the adapter without a
formatter; every refusal below is a gate verdict, not an unsupported node.

### 3. Changed files and changed commands

| | audit pass | confirmation pass |
| --- | ---: | ---: |
| changed | 235 | 241 |
| written | 0 | 0 |
| findings | 113 | 115 |
| withheld-redundant / withheld-unsafe | 98 / 0 | 100 / 0 |
| suppressed | 0 | 0 |

`written` is 0 because the command was `format --check`, which never writes. That it is 0 is the
measurement that `--check` was honoured, not an assumption about it.

Changed *commands* are not separately counted: `format --check` reports per file and the JSON
carries no per-command changed flag. The nearest measurement this run does make is the candidate
line delta per file, which dimension 7 uses.

### 4. Structural equivalence failures

**Zero.** `rejected` is 0 on every chunk of both passes, and `broken` is 0 — no source was already
failing, so every refusal is the candidate's fault and none of them is a structural one.

### 5. Comment payload and ownership failures

**Zero in both passes.** No refusal in either pass named the comment gate. The `tokens` gate refusal
the audit pass did carry — `Mathlib/Tactic/ClickSuggestions/ApplyAt.lean`, `token 451
(ProofWidgets.Jsx.jsxText) changed spelling` — is a whitespace-significant *token* payload, not a
comment, and is D25, repaired in `153ef88`.

Comment placement is the property with the least margin for a silent failure, because a misplaced
comment reparses fine. The gate that catches it is exact: each comment's payload is matched by
position and counted, so a comment emitted twice or dropped is a refusal rather than a diff. It
fired on no mathlib file in either pass, and `tests/native-layout/run.sh` §4 holds 45 assertions
naming individual comments — including the three D26 and D14 shapes this campaign added.

### 6. Second-pass byte differences

**Zero in both passes.** The idempotence gate reformats every accepted candidate and refuses on any
byte difference; `rejected` is 0 throughout, so no candidate moved on a second pass.

This is the dimension that caught the first attempt at D22's repair. Keying the `.flat` boundary on
each binder's *start* left a break inside a single binder (`{g₁\n      g₂}`), so round two no longer
saw a one-line run and formatted it differently — `ValidationGate.idempotence: formatting the
reparsed candidate changed bytes`. The gap-based keying that shipped is a fixpoint by construction.
That the dimension reads zero here is a result of a failure it reported, not of never having been
exercised.

### 7. Width-sensitive reflow coverage by construct

A formatter that echoed its input would satisfy every idempotence and validity gate in this run. The
distinguishing measurement is whether the *same* file lands at a different line count under a
different `line_width`, per construct family, so no family is presumed to reflow because another one
does. Each family's representative is the smallest sampled path that covers it, preferring paths
that cover the most families at once so one render settles several rows; a representative that
refuses or times out is retried once with the next candidate.

Rendered under `line_width = 100` and `line_width = 60`, `format --check --json` on the same source,
counting lines of the candidate:

| family | paths | representative | 100 → 60 | verdict |
| --- | --- | --- | --- | --- |
| command | 247 | `Mathlib/Tactic/CrossRefAttribute.lean` | 432 → 479 | reflows |
| term | 186 | " | 432 → 479 | reflows |
| tactic | 203 | " | 432 → 479 | reflows |
| do | 50 | " | 432 → 479 | reflows |
| offside | 218 | " | 432 → 479 | reflows |
| records | 162 | " | 432 → 479 | reflows |
| declarations | 224 | " | 432 → 479 | reflows |
| comments | 113 | " | 432 → 479 | reflows |
| docstrings | 203 | " | 432 → 479 | reflows |
| quotations | 81 | " | 432 → 479 | reflows |
| antiquotations | 38 | " | 432 → 479 | reflows |
| parser-definitions | 32 | " | 432 → 479 | reflows |
| interpolated | 9 | " | 432 → 479 | reflows |
| formatters | 7 | " | 432 → 479 | reflows |
| unicode | 238 | " | 432 → 479 | reflows |
| macro-density | 9 | " | 432 → 479 | reflows |
| custom-notation | 9 | `Mathlib/Data/Opposite.lean` | 116 → 129 | reflows |
| large-files | 10 | `MathlibTest/Tactic/Linarith/Basic.lean` | 928 → 1153 | reflows |
| exit | 1 | — | — | **unmeasurable on mathlib** |

19 of 20 families reflow. The line count *rises* as the width falls, in every case, which is the
direction a real layout engine moves and the direction an echo cannot move at all.

The coverage-first representative selection is why sixteen rows name one file:
`CrossRefAttribute.lean` genuinely contains all sixteen constructs, and one 2-minute render settling
sixteen families is what brought this measurement inside the wall-clock budget. It is weaker
evidence than sixteen distinct representatives would be — it shows those constructs reflow *in that
file*, not in every file that holds them — and that is the trade the budget bought.

`exit` is not a gap that better sampling closes. The entire checkout holds exactly one file with a
top-level `#exit` — `MathlibTest/Linter/LongFile.lean` — and that file is a linter test whose
`#guard_msgs` asserts a diagnostic about its own line count, so any reflow changes the assertion and
the validator correctly rejects the candidate. Family coverage over all 8,815 paths finds no second
instance; a direct `grep -rl` finds two more, both `--` comments in linter sources that *discuss*
`#exit`. The construct is unmeasurable *here* for a reason specific to its only instance, and it is
separately gated in this repository by `tests/cache/project/Fixture/Exit.lean`,
`tests/formatter/fixtures/Contract.lean`, and assertions in `tests/lossless`,
`tests/module-formatter`, `tests/comments`, `tests/modes` and `tests/stream`.

#### The family predicates

23e published a per-family coverage table but its generating script was not kept, so the predicates
were rewritten in `full/families.py` with every regex and its justification in the file. They were
not tuned until the numbers matched — fitting regexes to an uninspectable target manufactures
agreement. **13 of 19 families reproduce 23e's published count exactly**; six differ (term 65 vs 59,
offside 66 vs 45, records 59 vs 48, quotations 23 vs 24, formatters 3 vs 2, macro-density 4 vs 3),
broader in five and narrower in one. Two predicates were changed because the obvious spelling
measures nothing: `offside` as "any indented line" matches 100% of sources and is now a block opener
at end of line; `comments` as `(--|/-)` counts every docstring and is now matched against the source
with block spans removed, which lands on exactly 39 — 23e's published number.

### 8. Cache, artifact and frontend path counts

`--statistics` does not answer this dimension. `renderStatistics` (`LeanFmt/Cli.lean:969-973`)
prints exactly the counters `RunReport` already carries — `mode`, `files`, `findings`, `changed`,
`written`, `broken`, `rejected`, `withheld_unsafe`, `suppressed`, `infrastructure_failures` — a
stderr restatement of the JSON, with no route counts at all. The route counts live on the profile
channel, `LEAN_FMT_PROFILE_PHASES=1`, whose schema `tests/performance/gates.sh` pins. `--statistics`
is kept as an independent restatement of the JSON counters, which is a cheap cross-check on the
aggregator.

Audit pass, summed over the six chunks' `.stats`:

| counter | audit pass | confirmation pass |
| --- | ---: | ---: |
| `cache.targets` | 264 | 264 |
| `cache.active_children` | 264 | 264 |
| `cache.path_exact_render` | 241 | 249 |
| `cache.path_validation_failure` | 11 | 3 |
| `cache.path_cache_hit` | 0 | 0 |
| `cache.path_artifact_render` | 0 | 0 |
| `cache.index_hits` / `cache.served` | 0 / 0 | 0 / 0 |
| `cache.official_artifact_hit` / `_miss` | 0 / 264 | 0 / 264 |

`official_artifact_miss` equal to the target count is the *measured* form of "mathlib is not
formatter-integrated", so the artifact path count is zero by evidence rather than by assertion.

The route counters are checked as a partition rather than only tallied, because a target that takes
no route is a silent drop. In the audit pass they cover **252 of 264**, and the twelve-target
shortfall is exactly the twelve envelope exhaustions: those children were killed before any route
counter was reached, so the shortfall is accounted for by name rather than unexplained. Any *other*
shortfall would be a stop condition.

### 9. Incremental snapshot reuse and invalidation counts

**Not exercisable by this run**, and reporting it as a pass would be vacuous. Incremental snapshot
reuse is an LSP/in-process property; a batch run under `--no-cache` reuses nothing by construction,
so `cache.targets`/`index_hits`/`served` read zero. The durable gates that own it are
`tests/performance/run.sh` §1 — a warm run fully cache-served, `hits == served == targets`, with
`gate_no_frontend_work` proving neither the exact frontend nor per-target setup runs — and
`tests/incremental/run.sh`. This is how 23e handled exact/artifact equality, for the same reason.

### 10. Output digest

sha256 over every accepted candidate's bytes, concatenated in frozen-manifest order:

| | audit pass | confirmation pass |
| --- | --- | --- |
| candidates | 235 | 241 |
| bytes | 2,177,787 | 2,232,257 |
| digest | `e860a0a1b55a4cea793f350c45669f2892a93b4a8399dbd44795cad65a7b125a` | `f181a6e424daed1f00a2c8ddc26b3b95f6387b7e790085795b6bdc2302dc57ad` |

The two digests differ, and that is the point: eight files that refused under the audit binary now
produce candidates, and D24/D27/D25's repairs changed the columns of files that were already
accepted. A digest that had *not* moved would mean the repairs did nothing. The value is recorded so
a later run of the same manifest against the same revision can be compared byte for byte.

## Exact/artifact byte agreement is not exercisable here either

The prompt's Check clause asks for it, and this corpus cannot supply it. The artifact route needs
the target project built **under the compiler plugin**, and mathlib is built ordinarily. The
measured form of that is `cache.official_artifact_miss = 264 = targets` and
`cache.path_artifact_render = 0` on every chunk: the artifact route was not merely unused, it was
unavailable, and the run says so with a counter rather than with a claim. Building mathlib under the
plugin is a multi-hour rebuild of the whole checkout and would change the workload being measured.

The durable gate that owns byte agreement is `tests/performance/run.sh` §1d/§1e, on a fixture this
repository *does* build under the plugin: `gate_reports_identical` asserts the artifact-route and
exact-route `diff` reports are byte-identical, and `gate_artifact_avoids_exact` asserts the artifact
run spawned one artifact child and zero exact-source children — so the two reports agreeing is not
the same route measured twice. `tests/compiler/run.sh` owns the facet itself. 23e resolved the same
gap the same way. Recorded as **not exercisable on this corpus**, not as a pass.

## Style properties no gate can see

D19 and D20 exposed properties that are invisible to every gate: a blank line and a trailing space
change no token, and the candidate is byte-stable under a second pass. They are counted over the
accepted candidates against the same predicates applied to the sources they came from — a baseline
computed with a different predicate is not a baseline.

Source-side baseline over all 8,815 paths (`full/baseline.py`):

| | sources |
| --- | ---: |
| lines | 2,376,854 |
| column-zero declarations | 255,509 |
| lines ending in whitespace | **0**, in 0 files |
| runs of two blank lines | 4,359, in 2,758 files |
| tight bracket/keyword spellings | **1**, in 1 file |

Two of these change how the run's numbers read. **mathlib has zero trailing whitespace corpus-wide**
— it has a linter for it — so the baseline is exactly zero and any trailing whitespace in a
candidate is formatter-introduced with no ambiguity. **Double blank lines are not zero**, so a
candidate count must be compared per file against its own source; comparing against zero would
report mathlib's own style as a defect. The one tight spelling is `Mathlib/Util/TransImports.lean`
(`]at`), so only an *increase* is attributable to the formatter.

Over the audit pass's 235 accepted candidates, against the same predicates applied to those same 235
sources:

| | candidates | their sources |
| --- | ---: | ---: |
| lines | 55,633 | — |
| lines ending in whitespace | **0** | 0 |
| runs of two blank lines | 4 | 104 |
| files that *gained* a double blank line | **0** | — |
| column-zero declarations | 5,916 | 5,766 |
| files that *lost* one | 2 | — |
| files that gained a bracket/keyword collision | 2 | — |

Zero trailing whitespace over 55,633 candidate lines, against a corpus-wide source baseline of
exactly zero, is the strongest of these: there is no ambiguity to hide in.

The double-blank count *falls* from 104 to 4 and no file gains one, so the formatter removes
mathlib's own double blank lines and introduces none. Removing them is a layout decision this
product makes; it is reported here as a user-visible consequence rather than as a defect.

The two files that lost a column-zero declaration are D24 — `MathlibTest/Tactic/Linarith/Basic.lean`
(157 → 155) and `MathlibTest/Linter/Multigoal.lean` (25 → 23), a comment between `#guard_msgs in`
and its nested command defeating D13's dedent. Both were `would-format`, so both candidates were
publication-eligible with a top-level declaration indented, and no gate could see it — the candidate
reparses identically. That is what this dimension exists to catch. Repaired in `10cf1f2`; `24e2e2d`
repairs D27, found by that repair.

The same counts over the confirmation pass's 241 candidates:

| | candidates | their sources |
| --- | ---: | ---: |
| lines | 56,778 | — |
| lines ending in whitespace | **0** | 0 |
| runs of two blank lines | 4 | 105 |
| files that *gained* a double blank line | **0** | — |
| column-zero declarations | 5,997 | 5,843 |
| files that *lost* one | **0** | — |
| files that gained a bracket/keyword collision | 2 | — |

The row that moved is *files that lost a column-zero declaration*, **2 → 0**: D24's repair, measured
on the same predicate that found it. Six more files reach a candidate and the trailing-whitespace
and double-blank properties hold across all 241.

### D7 fires on ordinary mathlib

`Mathlib/Tactic/Ring/NamePolyVars.lean` and `Mathlib/Tactic/Ring/NamePowerVars.lean` both render

    for h : idx in [:size]do

D7 is pinned and known (`experiments/native-layout-defects/README.md`); this is its first
measurement on real sources — 2 of the audit pass's 235 candidates, against a source-side baseline
of 0 collisions in all 264.

**Adjacency is not exposure.** A closing bracket followed by a space and one of the seven keywords
occurs 26,473 times in 4,691 sources — 53% of the corpus — and that is *not* 26,473 places D7 can
fire. 23e's 71 accepted candidates contain zero collisions while certainly containing `] at` (`simp
[h] at h'` is everywhere), because in the ordinary case the separator is emitted by the syntax
tree's own formatter and never reaches the `pushToken` decision D7 is about. The broad predicate is
still the right *detector*, since each candidate is compared against its own source and only an
increase is reported, but the adjacency count must not be quoted as a D7 exposure estimate.

### Attributes always move to their own line, and that is upstream

`Lean/Parser/Command.lean:114-121`: a top-level `declaration` uses `declModifiers false`, so the
attribute list is followed by a **hard** `ppLine`, not a discretionary break a wider line could
flatten. `inline := true` exists and is used for structure fields, `let rec` and binders, so the
distinction is deliberate upstream. Measured over 23e's 71 accepted candidates:

| | source | candidate |
| --- | --- | --- |
| attribute on the same line as its declaration | 56 | **0** |
| attribute alone on its own line | 363 | 428 |

mathlib writes `@[simp] theorem foo …` inline; every one comes back split. There is nothing to
repair at the invariant-owning layer — it is Lean's printer reproduced faithfully — but it is a
user-visible consequence of adopting lean-fmt on mathlib and belongs in the report as one.

## The defects this audit found

Eleven files carried a formatter verdict and two more were accepted with wrong columns — thirteen
files, seven classes. Every one is in `experiments/native-layout-defects/README.md` with its
minimization; this is the audit's index into it.

| class | files | verdict | disposition |
| --- | --- | --- | --- |
| correct refusal | `MathlibTest/Linter/LongFile.lean`, `MathlibTest/FindDeprecations.lean` | `diagnostics` | **not a defect.** Both hold `#guard_msgs` docstrings asserting their own layout, so any reformat falsifies the file's own test. Refusing is right. |
| D21 | `MathlibTest/Tactic/SolveByElim/DummyLabelAttr.lean` | `formatter`: ``Unknown constant `Lean._root_.…` `` | **upstream, unrepairable here.** A `_root_` component in a node kind names no constant. The obvious rewrite was written and *measured* to move the failure rather than remove it. Shipped as a diagnosed refusal naming both ends of the declaration and the `format-ignore-next` escape (`b970b0b`). |
| D22 | `Mathlib/Algebra/MonoidAlgebra/NoZeroDivisors.lean`, `Mathlib/CategoryTheory/Sites/CoverLifting.lean` | `diagnostics`: `unknown tactic`; `Fields missing: Y, f` | **repaired**, `3bfeafe`. |
| D23 | `Mathlib/Data/DFinsupp/Notation.lean`, `Mathlib/Data/Finsupp/Notation.lean`, `Mathlib/Tactic/Rename.lean` | `formatter`: `uncaught backtrack exception` | **repaired**, `d73b92d`. |
| D25 | `Mathlib/Tactic/ClickSuggestions/ApplyAt.lean` | `tokens`: `jsxText` changed spelling | **repaired**, `153ef88`. |
| D26 | `Mathlib/Tactic/CasesM.lean`, `Mathlib/Analysis/InnerProductSpace/Projection/Submodule.lean` | `formatter`: `applied 4/5 boundaries`, `applied 2/4 exact islands` | **repaired**, `dedbd91`. |
| D24 | `MathlibTest/Linter/Multigoal.lean`, `MathlibTest/Tactic/Linarith/Basic.lean` | **none — accepted** | **repaired**, `10cf1f2` (+ `24e2e2d` for D27, found by that repair). Found by dimension-7 style counting, not by a gate. |

Two of these are worth separating from the rest.

**A candidate that does not elaborate is the most serious verdict this audit can return**, and D22
was two of them. Both files break a list whose items the parser measures against the *enclosing
item's own start column* — the class `CLAUDE.md` names as the one a `Format` document cannot
express, because `nest n` is relative to the ambient indent and no constructor means "to the column
where this subtree starts". Neither is the adapter's: `Lean.PrettyPrinter.formatCommand`, asked
directly through `runParserCategory`, prints the same broken layout with no adapter in the process.
The repair emits a `.flat` boundary at each single-space gap inside a run the source spells on one
line — refusing to place a break it cannot position, rather than placing it wrong.

**D24 refused nothing, which is why it matters.** Both files were `would-format`; a `fix` run would
have published a top-level declaration indented under a comment. It reparses identically, so no
validation gate can see it. It was found because dimension 7 counts column-zero declarations in the
candidate against the same count in its source, and two files came back short.

### Two defects pinned unrepaired, and why each is a release note rather than a blocker

**D7** — `pushToken` declines a separator between `]` and `do`, so `for h : idx in [:size]do`. It
appears on 2 of the 235 candidates and is measured below. Lean's own tokenizer makes this decision;
an adapter-side merge rule over-fires, which was measured, so the repair is not free.

**D28** — a `where` block mixing a documented and an undocumented binding produces a candidate that
does not elaborate. Lean's printer lays every `where` binding one column right of its align; a
documented one does not follow that break, and `where` is `checkColGe` against the first binding. It
was **constructed** while repairing D26, from `Mathlib/Tactic/CasesM.lean`'s shape — not found. No
file in the sample has it, so it costs no audited path.

Neither is a silent failure: D7 changes bytes a reader can see, and D28 refuses.

## Guard readings

The guard is `experiments/profile-run.sh`: it samples peak RSS and system memory pressure and stops
the chunk rather than the machine. Nothing in either pass was killed for memory, and no swap was
added.

Audit pass, per chunk of 44:

| chunk | peak RSS | hard stop | wall |
| --- | ---: | --- | ---: |
| 000 try 1 | 3.64 GiB | **pressure** | 39 s |
| 000 try 2 | 4.30 GiB | none | 235 s |
| 001 | 6.01 GiB | none | 365 s |
| 002 | 6.09 GiB | none | 148 s |
| 003 | 5.99 GiB | none | 326 s |
| 004 | 4.27 GiB | none | 189 s |
| 005 | 5.97 GiB | none | 214 s |

Peak across the run **6.09 GiB**, against the 8 GiB aggregate stop rule. Total 1,516 s of run time
(1,242 s under the restarted driver plus chunk 000's 274 s), inside the 60-minute cap.

Chunk 000's first attempt is worth keeping in the record: it was stopped at 39 s by *system*
pressure a concurrent session caused, not by this run's own footprint — 3.64 GiB at the time. The
driver waits for a stable quiet window and retries rather than abandoning, and the retry finished at
4.30 GiB. A run that reported the first attempt's partial output would have measured the machine.

Confirmation pass — six chunks, every one on the first try, no hard stop:

| chunk | peak RSS | wall |
| --- | ---: | ---: |
| 000 | 4.26 GiB | 221 s |
| 001 | 6.00 GiB | 230 s |
| 002 | 6.02 GiB | 114 s |
| 003 | 5.68 GiB | 301 s |
| 004 | 4.27 GiB | 177 s |
| 005 | 5.87 GiB | 162 s |

Peak **6.02 GiB**, total **1,205 s** of run time. No swap was added in either pass, and no chunk of
either pass was stopped by this run's own footprint.

Wall time is recorded as evidence, not as a threshold. The same binary over the same corpus measured
96 s and 208 s on 24 paths depending only on what else the machine was doing.

## Against the prompt's Check clause

| required | result |
| --- | --- |
| zero broken failures | **0**, both passes |
| zero rejected failures | **0**, both passes |
| zero unsupported nodes | **0**, both passes |
| zero structural-equivalence failures | **0**, both passes |
| zero comment payload/ownership failures | **0**, both passes |
| zero idempotence failures | **0**, both passes |
| nonzero formatting | 235 changed of 264 in the audit pass, 241 in the confirmation pass |
| reflow across named constructs | 19 of 20 families measured reflowing under a narrower width; `exit` unmeasurable on mathlib, for a reason specific to its only instance, and separately gated here |
| exact/artifact byte agreement | **not exercisable on this corpus** — mathlib is not plugin-built; owned by `tests/performance/run.sh` §1d/§1e |
| clean mathlib git status | verified before and after each pass; the only entry is the product's own untracked cache directory |
| frozen path+content digest for reruns | both manifests frozen in `experiments/workloads/`, digests above |
| wall/RSS as evidence, not thresholds | recorded above; no wall time is asserted anywhere |

### Unsupported project syntax

The prompt makes it a release blocker with a minimized fixture. One shape qualifies: **D21**, a
`_root_` component in a syntax node kind, from `MathlibTest/Tactic/SolveByElim/DummyLabelAttr.lean`.
It is minimized to `tests/native-layout/RootedKind.lean` and gated by §6a of that suite. It is
upstream — the two ends of one `macro (name := _root_.…)` declaration inside `namespace Lean`
disagree about what `_root_` means — and the obvious rewrite was written and measured to move the
failure rather than remove it. The product refuses it by name, cites the declaration's other end,
and leaves the command verbatim, with `format-ignore-next` as the user's escape.

That is a diagnosed refusal with a fixture, which is what the clause asks for. It is not silent, and
it does not block: a user formatting that file gets a named reason and an unchanged file.

### What this evidence does not claim

Three limits, each stated where it arises above and collected here so none of them is only findable
in a paragraph:

1. **3.0% of the corpus by count, 2.6% by bytes.** No file outside the 264 has been checked. The
full
   manifest is frozen for the 27.4 h run.
2. **Dimension 9 (incremental reuse) and exact/artifact agreement are not exercisable by a
cache-cold
   batch run.** Both are named to the durable suites that own them rather than reported as passes.
3. **Sixteen of dimension 7's twenty families share one representative file.** They reflow in that
   file; that is weaker than sixteen independent measurements, and it is what the wall-clock budget
   bought.
