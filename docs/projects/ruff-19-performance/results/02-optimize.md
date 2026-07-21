---
claim_id: RPR-IMPL
prompt: 02-optimize
status: in-progress
---

# RPR-IMPL — Instrument the unmeasured region, then optimize what it shows

## What this claim delivers so far

`LeanFmt/Profile.lean` and thirteen new phase names (`notes/02-instrumentation.md`), which took the
accounted fraction on the two cold workloads from 0.9% and 46.1% to over 90% and so met G3
(`evidence/01-workloads.md` §5). Three optimizations found by reading the phases the instrumentation
produced, each verified against an unchanged output digest.

## Optimization 1 — a doubled Lake graph traversal in `exactSetup`

`Project.exactSetup` walked the shared no-build graph twice, once to probe currency and once to read
the setup out of it; `officialArtifacts` did the same. Collapsed to one traversal, with the probe's
result reused. `phase.exact_setup_ms` on `self` `format --check` cold: 7,272 ± 100 ms →
3,612 ± 55 ms, **−50.3%**.

The probe cannot simply be dropped in favour of the fetch: `Lake.finalizeBuild` calls
`IO.Process.exit` when a `noBuild` fetch fails, so the application must decide currency before it
asks for the value. `Project.noBuildValue?` is that shape, and it is why the traversal could be
merged rather than removed.

## Optimization 2 — one unbuilt module cost 30% of a cold `check`

`phase.cache_write_ms` was **9,827 ms on a cold `mathlib-sample` `check`, 38% of the run.** Bracketing
inside `ResultCache.writeAll` put 9,799 ms of it in `write_closures`; bracketing inside that put
**7,018 ms in `workspace_artifacts`** — one call to `ResultCache.workspaceArtifactsDigest`, which
walks every `.olean` in the target's build directory and validates each one's trace.

That digest is the *fallback*: `closureDigest?` returns `none` when currency cannot be established for
a closure member, and `none` degrades to the coarse whole-workspace digest rather than to a permanent
miss. A temporary diagnostic named the member: `Archive.Arithcc`, which is `Archive/Arithcc.lean` —
**one of the 62 files in the workload, and not built in this mathlib checkout.** Its own artifacts are
absent, so its trace read fails, so its precise digest fails, so all 62 entries paid for a
whole-workspace walk to key the one entry that could not be keyed precisely.

### The fix, and why it does not weaken currency

`closureDigest?` treated every failure as one answer. It now distinguishes two, through a
`MemberFact`:

- **`unbuilt`** — the module has *none* of the four outputs Lake would write (`.olean`,
  `.olean.server`, `.olean.private`, `.trace`). It has no compiled output, so it contributed no
  grammar to anything, and that is a fact about the closure. It enters the digest as the part
  `closure <name> unbuilt`.
- **`unreadable`** — output may exist but its currency cannot be recomputed: trace absent beside a
  present `.olean`, unparseable, or of an unrecognized schema. Still `none`, still the fallback.
  `RCI-SPEC` froze the direction an unknown degrades and this does not touch it.

The distinction is **checked, not inferred**. Reading "no hash from the trace" as "unbuilt" would be
wrong: a stale `.olean` beside a missing trace is output whose currency is genuinely unknown. So the
`unbuilt` branch stats all four paths and takes any hit as `unreadable`.

The new part is *more* precise than what it replaces, not less. Under the fallback, the entry's key
moved whenever anything in the workspace was rebuilt. Under `closure <name> unbuilt`, it moves exactly
when that member gains compiled output — which is the event that matters.

### Measured

`mathlib-sample`, `check`, `--output-format concise`, output digest `c0dc55c3…` on every row —
identical to the `RPR-SPEC` baseline, so this is the same 27 findings before and after.

