# Next Proof Packet

- Stack: ruff-19-performance
- First unresolved: 02-optimize
- Claim ID: RPR-IMPL
- Prompt: 02-optimize
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RPR-IMPL**: Profile representation, layout, rule tiers, validation, rendering, watch, and LSP. Optimize proven critical paths. Only after single-session work, test exactly two isolated sessions under the adoption rule.
- **Done and committed** (`results/02-optimize.md`): the phase schema closed to 95.1% / 97.2% accounted; a doubled Lake traversal in `exactSetup` removed (-50.3% on `exact_setup`); and the whole-workspace fallback digest removed from a cold `mathlib-sample` `check` (-71% cold, -67% warm, output digest unchanged).
- **Also done**: the batched setup probe (`exact_setup` 3,531 ms over 34 traversals -> 0 ms over 34 hits, wall -13% on `self`), and `exact_child` attributed and closed as a floor rather than a target.
- **Also done**: the language server profiled over 165 requests (`exact_setup` is 105 ms, 27% of request latency, and is a floor -- the probe *is* the currency check, `nobuild_context` 0 ms / `nobuild_fetch` 104 ms). Watch needs no separate profiling; a generation runs the same `execute` path.
- **Also done**: `ruff-15`'s `PositionIndex` handoff, via `experiments/run-positions-bench.sh` -- and the phase that was supposed to measure it was timing nothing (`withPhase <| pure e` evaluates `e` before the bracket; use `IO.lazyPure`). Every prior `positions_ms` and `child_encode` figure is void and corrected.
- **Remaining, in order.** (1) A `formatter-integrated-built` workload. (2) The two-session concurrency test, last.
- **Before recording any new phase figure**, check the bracket wraps an effectful action. A pure value bound inside `withPhase` gets floated out of the closure and the phase reads 0 ms.
- **For `RPR-FINAL`**: build the per-commit gates from growth ratios and phase values, never wall times. `module_evidence` alone swings 1,687-5,916 ms on page-cache state with no code change (`results/02-optimize.md`).
- **Do not re-measure under load, and do not trust a first run.** `results/02-optimize.md` discards one run taken at load average 25 with five other `lean` processes resident. Check `uptime` and `ps -Ao rss,comm` before trusting a timing, and take at least three back-to-back runs -- the first after an idle period reads roughly 1.8x the settled value.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- No public `-j`, pinning, or strategy flag.
- Stop immediately on resource breach.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
