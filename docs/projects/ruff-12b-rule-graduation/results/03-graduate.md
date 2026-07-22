---
claim_id: RGR-IMPL
status: verified
depends_on: [RGR-EVIDENCE]
---

# RGR-IMPL — the verdicts, applied

`results/02-evidence.md`'s verdict table is now the built catalog. This note records what changed in
code, the checks that were run against it, the `ruff-10b` Design B decision with the measurement that
`ruff-10b` deferred to this moment, and what remains uncertain.

Nothing here re-decided a verdict. Prompt 03's job was application, and the one place where applying a
verdict required a judgement — where a preview rule's graduation condition has to live so it does not
rot — is recorded in §2 as a design decision, not as a re-opened verdict.

## 1. FMT013 → `stable-optional`

`LeanFmt/Rules.lean`: `lifecycle := .stable`, `defaultEnabled := false` — RGR-SPEC §1's fourth
outcome, occupied for the first time.

**No selector machinery was added.** `LeanFmt/Config.lean:668-671` already expands `all` and a
category to every `.stable` rule regardless of `defaultEnabled`; `default` reads `defaultEnabled`.
The state was implemented and merely unoccupied, exactly as RGR-SPEC §1.1 predicted. Verified against
the built binary, not against that prediction:

```
$ lake exe lean-fmt check --select FMT013     tests/fixtures/…    # FIRES  (no --preview)
$ lake exe lean-fmt check --select redundancy tests/fixtures/…    # FIRES  (no --preview)
$ lake exe lean-fmt check --select all        tests/fixtures/…    # FIRES  (no --preview)
$ lake exe lean-fmt check --select default    tests/fixtures/…    # silent
$ lake exe lean-fmt check                     tests/fixtures/…    # silent
```

**A correction to my own working record.** An earlier run of this matrix reported `redundancy` and
`all` as *not* firing. That was a defect in my shell helper — an unquoted selector word-split with
`grep -c` semantics — and not a product behaviour. The corrected helper is what produced the table
above, and the three FIRE results are what the catalog suite now pins. I record the false alarm
because the wrong result was stated before it was checked.

`lake exe lean-fmt rules` from the built binary:

```
FMT013	redundancy	stable	fixable	optional	remove redundant nested parentheses
```

`explain` states the combination in words rather than leaving a user to infer it from two flags:

> This rule is stable but off by default. It is syntax tier, so running it on a project not built
> with the lean-fmt compiler plugin costs one compiler frontend run per module; select it with
> `--select FMT013`, or `--select redundancy`, or enable it in `lean-fmt.toml`.

## 2. `RuleInfo.previewPath?` — DOC-3, with the invariant that keeps it honest

The other nine rules stay `.preview`, each carrying its RGR-SPEC §1.5 graduation condition. §4 DOC-3
required a first-class field with an enforcing invariant, and the reason is in `CLAUDE.md`: a
declared field nobody checks rots exactly as a declared tier field would.

`previewPath? : Option String := none`, rendered in three places a user actually looks:

- `explainText` — a `Path out of preview` block;
- `rulePageMarkdown` — a `## Path out of preview` section in `docs/rules/FMT0NN.md`;
- `ruleInfoJson` — a `previewPath` key, `null` for non-preview rules.

The invariant is `LeanFmtTest.lean` `testCatalogInvariants` 3b, and it is **bidirectional**:

```lean
  if info.lifecycle == .preview then
    match info.previewPath? with
    | none => throw <| IO.userError s!"preview rule {info.code} states no path out of preview"
    | some p => ensure (!p.isEmpty) s!"preview rule {info.code} has an empty path out of preview"
  else
    ensure info.previewPath?.isNone
      s!"non-preview rule {info.code} carries a path out of preview"
```

Both directions matter. Forward, a field that is merely *allowed* is a field that goes unset on the
next rule someone adds. Backward, a stale path left on a rule that has since graduated is a
documentation lie that reads as current.