| Run | Before | After | Change |
| --- | ---: | ---: | ---: |
| cache-cold | 24,696 ms | 7,656 / 7,106 / 7,099 ms | **−71%** |
| cache-warm | 10,863 / 11,706 / 11,394 ms | 3,557 / 3,543 ms | **−67%** |

The warm side improves for the same reason: `readAll` computes the same closure digests, so it hit the
same fallback.

Phase-level, on the cold run:

| Phase | Before | After |
| --- | ---: | ---: |
| `cache_write` | 9,827 ms | 1,365 ms |
| `workspace_artifacts` (sub-phase) | 7,018 ms | not reached |
| `module_evidence` | 5,938 ms | 1,606 ms |

`module_evidence` was never the target and no code in it changed. It is page-cache-bound, and the
section below measures it swinging 1,687–5,916 ms with no code change at all — so this row is not a
second optimization and the 5,938 → 1,606 figure is not a result. It is here because leaving it out
of the table would make the `cache_write` row look like less of the total than it is.

Accounted fraction after: **95.1%** cold, **97.2%** warm.

### Why the `self` workload does not move

`phase.cache_write_ms` on `self` `format --check` cold is 272 ms, of which `write_closures` is 46 ms:
this repository has no unbuilt module in any target's closure, so the fallback was never reached and
there is nothing here to remove. The change is a no-op on `self` by construction, and that is the
honest statement rather than a re-measurement — the `self` run taken after the fix (97,434 ms against
a 43,506 ms baseline) was taken at load average 25 with five other `lean` processes holding 1.3–1.6
GiB each, and is discarded as contaminated rather than reported.

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
app=$PWD/.lake/build/bin/lean-fmt

rm -rf ~/Code/mathlib4/.lean-fmt-cache
LEAN_FMT_PROFILE_PHASES=1 experiments/profile-run.sh \
  --name rpr-i4-sample-check-cold --project-root ~/Code/mathlib4 \
  --build-state ordinary-built --cache-state formatter-cache-cold \
  --sources experiments/workloads/mathlib-v4.32.0-sample.txt \
  -- experiments/run-check-workload.sh "$app" ~/Code/mathlib4 \
     experiments/workloads/mathlib-v4.32.0-sample.txt check --output-format concise
