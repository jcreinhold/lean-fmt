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

## Still open under this claim

- Watch and LSP profiling.
- The adversarial `PositionIndex`-build fixture inherited from `ruff-15`.
- A `formatter-integrated-built` workload.
- The two-session concurrency test, only after all single-session work.