Each condition names the corpus that would exercise the rule, because RGR-EVIDENCE's headline finding
was that mathlib measured which rules mathlib already enforces. FMT012's, in full, is the shape all
nine take:

> Graduates when it produces at least 10 audited true positives with zero false positives on a corpus
> with no `set_option` linter of its own. mathlib cannot supply that evidence by construction:
> `linter.style.setOption` is this rule's near-exact equivalent, so the zero it scored across 85
> mathlib modules says what mathlib already enforces and nothing about whether this rule is correct.

## 3. Nothing is retired

RGR-SPEC §1.3 and the verdict table both say so, and eight of these ten rules were judged on a corpus
that could not exercise them. `reservedCodes` is untouched; no code moved into it.

## 4. `ruff-10b` Design B — refused, with the measurement

`ruff-10b` named its revisit condition: *"if a syntax rule graduates to default and the gated
re-projection lands on the default run cost budget."* **The trigger is unfired.** No syntax rule
reaches `default`; `stable-optional` is off the default path by construction, so the antecedent's
first clause is false and Design B is not adopted.

`ruff-19` reached the same conclusion by observing that every syntax rule was still preview. This
stack can say more, and prompt 03 required more than a bare re-check: it measured what firing the
trigger would have cost under Design A, on real mathlib modules
(`experiments/run-cp2-cold-cost.sh`, medians of 3 after a discarded warm-up, `evidence/` and
`results/02-evidence.md` §CP-2):

| arm | median wall | frontend children | per module |
| --- | --- | --- | --- |
| baseline (default set, 5 rules) | 9,068 ms | **1** | 146 ms |
| + FMT013 (one syntax rule) | 299,608 ms | **62** | 4,832 ms |

**33.0× against a 1.25× budget — CP-2 fails by 26×.** The number that decides this is not the wall
time, which varies with machine load and which `tests/performance/run.sh` refuses to assert on. It is
the **1 frontend child versus 62**: a fixed cost against a per-module linear one. There is no machine
on which 62 frontend children cost what 1 costs.

So the refusal is not "Design B is unnecessary because the trigger did not fire." It is: **had the
trigger fired, Design A would have missed the budget by 26×, and Design B would have had to remove
essentially all of the 4,832 ms per module to close it.** That is the measurement `ruff-10b` deferred
to this moment, and `ruff-20` inherits a refusal with a number attached rather than a re-check.

RGR-SPEC §5.3's *projection* (~2×, extrapolated from `ruff-19`'s 408 ms/module over four fixture
modules) was wrong by ~11×. The projection is corrected; the 1.25× **budget** is unchanged and was
not moved to accommodate anything.

## 5. `ruff-19`'s gates — confirmed, not re-derived

The default rule set is unchanged: five rules, all source or import tier. §1c's derivation — zero
`exact_child` and zero `exact_setup` on a served workload, because no default rule needs the frontend
— still holds for the same reason it held before. `state/next.md` said not to re-derive what did not
change, and nothing changed.

Confirmed by running it:

```
$ tests/performance/run.sh
--- §0 the gates themselves discriminate ---
  ok   16 cases, every gate proven to discriminate
--- §1 a warm run is fully cache-served ---
  ok   the manifest's 34 files are the targets
  ok   every target is an index hit and is served (34/34)
  ok   neither the exact frontend nor per-target setup runs on a served workload
--- §2 no work outside the top-level phases (gate G3) ---
  ok   unaccounted remainder 56 ms of 562 ms (90.0% accounted, bound 250 ms)
--- §3 no top-level phase silently measures nothing ---
  ok   the PositionIndex build measures itself (14 ms over 2 MB)
--- §4 digest reuse: cold and warm agree byte for byte ---
  ok   the served report is identical to the report that populated the cache
tests/performance: ok
```