```

Raw profiles: `experiments/results/rpr-i4-sample-check-{cold,warm}-*`. The intermediate bracketing
runs that located the cost are `rpr-cachewrite-cold-*`, `rpr-closure-cold-*`, and
`rpr-fallback-cold-*`; those were taken without `--output-format concise`, so their output digest is
`17d744ae…` rather than `c0dc55c3…` — the same report in the default format, not a different result.

## The variance that qualifies both numbers above

Re-measuring the cold `mathlib-sample` run four times exposed a confound worth naming before it
misleads someone:

| Cold `mathlib-sample` `check` | Wall | `phase.module_evidence_ms` |
| --- | ---: | ---: |
| first run after the build directory fell out of the page cache | 14,028 ms | 5,916 ms |
| three back-to-back runs after it | 8,136 / 7,597 / 7,610 ms | 2,226 / 1,687 / 1,697 ms |

**`module_evidence` swings 1,687–5,916 ms on page-cache state alone**, with no code change and the
same output digest, and it carries most of the wall difference between those two conditions. The
24,696 ms `RPR-SPEC` baseline was itself a first-run-after-idle measurement, so the honest form of the
comparison is: cold `mathlib-sample` `check` went from **24,696 ms to 7,597–8,136 ms page-cache-warm
and 14,028 ms page-cache-cold**.

The −71% headline is not weakened by this, because the thing it claims is a *phase*, measured
directly: `cache_write` 9,827 → 1,365 ms, and `workspace_artifacts` 7,018 ms → never reached. Those do
not move with the page cache. What the confound does weaken is any attempt to read a wall-clock delta
here as a per-commit gate, which is why `RPR-FINAL`'s gates should be growth ratios and phase values
rather than wall times — the convention `tests/layout/bench.sh` already follows.

## Optimization 3 — 34 traversals of one Lake graph

`phase.exact_setup_ms` was 3,531 ms on a cold `self` `format --check`, of which `setup_probe` was
3,528: `Project.exactSetup` constructs a Lake build context, starts a build and monitors it **once per
target**, and the graph it walks is the same graph every time.

`Project.exactSetups?` collects every target's setup job into a single `startBuild` — the shape
`Project.importClosures?` already uses for currency closures — and `ExactRun.primeSetups` fills a
per-run map from it before the analysis loop begins.

**It is primed with the frontend-bound subset, never the whole selection.** The set is already known
at both batch call sites: in `execute` it is the snapshots the cache and the source tier left
unanswered, and in `organize` it is the snapshots that have a candidate rewrite. On `self` all 34
reach the frontend and one traversal replaces 34; on `mathlib-sample` exactly **1 of 62** does, so
priming the whole selection would resolve 61 setups nothing asks for. `primeSetups` returns
immediately below two targets, which is why the sample's numbers above are unchanged by this
optimization.

**The map is keyed on the source bytes, not the path.** A setup carries the header's imports, and this
run's writing modes hand the frontend a *rewritten* snapshot at the same path: `fix` may reorder or
drop an import (FMT006, FMT007) and `organize` exists to. A path-keyed map would have validated a
rewritten file against imports it no longer has — precisely the check those modes perform. The stored
source is compared on every hit, and a mismatch falls through to the per-target path.

Nothing about this batches a *decision*. `exactSetups?` degrades to all-`none` on any failure, and a
`none` sends that target to `exactSetup`, which builds. It is an optimization over the probe only.

### Measured

`self`, `format --check`, cache-cold, `--output-format concise`, output digest `e3b0c442…` (the empty
string — this repository is lint-clean and canonically formatted) on every row.

| | Before | After |
| --- | ---: | ---: |
| Wall | 42,676 ms | 36,747 / 38,369 / 36,196 ms (**−13%**) |
| `exact_setup` | 3,531 ms over 34 probes | **0 ms** over 34 hits |
| `setup_prime` | — | **105 ms**, once |

### What is left in `exact_child`, and why it is not pursued

After this, `exact_child` is 31,236 ms of a 36,747 ms run — **85%** — and `child_analyze` is 28,381 of
that. The remaining 2,855 ms is 84 ms per file of process overhead, and it was attributed rather than
guessed at:

- `child_setup`, a new bracket around the child's `ModuleSetup` read and parse, reads **0 ms on all 34
  files**. The suspicion that a deep closure's setup JSON was expensive to parse is retired.
- Bare `lean-fmt --version` startup is 42–71 ms measured directly, for a 175 MB binary. That is most
  of the 84 ms and it is dyld mapping the executable.

So `exact_child` is 91% the Lean frontend elaborating the module, and the overhead around it is
dominated by loading a binary that must contain the frontend. The two structural ways to remove it are
both closed: sharing one environment across files would elaborate a file against imports it does not
have, which `CLAUDE.md` forbids under "preserve exact ordered imports … and validation identity"; and
a persistent worker is the archived worker protocol, which `CLAUDE.md` forbids restoring. This is
recorded as a floor, not as an open optimization.

## The language server, profiled — and one floor found rather than removed

The server was uninstrumented, but it needed no new phases of its own: every answer is
`Application.ExactRun.streamSnapshot` over one document, so the existing schema already covers a
request end to end. Running `tests/lsp/acceptance.sh` under `LEAN_FMT_PROFILE_PHASES=1` — 165 requests
across its sessions — gives the first per-request breakdown this project has had:

| Phase | Total | Calls | Mean |
| --- | ---: | ---: | ---: |
| `exact_child` | 46,681 ms | 165 | 282 ms |
| `child_analyze` (sub-phase) | 29,792 ms | 164 | 181 ms |
| `exact_setup` | 17,290 ms | 165 | **105 ms** |
| `envelope_decode` | 6 ms | 164 | 0 ms |

**Every request pays a full Lake no-build graph traversal, and it is 27% of request latency**
(105 of roughly 390 ms). `ExactRun.primeSetups` cannot help: a request analyzes one document, and
priming returns immediately below two targets.

### Why it is not cached, with the measurement that settles it

The obvious fix is to reuse the setup across a session's requests, keyed on the import header rather
than the whole source, so typing in the body does not invalidate it. That is unsound, and splitting
the probe says exactly why:

| Sub-phase | Mean over 165 requests |
| --- | ---: |
| `nobuild_context` — `mkJobQueue`, `mkMonitorContext`, `mkBuildContext'` | **0 ms** |
| `nobuild_fetch` — `startBuild` and `monitorBuild` | **104 ms** |

