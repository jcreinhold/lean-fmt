---
claim_id: RGR-EVIDENCE
prompt: 02-evidence
status: verified
---

# RGR-EVIDENCE — Measure all ten preview rules against the frozen criteria

## What this claim delivers

Firing counts and hand audits for FMT008–FMT017 over 85 real mathlib modules, a fix audit for the
fixable rules, the CP-1 and CP-2 cost measurements, and one verdict per rule against
`results/01-criteria.md`. Every verdict names an outcome from §1 and the sections it cleared and failed,
so `RGR-IMPL` applies them without re-deciding anything.

Evidence lives in `evidence/02-corpus-audit.md` (environment, commands, every audited finding) and
`evidence/02-cp1-warm-serve.md` (the CP-1 probe). Harnesses are `experiments/run-cp1-warm-serve.sh`,
`experiments/run-fix-audit.sh`, and `experiments/run-cp2-cold-cost.sh`.

## The headline

**No rule graduates to default.** Not one of the ten came within an order of magnitude of §2.2's
exposure bar, and the reason is a property of the corpus rather than ten separate rule failures.

| | |
| --- | --- |
| Real mathlib modules run | **85** (62 frozen sample + 23 stress/batch/remainder) |
| Total findings, all ten rules | **2** |
| Rules that fired at all | **2** (FMT009, FMT013) |
| Rules that never fired | **8** |
| False positives found | **0** |
| Broken modules / infrastructure failures | **0 / 0** |
| §2.2 bar for `default` | 10 audited true positives on real code |
| Highest any rule reached | **1** |

## The finding that governs everything else

`results/01-criteria.md` §2.2 warned in advance that this could happen and fixed how to report it. It
happened.

**mathlib is close to the worst available corpus for demonstrating that a hygiene rule fires
correctly, because mathlib already enforces these rules itself.** `linter.style.setOption` is FMT012's
near-exact equivalent; mathlib CI enforces module docstrings, closed scopes, and reviewed attribute
lists. A rule aimed at what a heavily self-linted corpus already forbids finds nothing there, and
finding nothing is evidence about the corpus, not about the rule's precision.

The clearest signal is which rule fired. **FMT013 is the one rule with no mathlib counterpart, and it
is the one rule that fired on the sample.** The runner's own header said so before this stack existed:
"mathlib is heavily self-linted for the FMT008-012 and FMT014-017 equivalents (expected near-zero);
FMT013 (redundant nested parens) has no mathlib linter."

The corpus measured which rules mathlib already enforces. It did not measure which rules are correct.

**This is not a reason to lower the bar**, and §2.2 explicitly removed that remedy. It is a reason the
available outcomes for eight rules are `preview-with-path` and `retired`, and it makes the graduation
condition each of them carries the substantive product of this stack.

## Criteria that were *not* revised

Per prompt 02's stop rule and `CLAUDE.md`, this section exists so a reader can check nothing moved.

- §2.2's exposure threshold (10) is **unchanged**, despite no rule reaching 2. `results/01-criteria.md`
  §0 predicted this would be the pressure point and pre-committed against it.
- §2.1's zero-false-positive budget is unchanged; nothing tested it, because there were no false
  positives.
- §5.3's CP-2 **number** (1.25×) is unchanged. Its **projection** was wrong and is corrected below —
  those are different things, and only the second is revised.

## Per-rule verdicts

Each cites the criteria sections it was judged against.

### FMT008 — docs / syntax / report-only

- **Corpus:** 0 findings on 85 mathlib modules. 17 findings on lean-fmt's own 34 modules.
- **§2.2:** zero real-code findings ⇒ ineligible for `default` **and** for `stable-optional`.
- **§2.4 opinionation:** the 17 self findings say **lean-fmt's own modules carry no module docstrings**.
  A rule the shipping repository does not itself follow has an opinionation problem that no
  false-positive count surfaces. (Per §6.3 these are not exposure evidence; they are opinionation
  evidence, which is exactly what §2.4 asks for.)
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** *graduates when it produces ≥10 audited true positives with zero false positives
  on a corpus of Lean projects that do not already enforce module docstrings in CI, and lean-fmt's own
  tree either complies or the rule is scoped to exclude executable/script modules.*

### FMT009 — structure / syntax / report-only

- **Corpus:** 1 finding — `scripts/create_deprecated_modules.lean:21`, `unclosed namespace`. Hand-checked:
  411 lines, no `end` anywhere. **True positive under the rule's contract; borderline opinionation.**
