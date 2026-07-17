# RRE-FINAL — Verify engine depth and contributor ergonomics

**Verified.** The engine's tier behavior is now tested rather than argued, and the contract's two
untested clauses have gates. This prompt also found that `RRE-IMPL` was marked verified on an
incomplete gate set and broke three harnesses nobody ran; that is recorded below rather than quietly
repaired.

## The headline

**`RRE-IMPL` broke three test harnesses and I marked it verified anyway.** `tests/lossless/run.sh`,
`tests/modes/run.sh`, and `tests/printer/run.sh` all failed at commit `b67b4af`. I ran the five gates
the prompt's Check section names by category — build, unit, boundary, check, compiler — and treated
that list as exhaustive. It is not: `README.md:131-140` lists nine harnesses, and "the focused
unit/integration suites named by touched modules" means every suite that consumes what the touched
module produces. Three did, and I did not look.

```
                        at b67b4af (RRE-IMPL "verified")   now
  tests/lossless        FAIL  KeyError: 'findings'          pass
  tests/modes           FAIL  KeyError: 'findings'          pass
  tests/printer         FAIL  stale shape evidence          pass
```

The first two read `artifact["findings"]`, which `RRE-IMPL` deleted. The third is the corpus census
described below. All three are fixed here, and the honest summary is that `RRE-IMPL`'s claim was
true about the code and false about the repository.

## What was run

```
$ LEAN_NUM_THREADS=1 lake build                    → 0
$ LEAN_NUM_THREADS=1 lake exe lean-fmt-tests       → 0
$ bash tests/boundary/run.sh                       → 0
$ bash tests/check/run.sh                          → 0
$ bash tests/compiler/run.sh                       → 0
$ bash tests/lossless/run.sh                       → 0   (fixed here)
$ bash tests/modes/run.sh                          → 0   (fixed here)
$ bash tests/printer/run.sh                        → 0   (fixed here)
$ bash tests/layout/run.sh                         → 0
$ bash tests/scale/run.sh                          → 0
$ bash tests/service/run.sh                        → 0
$ python3 experiments/check-quoted-figures.py      → 0   (33 figures checked)
$ git diff --check                                 → 0
$ check_stack.py --structural (ruff-05, ruff-03)   → OK, no errors
$ write_next.py --check                            → OK
```

Every harness in the repository, not the five named by category. Exit codes read directly, never
through a pipe.

## The scaffolding tension, and how it resolves

The work order says "add a representative rule at each tier". The stop rule says "do not retain fake
product rules merely for coverage". Both hold only if the representative rules never enter
`ruleRegistry` — and they could not have been anywhere else, because `runRules` folded a hardcoded
global. **That is what a substitution seam is for, and the engine did not have one.**

`runRulesOf (rules : Array Rule)` and `RulePlan.requiredTierOf (rules : Array Rule)` take the
registry as a parameter; `runRules` and `requiredTier` fix it to `ruleRegistry`. Total new production
surface: two definitions, no new behavior, no caller changed. Tests register probe rules
(`probeSource`, `probeSyntax`, `probeTie`) in `LeanFmtTest.lean`; the product ships two rules, as
before. Nothing was added to the registry and nothing had to be removed from it, so the work order's
"remove scaffolding rules after their contracts are tested" is satisfied vacuously and honestly:
scaffolding that never enters the product needs no removal step.

The probes are deliberately adversarial about order. `probeSyntax` is registered **last** and its
findings land **first**, so an engine concatenating in registry order fails every assertion.

## The tests are non-vacuous, and one of them was not

Each new assertion was falsified by breaking the thing it claims to check:

| mutation | caught by |
| --- | --- |
| `runRulesOf` returns `findings` unsorted | `mixed-tier findings are not byte-sorted independently of registry order` |
| `Tier.satisfies .syntax .source := true` | `selecting a syntax rule did not require syntax facts` |
| the cache-collision fixture's first run writes no entry | `expected exit 0, got 2` |

**The cache-collision test was vacuous when first written and the falsification is what found it.**
It ran `check` twice with different `--select` and disabled the analyzer on the second, reasoning
that only a cache hit could then succeed. It could not: a plain `check` on a current module takes the
source-only shortcut in `availableAnalysis` and never consults the analyzer *or the cache*, so the
run passed without a hit and the test asserted nothing. It needed
`LEAN_FMT_DISABLE_ARTIFACT=1 LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1` as well — the same trio every
other cache test in that file already uses, which is what I should have noticed. Now: with the entry
present it exits 0; without it, 2. The comment in the file explains why all three vars are
load-bearing, because the next reader will otherwise trim them back.

## Dead code the audit found

**The tier guard in `runRulesOf` was redundant.** `if !facts.tier.satisfies rule.tier then findings`
did exactly what the match's `| .syntax _, .source _ => findings` case does. Mutation-testing
`Tier.satisfies` is what exposed it: the mutation was caught by `requiredTierOf` (through `Tier.max`)
and nothing else, because the guard could not affect any result. Removed — the match is total over
the constructor pair, and a match that decides by construction cannot drift from a guard that
restates it.