§0 is `negative.sh`, which proves each gate can fail before the suite reports that none did — so the
pass above is a discriminating pass, not a vacuous one.

CP-1 (RGR-EVIDENCE, `evidence/02-cp1-warm-serve.md`) already showed these gates survive even with all
ten preview rules selected: a warm, fully-served, zero-`exact_child` run emitted 17 findings
byte-identical to cold. A tier above source is served from the cache; it does not force the frontend.

## 6. Tests that encoded the old catalog

Three assertions in `LeanFmtTest.lean` were true only because no stable rule was default-off. They
were updated to assert the new shape, not deleted:

- **`"a preview category selected rules without preview mode"`** — `redundancy` is now a *mixed*
  category (FMT010/011 preview, FMT013 stable). Rewritten to assert `gated.selected == #["FMT013"]`,
  with FMT010 taking over as the preview-gate exemplar and direct stable-optional coverage added
  (exact code / `all` / `default`).
- **`"all/default did not expand to exactly the stable set without preview"`** — its premise, "every
  stable rule is default-on," is precisely what this stack broke. Rewritten to assert the divergence,
  plus a guard so the assertion cannot pass vacuously if the stable-optional outcome is ever vacated:

```lean
  let defaultCount := (allRuleInfos.filter (·.defaultEnabled)).size
  ensure (defaultCount < stableCount)
    "no stable rule is default-off, so the stable-optional outcome has no live instance"
```

## 7. Checks

Every check `state/next.md` and `prompts/03-graduate.md` named, run from a clean tree at `9bfd69d`:

| check | result |
| --- | --- |
| `lake build` | ok (includes `LeanFmtCacheSpec`) |
| `lake exe lean-fmt-tests` | ok — `lean-fmt module-artifact tests passed` |
| `lake lint` | `files=35 findings=0 changed=0 broken=0 rejected=0 infrastructure_failures=0` |
| `lake exe lean-fmt docs --check` | `docs up to date (17 files)` |
| `tests/catalog syntax semantic modes reporting suppression discovery check` | PASS |
| `tests/boundary` | PASS |
| `tests/performance` (incl. §0 `negative.sh`) | PASS, output above |
| `tests/lossless printer stream imports layout` | PASS |
| `tests/cache compiler downstream scale` | PASS |
| `tests/watch` | PASS (clean index; the §9.6 defect `ruff-20` owns did not trigger) |
| `tests/ci` | PASS (reads committed state; tree was clean at `9bfd69d`) |
| `git diff --check` | clean |
| `explain FMT013` | `[stable]`, `default: off`, prose paragraph above |
| `explain FMT012` | `Path out of preview` block present |

Structural checkers: the same five pre-existing `implementation_route` failures every lean-fmt stack
reports, including the closed and verified `ruff-06` and `ruff-12`. No new stack-shaped failure.
Recorded, not worked around — see `results/01-criteria.md` §"Structural checker disagreement".

## 8. Remaining uncertainty

- **The baseline's single `exact_child` is unexplained.** It is not an error path — 0 broken, 0
  infrastructure failures, 27 findings matching `ruff-19`'s recorded baseline — but I did not
  establish what spawns it. The CP-2 conclusion does not depend on the answer: 1 versus 62 is a
  structural difference at any value of 1.
- **CP-4's 0 ms is a measurement, not an explanation.** RGR-SPEC §5.5 predicted a ~101 ms
  `official_artifacts` tax and this workload showed none. I did not establish why, and I decline to
  claim a mechanism I have not shown. `ruff-19`'s 101 ms was specific to its four-module workspace.
- **CP-3 was never measured**, and is an explicit gap rather than a pass. Nothing binds it while no
  rule reaches default.
- **Nine graduation conditions are unexercised.** Each names a corpus that would test its rule, and
  none of those corpora has been run. The conditions are falsifiable and unfalsified — which is the
  honest state, but it is not evidence that any of the nine is correct.