- **§2.2:** 1 < 10 ⇒ ineligible for `default`.
- **Defect recorded, not repaired (prompt 02 stop rule):** FMT009's own explanation already carves out
  *"the idiomatic whole-file section"* for an **anonymous** section. A **named** namespace spanning a
  whole file is arguably the same idiom and is not carved out. Until that is settled the rule's contract
  is ambiguous at exactly the place it fired, which also blocks `stable-optional` under §1.2 — `.stable`
  is a meaning-freeze promise, and this meaning is not ready to freeze.
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** *graduates when the whole-file named-namespace case is settled — either carved out
  like the anonymous whole-file section or explicitly kept reportable with the reason recorded — and it
  then produces ≥10 audited true positives with zero false positives.*

### FMT010 — redundancy / syntax / fixable

- **Corpus:** 0 findings on 85 modules, **including `Mathlib/Data/Finset/Attr.lean`**, which is in the
  stress set precisely because it is attribute-dense. That is the strongest available evidence that
  duplicate attributes do not survive mathlib review.
- **§3 fix audit:** clean. FX-2 byte idempotence, FX-3 convergence, FX-4 re-elaboration, FX-6
  composition all pass (`experiments/run-fix-audit.sh`, cases `fmt010-dup`, `fmt010-quote`,
  `compose-all`).
- **§2.2:** zero real-code findings ⇒ ineligible for `default` and `stable-optional`. The fix being
  well-behaved does not substitute for the rule having fired.
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** *graduates when it produces ≥10 audited true positives with zero false positives
  on a corpus that is not attribute-reviewed — generated code, student code, or a project without an
  attribute linter.*

### FMT011 — redundancy / syntax / fixable

- **Corpus:** 0 findings on 85 modules.
- **§3 fix audit:** clean (`fmt011-dup`, `compose-all`).
- **§2.2:** zero real-code findings ⇒ ineligible for `default` and `stable-optional`.
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** as FMT010, for duplicate `deriving` classes.

### FMT012 — debug / syntax / report-only

- **Corpus:** 0 findings on 85 modules. mathlib ships `linter.style.setOption`, which is this rule's
  near-exact equivalent, so a zero here is close to guaranteed by construction and carries almost no
  information about the rule.
- **§2.2:** zero real-code findings ⇒ ineligible for `default` and `stable-optional`.
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** *graduates when it produces ≥10 audited true positives with zero false positives on
  a corpus with no `set_option` linter of its own — which mathlib, by construction, cannot supply.*

### FMT013 — redundancy / syntax / fixable

- **Corpus:** 1 finding — `Mathlib/GroupTheory/NoncommPiCoprod.lean:174`, `Commute m ((ϕ i x))`.
  **True positive**, hand-audited against its source; the outer pair carries no grouping or precedence
  role. Not opinionation: the same file already writes `(ϕ i x)` five other times. `ruff-10b`
  independently hand-reviewed the same edit.
- **§2.1:** zero false positives, zero opinionation findings.
- **§2.2:** 1 < 10 ⇒ **ineligible for `default`**. Eligible for `stable-optional`, which requires every
  finding it produced to audit clean (it did) **and** a fixture suite covering positive, negative,
  malformed, Unicode, and custom-syntax cases. Verified present in `tests/syntax/`: `NestedParen`,
  `NestedParenTriple` (positive), `NearParen` (negative), `Malformed` (malformed), `NestedParenUtf8`
  (Unicode), `CustomSyntax` and `QuoteParen` (custom syntax / quotation), `Comment` (trivia).
- **§3 fix audit:** clean across five FMT013 cases plus composition.
- **§1.2 meaning-freeze:** the contract — an inner parenthesized term immediately wrapped by another
  pair — is precise, has no open question of the kind FMT009 has, and has been stable since `ruff-10`.
- **Verdict: `stable-optional`** — `lifecycle := .stable`, `defaultEnabled := false`.
- **Why not `default`:** §2.2 exposure, and §5.3 CP-2 independently (below). Either alone is decisive.
- **§1.5:** not required — `stable-optional` is not preview. Should the exposure bar later be met on a
  corpus that exercises it, `default` remains reachable subject to CP-2.

### FMT014 — deprecation / semantic / fixable (unsafe)

- **Corpus:** 0 findings on 85 modules.
- **§3 FX-1:** the fix is `applicability := .unsafe` (`LeanFmt/Rules.lean:651`, a textual rename), so
  §3 FX-1 bars the rule from `default` *with the fix enabled by default* regardless of exposure. The
  report-only half is unaffected.
- **§2.2:** zero real-code findings ⇒ ineligible for `default` and `stable-optional`.
- **Verdict: `preview-with-path`.**
- **§1.5 condition:** *graduates report-only when it produces ≥10 audited true positives with zero false
  positives on a corpus that uses deprecated declarations; the rename fix stays `.unsafe` and opt-in
  regardless.*

### FMT015, FMT016, FMT017 — unused / unused / naming, semantic, report-only

