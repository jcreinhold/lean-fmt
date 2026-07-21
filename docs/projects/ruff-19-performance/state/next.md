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
- **Remaining, in order.** (1) `exact_child` / `child_analyze`, which is 79-84% of every cold run and is still one child process per file. (2) Watch and LSP profiling. (3) The adversarial `PositionIndex`-build fixture inherited from `ruff-15`, and `phase.positions_ms` measured against it -- it reads 0 ms on every workload so far. (4) A `formatter-integrated-built` workload. (5) The two-session concurrency test, last.
- **Do not re-measure under load.** `results/02-optimize.md` discards one run taken at load average 25 with five other `lean` processes resident. Check `uptime` and `ps -Ao rss,comm` before trusting a timing.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- No public `-j`, pinning, or strategy flag.
- Stop immediately on resource breach.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
