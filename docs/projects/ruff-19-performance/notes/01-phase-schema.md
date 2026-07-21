# The phase schema

`RPR-SPEC`. What a profiled `lean-fmt` run is allowed to say about itself, which names are frozen,
which names `RPR-IMPL` must add, and the one test that decides whether the schema is finished.

## 1. The channel

`LEAN_FMT_PROFILE_PHASES=1` turns on a stderr diagnostic channel with two record kinds:

```
phase.<name>_ms=<integer>
cache.<name>=<integer>
```

`LeanFmt/Application.lean:1252-1268` owns all three emitters (`recordPhase`, `recordDuration`,
`recordCount`). The channel is not a reporting surface: it is off by default, writes to stderr, never
enters `RunReport`, and no exit code depends on it. `experiments/profile-run.sh` retains both kinds
into the run's `.phases` file.

Both kinds are load-bearing and neither substitutes for the other. Wall time cannot distinguish "the
cache served this run" from "the page cache was warm" — that ambiguity is what made `ruff-16` read a
whole-project cache-key invalidation as an in-process reuse defect (`ruff-16b` `RCI-SPEC`). Counts
settle it; timings cannot.

## 2. Frozen names

These exist today and must keep their spelling and their meaning. A rename is a schema revision, not
a refactor: saved profiles in `experiments/results/` are keyed on these strings.

| Name | Brackets | Site |
| --- | --- | --- |
| `phase.discovery_ms` | `Discovery.run`: the config walk and the selection walk together | `Application.lean:1293-1295` |
| `phase.workspace_load_ms` | Lake workspace load inside `Project.load` | `Application.lean:1308` |
| `phase.selection_snapshot_ms` | exact module selection and source snapshots | `Application.lean:1309` |
| `phase.import_findings_ms` | `computeImportReports` — the import tier, FMT005/006/007 | `Application.lean:1336` |
| `phase.cache_epoch_ms` | `ResultCache.open?`: epoch computation and index open | `Application.lean:1344` |
| `phase.cache_lookup_ms` | `cache.readAll`, including per-entry closure digests | `Application.lean:1350` |
| `phase.module_evidence_ms` | `Project.moduleEvidence` | `Application.lean:1403` |
| `phase.official_artifacts_ms` | `officialArtifacts` facet fetch | `Application.lean:1417` |
| `cache.targets` | selected files this run | `Application.lean:1384` |
| `cache.index_hits` | entries the index answered with | `Application.lean:1385` |
| `cache.served` | of those, entries that survived the tier/caps demotion | `Application.lean:1386` |

`index_hits` and `served` differ exactly when a stored result cannot answer this run's mode, which is
why both are reported: it separates "the entry was invalidated" from "the entry was inadequate."

## 3. What the schema does not yet cover

Measured at `369057d`, over the frozen workloads (`evidence/01-workloads.md`). *Accounted* is the sum
of the emitted `phase.*` values against the wrapper's `wall_ms`:

| Workload | Wall | Accounted | Fraction |
| --- | ---: | ---: | ---: |
| `self` `check`, cache-warm | 564 ms | 418 ms | 74.1% |
| `mathlib-sample` `check`, cache-warm | 10,863 ms | 10,571 ms | 97.3% |
| `mathlib-sample` `check`, cache-cold | 24,696 ms | 11,388 ms | 46.1% |
| `stress-largest` `format --check`, cache-cold | 19,152 ms | 4,088 ms | 21.3% |
| `self` `check`, cache-cold | 21,099 ms | 370 ms | **1.8%** |
| `self` `format --check`, cache-cold | 43,506 ms | 380 ms | **0.9%** |

**The schema explains the runs that are already fast and says nothing about the runs that are slow.**
Every cold run's missing time is in one place: `withExactRun` and the per-snapshot loop under it
(`Application.lean:1431-1468`), which is unbracketed end to end. That region holds the exact frontend,
every rule tier above import, layout, validation, and cache writes — the six things the completion
contract asks this stack to profile separately, currently reported as one unnamed 43-second gap.

This is the schema's defect and `RPR-IMPL` owns closing it. It is stated here as a number so that
closing it is checkable rather than a matter of opinion.

## 4. Names `RPR-IMPL` must add

Each is placed at a site that exists today, so the schema is a claim about this code and not about a
design someone might build.

| Name | Brackets | Site today |
| --- | --- | --- |
| `phase.config_ms` | config resolution, split out of the selection walk | inside `Discovery.run` |
| `phase.exact_setup_ms` | `withExactRun` up to the first snapshot: child spawn and module setup | `Application.lean:1431` |
| `phase.parse_ms` | frontend parse per run | inside `analyzeSnapshot` |
| `phase.capture_ms` | semantic capture (notations, diagnostics, occurrences) | inside `analyzeSnapshot` |
| `phase.rules_source_ms` | the source tier | inside `previewFile`/`fixFile` |
| `phase.rules_syntax_ms` | the syntax tier | inside `previewFile`/`fixFile` |
| `phase.rules_semantic_ms` | the semantic tier | inside `previewFile`/`fixFile` |
| `phase.layout_ms` | `LeanFmt.Printer` render | `formatFile`, `previewFile .format` |
| `phase.layout_fit_ms` | **sub-phase of `layout_ms`**: phase-2 reflow `group` and fit tests | `LeanFmt.Doc` |
| `phase.validation_ms` | the validator child a writing `format`/`fix` must pass | `withExactRun` |
| `phase.cache_write_ms` | `cache.writeAll` | `Application.lean:1428`, `:1466` |
| `phase.positions_ms` | `resolvePositions` — `PositionIndex` **build** | `Application.lean:1399`, `:1430`, `:1468` |
| `phase.render_report_ms` | `formatReport` | `LeanFmt.Cli` |

The import tier needs no new name: `phase.import_findings_ms` already is it.

Two of these are inherited requests rather than bookkeeping. `phase.layout_fit_ms` is named by the
completion contract because `RLC-FINAL` already found one quadratic fit-test regression there
(`tests/layout/bench.sh`), and a sub-phase is how a second one gets noticed. `phase.positions_ms` is
`ruff-15`'s handoff: `report-bench` builds its index *outside* the clock
(`LeanFmtTest.lean:2850-2852`), so index build — the one part of rendering that is O(source bytes)
rather than O(findings) — has never been measured at all.

## 5. Invariants

1. **Top-level phases are disjoint.** A `phase.*` name brackets an interval no other top-level phase
   brackets. Nesting is allowed only for a name declared a sub-phase in §4, and a sub-phase is
   excluded from the accounted sum.
2. **A phase name means the same thing in every mode.** If a mode does not reach a phase, it emits
   nothing for it; it does not emit a differently-scoped interval under the same name.
3. **The channel cannot change an answer.** Nothing gated on `LEAN_FMT_PROFILE_PHASES` may allocate
   into, order, or short-circuit production work. It reads clocks and counters already computed.
4. **Completeness gate.** On every frozen workload, the accounted fraction is **≥ 90%**. §3 is the
   before picture; this is the after. Below 90%, the schema is not finished regardless of how many
   names it has.

## 6. Rejected: a `--profile` flag

Considered and not adopted. A CLI flag would make phase timing a public surface with a compatibility
obligation, and `roadmap.md`'s stop rules forbid exposing execution strategy through the CLI at all —
a user who can ask for phases will ask why one is slow and then ask to turn it off. The environment
variable is already the repository's convention for diagnostics that are evidence rather than product
(`LEAN_FMT_PROFILE_PHASES`, `LEAN_NUM_THREADS`), and `experiments/profile-run.sh` is the supported
consumer. Nothing in the schema is a promise to a user.