- **Corpus:** 0 findings each on 85 modules.
- **§2.2:** zero real-code findings ⇒ ineligible for `default` and `stable-optional`.
- **Verdict (each): `preview-with-path`.**
- **§1.5 conditions:** *FMT015/FMT016 graduate when they produce ≥10 audited true positives with zero
  false positives on a corpus that is not `linter.unusedVariables`-clean — mathlib runs that linter, so
  it cannot supply the evidence. FMT017 graduates when the nullary-constructor-resemblance heuristic is
  exercised on a corpus with ≥10 findings and its opinionation rate under §2.4 is measured, since a
  naming rule is the most likely of the ten to be true-but-unwanted.*

## Verdict summary for `RGR-IMPL`

| Rule | Outcome | `lifecycle` | `defaultEnabled` |
| --- | --- | --- | --- |
| FMT008 | preview-with-path | `.preview` | `false` |
| FMT009 | preview-with-path | `.preview` | `false` |
| FMT010 | preview-with-path | `.preview` | `false` |
| FMT011 | preview-with-path | `.preview` | `false` |
| FMT012 | preview-with-path | `.preview` | `false` |
| **FMT013** | **stable-optional** | **`.stable`** | **`false`** |
| FMT014 | preview-with-path | `.preview` | `false` |
| FMT015 | preview-with-path | `.preview` | `false` |
| FMT016 | preview-with-path | `.preview` | `false` |
| FMT017 | preview-with-path | `.preview` | `false` |

**No rule is retired.** §1.3 reserves retirement for a rule with no constituency; every one of these
has a stated corpus on which it would earn its place, and eight of them were never given one. Retiring
a rule because the wrong corpus was used to judge it would be the wrong lesson to encode in
`reservedCodes`, which is permanent.

**`ruff-10b` Design B does not fire.** §3 FX-7 and `ruff-10b`'s revisit condition both require *"a
syntax rule graduates to default"*. None does — FMT013 reaches `stable-optional`, which is off the
default path by construction. `RGR-IMPL` records the trigger as unfired, but unlike `ruff-19`'s check
it now carries a measurement of what firing it would have cost (§5.3 below).

## Cost measurements

### CP-1 (§5.2) — the warm path: **holds, and the prediction it rested on is now tested**

`evidence/02-cp1-warm-serve.md`. With all ten preview rules selected on the 34-module self workload,
the warm run stays fully cache-served: `index_hits == targets == served == 34`, `exact_child = 0`,
`exact_setup = 0` — `ruff-19` §1a/§1b/§1c all pass.

The zero counts are not self-confirming, and this is the part worth keeping: a cache replaying a stale
source-tier entry and silently dropping the higher-tier findings prints exactly those numbers. The four
single-rule arms are individually vacuous for that reason on a clean tree. The all-ten arm is the
evidence — it emitted **17 findings** on that warm, fully-served, zero-child run, byte-identical to the
cold report. A cache that had dropped the tier would have emitted nothing.

So graduating a rule of any tier does not threaten `ruff-19`'s warm gates, and §5.2's escape hatch is
not needed.

### CP-2 (§5.3) — the cold path: **failed by 26×**

`experiments/run-cp2-cold-cost.sh`, 62-module frozen sample, mathlib built **without**
`LeanFmtCompilerPlugin` (the definition of `ordinary-built`), `--no-cache` so every repetition is cold,
one `check` invocation per repetition so per-process and per-workspace setup amortizes exactly once.
`ruff-19`'s variance policy: 4 repetitions, first discarded, median of 3, spread reported.

| Arm | wall median | spread | `exact_child` count | `exact_child` ms | per module |
| --- | ---: | --- | ---: | ---: | ---: |
| baseline (default, 5 rules) | **9,068 ms** | 8,179–13,656 | **1** | 2,648 | 146 ms |
| + FMT013 (one syntax rule) | **299,608 ms** | 296,800–317,446 | **62** | 280,101 | 4,832 ms |

**Ratio: 33.0×. The §5.3 budget is 1.25×.** CP-2 fails by a factor of 26.

The count is the durable part, per `tests/performance/run.sh`'s rule that a gate must be a count, a
ratio, or a digest. **The baseline spawns 1 frontend child across 62 modules; adding one syntax-tier
rule spawns 62 — one per module.** The baseline's single child is a *fixed* cost (it does not scale
with the manifest), while the graduated arm's is *linear in modules*. That structural difference, not
the wall time, is why this is not a tuning problem: there is no machine on which 62 frontend children
cost what 1 costs.

Validity cross-check: the baseline arm emits **27 findings**, exactly reproducing `ruff-19`'s recorded
baseline finding count for this workload, so the two arms are measuring the workload `ruff-19` defined.

### §5.3's projection was wrong by ~11×, and the correction is recorded rather than absorbed

