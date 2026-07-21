# The schema as built

`RPR-IMPL`. What the profile channel actually emits now, where each name is bracketed, and every
place the built schema departs from the one `RPR-SPEC` froze in `notes/01-phase-schema.md` §4 —
with the measurement that caused the departure.

## 1. Where the channel lives

`LeanFmt/Profile.lean`, a new leaf module. It started inside `LeanFmt.Application`, which is where the
first phases were, and had to move the moment `RPR-IMPL` needed to bracket `Project.exactSetup`:
`Application` imports `Project`, so a phase cannot be emitted from below the module that owns the
emitter.

It is deliberately not in `LeanFmt.Basic`. `lakefile.lean` globs `Basic` into
`LeanFmtCompilerPlugin`, which links into every compilation of every module of an integrating project;
a timer living there would make editing it invalidate every integrated module's Lake trace — the exact
failure that removed `LeanFmt.Rules` from that library. Nothing globs `LeanFmt.Profile` and nothing in
the plugin's import closure reaches it. `scripts/CheckModules.lean` still covers it: a module is in the
build when something built imports it, and `Project` does.

`withPhase` is the whole interface. It reports on the way out even when the action throws, because the
exact frontend child can fail after spending its entire budget and that is precisely the cost worth
seeing.

## 2. Names now emitted

Beyond the eight `RPR-SPEC` froze (`notes/01-phase-schema.md` §2), all still spelled the same:

| Name | Brackets | Site |
| --- | --- | --- |
| `phase.exact_setup_ms` | resolving one module's Lake setup and writing the child's inputs | `Application.lean`, `ExactRun.envelope` |
| `phase.setup_probe_ms` | **sub-phase**: `Project.noBuildValue?`, the no-build graph traversal | `Project.lean`, `exactSetup` |
| `phase.nobuild_context_ms` | **sub-phase**: Lake job queue, monitor and build context construction | `Project.lean`, `noBuildValue?` |
| `phase.nobuild_fetch_ms` | **sub-phase**: `startBuild` and `monitorBuild` — the currency check itself | `Project.lean`, `noBuildValue?` |
| `phase.setup_build_ms` | **sub-phase**: the building fallback, when the probe says stale | `Project.lean`, `exactSetup` |
| `phase.setup_prime_ms` | one batched no-build traversal resolving every frontend-bound target's setup | `Application.lean`, `ExactRun.primeSetups` |
| `phase.exact_child_ms` | the exact frontend round trip: spawn, run, collect | `Application.lean`, `ExactRun.envelope` |
| `phase.child_setup_ms` | **sub-phase, emitted by the child**: reading and parsing the `ModuleSetup` | `Application.lean`, `runAnalyzeChild` |
| `phase.child_analyze_ms` | **sub-phase, emitted by the child**: `analyzeExact` itself | `Application.lean`, `runAnalyzeChild` |
| `phase.child_encode_ms` | **sub-phase, emitted by the child**: encoding the envelope to JSON | `Application.lean`, `runAnalyzeChild` |
| `phase.envelope_decode_ms` | parsing the child's JSON back into an `AnalysisEnvelope` | `Application.lean`, `ExactRun.envelope` |
| `phase.layout_ms` | `renderCanonicalText` — `Printer` plus `Doc`, fit tests included | `Application.lean`, `canonicalAnalysis` |
| `phase.rules_ms` | one file's report: every rule tier, suppression, fix composition | `Application.lean`, `execute` (three sites) |
| `phase.validation_ms` | **sub-phase**: the validator child a writing `format`/`fix` must pass | `Application.lean`, `formatFile`/`fixFile` |
| `phase.cache_write_ms` | `cache.writeAll` | `Application.lean`, `execute` (two sites) |
| `phase.write_closures_ms` | **sub-phase**: the batch's closure digests, inside `writeAll` | `Cache.lean`, `ResultCache.writeAll` |
| `phase.closure_resolve_ms` | **sub-phase**: `Project.importClosures?`, the no-build closure fetch | `Cache.lean`, `closureDigests` |
| `phase.closure_hash_ms` | **sub-phase**: one target's per-member trace reads | `Cache.lean`, `closureDigests` |
| `phase.workspace_artifacts_ms` | **sub-phase**: the whole-workspace fallback digest, at most once per run | `Cache.lean`, `workspaceArtifactsDigest` |
| `phase.positions_ms` | `resolvePositions` — the `PositionIndex` **build** | `Application.lean`, `profiledPositions` |
| `phase.render_report_ms` | `formatReport` | `Cli.lean`, `runOneGeneration` |

Sub-phases are excluded from the accounted sum, per `notes/01-phase-schema.md` §5.1.

**Two phases inside `noBuildValue?` are timed, not bracketed.** That function redirects stdout and
stderr into its own buffer for its whole duration, so Lake's monitor cannot draw over ours — which
means `withPhase`, which writes to stderr, emits into that buffer and is discarded with it. Nothing in
there can report on itself through the normal path. `nobuild_context` and `nobuild_fetch` read
`IO.monoNanosNow` and call `recordDuration` in the `finally`, after the streams are restored.