**`Facts.tier` had no callers at all** once the guard went. `RRE-IMPL` added it and nothing ever used
it. Deleted.

## The corpus census moved, and one qualitative figure with it

This repository is the printer's own corpus, so `RRE-IMPL`'s rewrite of `LeanFmt/Rules.lean` moved
every figure describing it. `tests/printer/run.sh` caught the stale evidence and named its own
remedy, exactly as it did for `RFP-IMPL` (`ruff-04/results/02-integration.md:143-152`).

```
                     before    after
  commands           468       483
  nodes              43,840    44,562
  distinct kinds     7         6      <- qualitative
  empty nodes        35.7%     35.8%
  canonical          445       459
```

**The distinct-kind count fell because `RRE-IMPL` deleted this repository's only `register_option`.**
`Lean.Option.registerOption` was also the corpus's only command outside `Lean.Parser.Command.*`.
That is not a regression and the conservative fallback that owned it is untouched — the kind did not
stop existing in Lean, it stopped existing in code I wrote, which is precisely the caveat
`notes/01-command-printing.md` already puts under that table. The table and the caveat now say so.

**The independent-agreement check still agrees exactly**: the Python probe finds 402 of 414
declarations claimable, and the printer counts `459 = 402 + 25 namespace + 25 end + 7 open`. That
identity surviving a 15-command corpus change is worth more than any single count in the table.

`experiments/check-quoted-figures.py`'s own pattern hardcoded `7 distinct kinds` and had to move to
`6`. Re-running the census after the prose edits confirmed a fixed point, so the figures describe the
tree they were measured from.

## What changed

- `LeanFmt/Rules.lean`: `runRulesOf`; `runRules` fixes it to `ruleRegistry`; dead tier guard and
  `Facts.tier` removed.
- `LeanFmt/Config.lean`: `RulePlan.requiredTierOf`; `requiredTier` fixes it to `ruleRegistry`.
- `LeanFmtTest.lean`: `testEngineTiers` (mixed-tier ordering, tier skipping, tie-breaking on code,
  `ToJson` deriving `input` from the implementation) and `testMixedSelection` (`requiredTierOf` over
  selections the shipped registry cannot express).
- `tests/check/run.sh`: the cache-collision test.
- `tests/lossless/check_projection.py`, `tests/modes/run.sh`: repaired; both now assert the artifact
  carries **no** `findings` key rather than reading one.
- `docs/adding-a-rule.md`: the contributor guide. Linked from `README.md`; `AGENTS.md` gained the
  three durable facts a contributor must not rediscover (tier is a constructor, the artifact carries
  facts, the plugin's exposure has two channels).
- `README.md`, `AGENTS.md`: `source-input`/`Syntax-input` → `source-tier`/`syntax-tier`. That
  vocabulary was `RuleInfo.input`'s, and the field is gone.
- `ruff-03`'s evidence, notes, state, and `LeanFmt/Printer.lean`'s docstrings: census figures.

## Measurements

- `lean-fmt rules --json` emits `"input": "source"` for both rules, derived from `RuleImpl` rather
  than read from a field.
- 33 quoted figures checked against the regenerated evidence, all agreeing.
- Census: 483 commands, 44,562 nodes, 6 distinct kinds, `canonical=459`, 20 modules byte-identical.

## Remaining uncertainty

- **`Tier.syntax` still has no shipped rule, and `testEngineTiers` asserts that on purpose.** The
  assertion `ruleRegistry.all (·.tier == .source)` fails the moment `ruff-06` ships one — with a
  message naming the two places (`renderCanonicalText`, `availableAnalysis`'s shortcut) that assume
  otherwise. That is a to-do list disguised as a test, and it is deliberate: the alternative is
  discovering those assumptions from a wrong answer.
- **The seam is a discipline, not a barrier.** Nothing stops a production caller from passing its own
  array to `runRulesOf`. Both definitions say so in their docstrings; neither can enforce it. A
  private-by-default module and one test file are the whole of the protection.
- **The corpus census will rot again on the next commit that touches `LeanFmt/`.** That is designed —
  `check-quoted-figures.py` exists so the rot fails loudly — but it means every stack touching this
  repository's sources inherits ruff-03's figures as work. This is the second stack to pay it.
- **No performance measurement.** The seam adds one array parameter on a non-hot path and the roadmap
  asks for performance records only where a prompt makes a performance claim. This one makes none.
- **`RRE-FINAL` did not measure the rebuild fanout on the frozen sample**, which `state/current.md`
  carried in as owed. `evidence/03` measures it on one module, and the mechanism is structural — the
  plugin's Lake library no longer contains `LeanFmt.Rules`, so no module in any project can depend on
  it. A 62-module measurement would confirm what the boundary gate already pins and was judged not
  worth a sample run; naming it here rather than silently dropping it.