None of the cost is context construction, so building the context once per session saves nothing. All
of it is the fetch, and **the fetch is the currency check** — it reads the artifacts on disk *now*.
A session that cached its result would keep elaborating against artifacts a `lake build` in another
terminal has already replaced, which is the exact failure `noBuildValue?` exists to catch and which
`CLAUDE.md` forbids approximating: "Filesystem presence or a raw path is not build validity."

So this is recorded as a floor. Removing it needs a *cheaper currency signal*, not a cache — a watch
on the build directory that invalidates the session's setups — which is a design change with its own
correctness surface, not an optimization, and it is named in `state/current.md` for whoever takes it.

### A defect in the profile channel, found by using it

The first attempt to measure this split emitted nothing at all. `noBuildValue?` redirects both stdout
and stderr into its own buffer for its whole duration — deliberately, so Lake's monitor cannot draw a
spinner over our stderr — and `withPhase` writes to stderr. **Any phase bracketed inside that function
went into the buffer and was discarded with it.** The two sub-phases are therefore timed with
`IO.monoNanosNow` and reported by `recordDuration` in the `finally`, after the streams are restored.
Worth knowing before someone instruments in there again and reads the silence as zero cost.

## A phase that measured nothing, and what it voided

`ruff-15` handed this stack an unmeasured claim: `report-bench` builds its `PositionIndex` *outside*
the clock, so index build — the one part of rendering that is O(source bytes) rather than O(findings)
— had never been measured. `phase.positions_ms` was added for it and read **0 ms on every workload in
this stack**. That reading was wrong, and the fixture below is what exposed it: a 4 MB file whose only
finding sits at the last byte still reported 0 ms, which is not a believable number for a full
normalize, a `toUTF8` copy, and a byte walk.

The site was:

```lean
withPhase "positions" <| pure (resolvePositions snapshots files)
```

**Lean is strict, so the argument to `pure` is evaluated to build the closure before `withPhase` is
ever entered.** The bracket timed an already-computed value. Rewriting it as `withPhase "positions" do
let index := resolvePositions ..; return index` did *not* fix it — the compiler is free to float a pure
computation that does not depend on the action's state out of the closure, and it still read 0 ms. Only
`IO.lazyPure fun _ => ..` forces the work inside the bracket, because a thunk is forced when the action
runs.

### What this voids, and what it corrects

- **Every `positions_ms` reading in this stack is void.** The real numbers are below.
- **`child_encode` was under-measured too.** `notes/02-instrumentation.md` §3.6 recorded it as "0 ms"
  and used that to retire the suspicion that a ~10×-source projection was expensive to serialize. With
  the same `IO.lazyPure` treatment it reads **17 ms across 8 files, about 2 ms each**. The suspicion is
  still retired — 2 ms against 180 ms of elaboration in the same child — but the number it was retired
  against was wrong, and the note now says so.
- No other phase is affected: every other bracket wraps a genuinely effectful action, which cannot be
  floated.

## The `PositionIndex` fixture, and `ruff-15`'s guess

