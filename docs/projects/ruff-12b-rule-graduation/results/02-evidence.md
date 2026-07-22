---
claim_id: RGR-EVIDENCE
prompt: 02-evidence
status: in-progress
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

### CP-2 (§5.3) — the cold path

*(measurement in progress; `experiments/run-cp2-cold-cost.sh`)*

## Checks read

*(pending)*

## Remaining uncertainty

*(pending)*