**The child's records cross the process boundary on stderr.** The exact frontend runs in another
process; its stdout is the envelope and takes no passengers. The parent forwards any `phase.` line it
finds in the child's captured stderr, which is what makes the elaboration/encode split visible from a
parent profile at all.

## 3. Departures from the frozen schema, and why

Each is a measurement, not a preference.

### 3.1 `rules_source` / `rules_syntax` / `rules_semantic` collapsed to one `rules`

`RPR-SPEC` asked for one phase per tier. Built as one, because the whole of it is **11 ms across 34
files** on a cold `format --check` and **1 ms across 62 files** on the mathlib sample. Splitting a
10-millisecond phase three ways is invented precision: the split would cost three brackets in the hot
loop and could not distinguish its parts from timer noise.

The tier structure is not lost — the import tier has had its own `phase.import_findings_ms` since
before this stack, and it is 795–1,437 ms, two orders of magnitude above the rest of the registry. If
`rules` ever becomes material, splitting it is a two-line change made against a number instead of an
expectation.

### 3.2 `layout_fit` is not a production phase

`RPR-SPEC` named a sub-phase for phase-2 reflow's `group`/fit-test cost. It is not here, and the
reason is structural rather than economic: `LeanFmt.Doc` is pure. Reading a clock inside it would make
the layout engine `IO`, which is a far larger change to the architecture than a diagnostic justifies —
and `CLAUDE.md` puts layout below the lifecycle for exactly that reason.

The measurement it wanted already exists out of production. `tests/layout/bench.sh` drives
`lean-fmt-tests doc-bench` over adversarial nesting and asserts *growth ratios*, which is the check
that actually caught the one real fit-test regression (`RLC-FINAL`, quadratic re-running of enclosing
fit tests). `phase.layout_ms` bounds the whole render from outside: 889–1,012 ms for 34 modules, about
29 ms each.

### 3.3 `parse` and `capture` became `child_analyze`

`RPR-SPEC` named them as if they were separable in the parent. They are not: `analyzeExact` runs the
frontend as one operation inside the child, and parse and capture are not two calls with a boundary
between them. `child_analyze` is the honest granularity — everything the frontend does — and
`child_encode` separates the part that is *not* frontend work.

### 3.4 `config` did not become its own phase

`phase.discovery_ms` is 4–6 ms on this repository and 368–430 ms on mathlib, where it is dominated by
the 8,795-file walk rather than by config resolution. Splitting config out of a 5 ms phase measures
nothing; on the workload where it is large, the walk is the cost, and that is already the phase's
name. Left as one.

### 3.5 Four brackets inside `writeAll` that measured nothing, and were removed

`write_load`, `write_order`, `write_serialize`, `write_collect` were added to attribute a 9,827 ms
`cache_write` and each read **0 ms** on a 62-module cold run. The suspicion they tested — that
serializing an index holding 62 full `SemanticAnalysis` values was the cost — is retired by that, and
the brackets are gone rather than kept as five zeros in every profile. `write_closures`, the one that
held 9,799 of the 9,827 ms, stayed and now has two sub-phases of its own.

### 3.6 `child_setup` measures zero, and is kept anyway

Unlike the four `writeAll` brackets, this one stays. It reads **0 ms on all 34 files** of a cold
`self` run, which is what retires the suspicion that a deep closure's `ModuleSetup` JSON was expensive
to parse — but it is also the only bracket that can see inside the 84 ms per file of process overhead
between the parent's `exact_child` and the child's `child_analyze`. A zero here is the load-bearing
half of the claim that the remainder is binary load (`results/02-optimize.md`), so it is worth its
line.

### 3.7 New names the schema did not anticipate

`setup_probe`/`setup_build`, `envelope_decode`, `child_encode`, and the four closure brackets above. All three exist because §4 of the
baseline note assigned phases to sites and these turned out to be the sites that mattered:
`setup_probe` is where the duplicate traversal was found, and `envelope_decode` (20–27 ms for 34
modules) and `child_encode` (0 ms) are how the suspicion that a ~10× projection was expensive to
serialize was *retired* rather than acted on.

## 4. What the schema now accounts for

| Workload | Wall | Accounted | Before |
| --- | ---: | ---: | ---: |
| `self` `format --check`, cache-cold | 50,284 ms | 90.6% | 0.9% |
| `mathlib-sample` `check`, cache-cold | 25,991 ms | 94.8% | 46.1% |
| `mathlib-sample` `check`, cache-cold, after `results/02-optimize.md` | 7,099 ms | 95.1% | — |
| `mathlib-sample` `check`, cache-warm, after `results/02-optimize.md` | 3,543 ms | 97.2% | 97.3% |

G3 (`evidence/01-workloads.md` §5) is met on both. The residual is process startup, CLI parsing, and
report writing — 23 ms of startup measured directly, the rest under the sampler's resolution.