`experiments/run-positions-bench.sh` generates four shapes at one size into `tests/reporting/`, which
`lean-fmt.toml` excludes, so they never enter the lint corpus or the printer's shape evidence. They are
generated and removed rather than committed. The finding is `FMT003` (forbidden control byte): it fires
anywhere in the source, needs no frontend, and is report-only.

| shape | 1 MB | 4 MB | 16 MB |
| --- | ---: | ---: | ---: |
| `early` — one finding a few bytes in | 0 ms | 4 ms | 12 ms |
| `late` — one finding a few bytes from the end | 6 ms | 30 ms | 105 ms |
| `many` — findings spread evenly | 8 ms | 43 ms | 178 ms |
| `oneline` — whole body on one line, finding at the end | 6 ms | 28 ms | **212 ms** |

**`ruff-15` guessed the adversarial shape correctly and I had reasoned it wrong.** Reading
`positionsOf` — a single linear pass over *sorted* offsets — I concluded that position could not
matter and that only size could. The walk does stop at the last offset it needs, which is exactly why
position matters: a finding at the end costs a full pass and one at the start costs almost none.
**7.5× between `early` and `late` at the same 4 MB.** The `early` row is the floor that is paid
regardless — `LosslessSource.normalize` plus `toUTF8` over the whole file, for any file with at least
one finding.

The half of the guess that does *not* hold at ordinary sizes is the enormous line: at 1 MB and 4 MB
`oneline` matches `late`, so the column counter costs nothing extra. At 16 MB it is 2× `late`, which is
one sample at one size and is flagged rather than explained.

This is linear in the size that matters and modest in absolute terms — 105 ms for a 16 MB file is not a
defect. It is recorded so that a future change that makes it quadratic has a number to be caught
against, which is what `ruff-15` asked for.

**Watch mode is not on this list.** A watch generation runs the same `Application.execute` path the
batch modes do and `render_report` already brackets its per-generation rendering, so the `self` warm
baselines are the watch numbers; there is nothing separate to profile.

## The compiler integration, measured for the first time

`evidence/01-workloads.md` named `formatter-integrated-built` as a state and then said no frozen
workload was in it. It now has one: four modules this repository builds *with*
`LeanFmtCompilerPlugin` (`tests/compiler/LocalSyntax.lean`, `tests/check/{Clean,Findings,Layout}.lean`),
so each `.olean` carries a `leanFmtArtifact`.

**Getting into the state is most of the finding.** Two of the three obvious commands do not exercise
the artifact path at all:

| Command on the integrated modules | `official_artifacts` | `exact_child` |
| --- | ---: | ---: |
| `check` (source tier only) | 0 ms | never runs — nothing above source is demanded |
| `format --check` | **absent** | 4 runs, 1,186 ms — the semantic demand skips the facet entirely |
| `check --preview --select FMT012` (syntax tier) | **105 ms** | never runs |

Only a syntax-tier selection sits in the band where the artifact is both sufficient and necessary,
and that is the comparison. The same command over four *ordinary-built* modules (`LeanFmt/Digest.lean`,
`Profile.lean`, `Config.lean`, `Doc.lean`):

| State | `official_artifacts` | `exact_child` | `setup_prime` |
| --- | ---: | ---: | ---: |
| `formatter-integrated-built` | 105 ms | **never runs** | — |
| `ordinary-built` | 101 ms (finds nothing) | 2,058 + 370 + 634 + 221 = **3,283 ms** | 100 ms |

**One Lake traversal replaces four frontend child processes — about 820 ms per module.** That is the
claim the compiler plugin was built on, and until now it was an argument rather than a number.

Two things this measurement is not. It is not a speed benchmark: four small fixture modules are not a
project, and the per-module frontend cost above is dominated by the first child's 2,058 ms of
process and import startup, which the later three do not pay. And it does not say the integration is
free — building with the plugin costs artifact-sized `.olean` growth that `docs/adding-a-rule.md`
already quantifies at ~25 B per element.

