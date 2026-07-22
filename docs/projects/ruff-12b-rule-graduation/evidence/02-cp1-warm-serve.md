# CP-1 probe — does the warm cache serve a tier above source?

`results/01-criteria.md` §5.2 made CP-1 (the `ruff-19` §1 warm-served gates) absolute, and recorded
that it rested on a **prediction that had never been tested**: that the aggregate semantic-result
cache, being content-keyed, replays a warm hit regardless of the tier that produced it. No default
rule has ever demanded a tier above source, so nothing in the product had ever exercised it.

`state/next.md` named this the thing to test first, because a false prediction changes the shape of
the whole stack. **It is true.**

## Method

`experiments/run-cp1-warm-serve.sh`. Five arms over `experiments/workloads/lean-fmt-self.txt`
(34 modules, `ordinary-built`): today's default five, then that set plus one syntax-tier rule, plus a
syntax-tier *fixable* rule, plus a semantic-tier rule, then plus all ten preview rules.

No rule's `defaultEnabled` was changed. The graduated default set is simulated with
`--select default --select FMT0NN`, which is the same execution path a default selection takes once
`Config.resolveAxis` has produced the enabled set — the tier demand that drives `RulePlan` comes from
the resolved set, not from how it was spelled.

Each arm primes, then measures the warm repeat, asserting `ruff-19`'s own predicates from
`tests/performance/gates.sh` — §1a `gate_targets_match`, §1b `gate_fully_served`, §1c
`gate_no_frontend_work` — all of which are counts, so the result is valid on a loaded machine. The
frozen-sample precision run was in fact running concurrently.

## Result

| Arm | targets | index_hits | `exact_child` | `exact_setup` | report lines | gates |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| baseline (default, 5 rules) | 34 | 34 | 0 | 0 | 0 | ok |
| + FMT012 (syntax) | 34 | 34 | 0 | 0 | 0 | ok |
| + FMT013 (syntax, fixable) | 34 | 34 | 0 | 0 | 0 | ok |
| + FMT015 (semantic) | 34 | 34 | 0 | 0 | 0 | ok |
| **+ all ten preview** | 34 | 34 | **0** | **0** | **17** | **ok** |

## Why the zero counts are not self-confirming

Zero `exact_child` with an empty report is exactly what a cache serving the *wrong* thing would
print: a stale source-tier entry replayed under a higher-tier selection, with the higher-tier findings
silently missing, produces those same numbers. The first four arms are individually vacuous for that
reason — lean-fmt's own tree is clean for the default five and for FMT012, FMT013, and FMT015 alone.

The last arm is what makes the probe mean something. With all ten preview rules selected, the warm,
fully-served run with zero frontend children **emitted 17 findings**, and that report was byte-identical
to the cold run's (`cmp -s`, `ruff-19` §4's `gate_reports_identical` condition). A cache that had
dropped the higher tier would have emitted nothing.

So the cache genuinely serves syntax- and semantic-tier results from a warm hit. All 17 are FMT008
(missing module docstring), across lean-fmt's own modules.

## What this settles, and what it does not

**Settles:** graduating a rule of any tier does not threaten `ruff-19`'s §1a/§1b/§1c gates. CP-1 is
satisfiable by every candidate set, and §5.2's escape hatch — "if a candidate set does break §1c, the
cache is failing to serve a tier it should serve" — is not needed.

**Does not settle:** anything about the cold or changed-file path, which is where §5.3's CP-2 budget
and `ruff-19`'s measured ~408 ms marginal per module live. CP-1 says a *repeat* run of an unchanged
project is free. It says nothing about the first run, or about the run after an edit, which is the
run a developer actually waits on.

## Incidental finding, carried to the FMT008 verdict

All 17 self-corpus findings are FMT008, i.e. **lean-fmt's own 34 modules do not carry module
docstrings**, and `lake lint` — which runs the formatter on this repository under `lean-fmt.toml` —
passes today because FMT008 is preview and therefore outside `all`.

Per §6.3 this is not independent exposure evidence: the rules and this code were written by the same
project. It is, however, direct §2.4 opinionation evidence, and the FMT008 verdict in
`results/02-evidence.md` must address it. A rule that the repository shipping it does not itself
follow has an opinionation problem that no false-positive count will surface.