`results/01-criteria.md` §5.3 projected ~408 ms marginal per module from `ruff-19`'s four-module
fixture measurement, and predicted a graduated syntax rule would roughly **double** a cold run — about
8× over budget. Measured on real mathlib modules the marginal cost is **4,832 ms per module**, and the
result is **33×**, not 2×.

`ruff-19` attached the warning to its own number — *"It is not a speed benchmark: four small fixture
modules are not a project, and the per-module frontend cost above is dominated by the first child's
2,058 ms of process and import startup"* — and §5.3 carried the number forward anyway. That was the
error, and it is worth naming precisely: **the budget (1.25×) is unchanged and was not the mistake; the
projection built on it was a separate claim and it was wrong.** §"Criteria that were not revised" above
holds.

The correction strengthens rather than weakens every verdict: no rule was going to graduate on exposure
grounds regardless, and CP-2 now independently forecloses `default` for all six syntax-tier rules and
all four semantic-tier rules on any `ordinary-built` project.

### CP-4 (§5.5) — the predicted tax **did not materialize**

§5.5 predicted `official_artifacts` would cost ~101 ms on a workspace that cannot hold an artifact,
citing `ruff-19`. Measured here on ordinary-built mathlib, in both arms:
**`phase.official_artifacts_ms = 0`.**

Recorded as a correction, not quietly dropped: on this workload the facet lookup is free, so CP-4's
"tax on projects that cannot benefit" is not a real cost here and must not be cited as one. Whether
that is because the phase short-circuits when no Lake formatter facet is configured, or because
`ruff-19`'s 101 ms was specific to its four-module workspace, is **not established by this
measurement** and this note does not claim it.

### CP-3 (§5.4) — not measured

The integrated arm was not run. It is not needed for any verdict: no rule reaches `default`, so no rule
puts a tier above source on the default path, so CP-3 binds nothing. Recorded as an explicit gap rather
than silently skipped — `RGR-FINAL` should either run it or record the same reasoning.

## What this means for `ruff-10b` Design B

The trigger stays unfired (no syntax rule reaches `default`), but this stack can now say what `ruff-19`
could not: **had it fired, Design A would have failed the budget by 26×.** A parse instead of a full
re-elaboration would have to remove essentially all of the 4,832 ms per module to bring 33× under
1.25×. That is a far stronger statement than `ruff-19`'s "the trigger has not fired", and `RGR-IMPL`
should record it in place of a bare re-check.

## Checks read

| Check | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | exit 0 |
| `experiments/run-lifecycle-precision-sample.sh` (62 modules) | 1 finding, 0 broken, 0 infra |
| same, 23 stress/batch/remainder modules | 1 finding, 0 broken, 0 infra |
| `experiments/run-fix-audit.sh` | 10 cases, 0 assertion failures |
| `experiments/run-cp1-warm-serve.sh` | 5 arms, `ruff-19` §1a/§1b/§1c pass on all |
| `experiments/run-cp2-cold-cost.sh` | baseline 9,068 ms / +FMT013 299,608 ms (medians of 3) |
| baseline `check --json` over the sample | 27 findings, 0 broken, 0 infrastructure failures |
| `git diff --check` | clean |
| structural checkers | same 5 pre-existing `implementation_route` failures as every lean-fmt stack |

No production module changed in this prompt, so `tests/boundary/run.sh` has no new boundary to inspect;
it belongs to `RGR-IMPL`.

## Remaining uncertainty

- **The baseline's single `exact_child` is unexplained.** It is 1 across 62 modules, so it is a fixed
  cost rather than a per-module escalation, and the run reports 0 broken and 0 infrastructure failures —
  so it is not an error path. Beyond that this note does not claim a mechanism, because it did not
  establish one. It does not affect any verdict (the ratio is driven by 62 vs 1), but someone should
  find out what it is.
- **CP-4's 0 ms is a measurement, not an explanation** (above). Do not convert it into a claim that the
  facet lookup is always free.
- **My baseline wall median (9,068 ms) is well under `ruff-19`'s recorded 24,696 ms** for nominally the
  same workload. Different mathlib revision, different machine state, and `ruff-19` itself records the
  same binary and corpus varying 3,977–19,968 ms on load alone. The finding count matching at 27 is the
  reason to trust the arm; the *ratio* is the quantity to carry forward, not either absolute.
- **Eight rules have zero evidence about their precision**, and that is a durable gap this stack cannot
  close — closing it needs a corpus that is not mathlib. Each §1.5 condition names the corpus that would
  close it, which is the most this stack can honestly do.
- **The opinionation category (§2.1) got one hard case** (FMT009) and it was genuinely hard. The
  distinction between "false positive" and "true but unwanted" held up, but one case is not a test of it.