### A cost the ordinary-built column exposes

`official_artifacts` costs **101 ms on a workspace that cannot possibly have an artifact**, and it
pays that before finding nothing. The magnitude is unsurprising — it is the same no-build graph
traversal as `setup_prime` at 100 ms, and Optimization 3 already showed that one traversal is the
unit of cost here. But a workspace where no module declares the plugin can never produce an artifact,
and that is decidable from the workspace configuration without traversing anything.

It is not fixed here. It is one traversal per run, not per module, so it does not grow with the
workload, and this stack's remaining work is the concurrency test and the durable gates. It is
recorded so it is a choice with a reason rather than something nobody looked at.

## The two revisits the roadmap inherits

`roadmap.md` line 43 assigns `RPR-IMPL` two named optimization revisits from earlier stacks. Both are
settled here, and neither turns into work — for opposite reasons.

### `ruff-10b` Design B (parse-only re-projection): the trigger has not fired

`ruff-10b` rejected Design B for v1 and named its revisit condition exactly: *"if a syntax rule
graduates to default and the gated re-projection lands on the default run cost budget"*
(`ruff-10b/results/03-final.md`).

It has not. Every syntax-tier rule in `LeanFmt/Rules.lean` — FMT009 through FMT014 — carries
`defaultEnabled := false` and `lifecycle := .preview`. The re-projection is still behind a gate no
default run opens.

And this stack can now say that as a measurement rather than a reading of the source. On the
`integrated` modules, a plain `check` records `phase.official_artifacts_ms` = **0 ms** and never
enters the syntax path at all; the same modules under `check --preview --select FMT012` record
105 ms. The default run cost budget does not contain the re-projection, so there is nothing for
Design B to be cheaper than.

### `ruff-01`'s node table: the premise was overtaken by the code

`ruff-01` handed this forward as an open question with a price on it: the node table is **45.6% of a
real artifact** (187,902 B of 411,671 B) and is *"read by nothing but the probe differential"*, so
whether the full flattened tree is the right granularity was unmeasured
(`ruff-01/results/03-acceptance.md`, `ruff-01/state/current.md`).

**That premise is now false, and built code is what decides.** `LeanFmt/Printer.lean` — the canonical
printer, the product's central feature, which did not exist when `ruff-01` wrote that — walks the
node table end to end (`for node in [0:tree.source.nodes.size]`), resolves kinds through
`Tree.kindOf`, and follows `parent` chains to arbitrary ancestors. All six syntax-tier rules index it
for ranges and child adjacency. The table is load-bearing, not dead weight.

There is also no field-level fat left to trim. `LosslessSource.Node` is three fields — `kind`,
`parent`, `range` — and the printer reads all three.

So the granularity question narrows to one lever: **prune the tree to the node kinds the formatter
actually dispatches on.** The printer matches 33 distinct kind strings and the rules two more, a
fixed and enumerable set, so this is mechanically possible with parent re-linking.

**It is refused, on a constraint this project already paid to establish.** A kind-pruned artifact
encodes formatter implementation knowledge — it would hold what the current printer happens to match,
which is a step toward findings and away from facts, against `CLAUDE.md`'s "the module artifact holds
the projection and nothing else — facts, never findings." The concrete cost is the one already
learned once: editing the printer's kind list would invalidate every integrated module's Lake trace,
the same coupling that was removed when the rules were made unreachable from the plugin. Trading a
rebuild of every downstream module for at most 45.6% of an `.olean` section is the wrong side of that
trade, and it is the trade the project has already made in the other direction deliberately.

Recorded as settled rather than deferred: the question `ruff-01` could not answer was "does anything
read it," and the answer is now yes, decisively.

## Still open under this claim

- The two-session concurrency test, only after all single-session work.
