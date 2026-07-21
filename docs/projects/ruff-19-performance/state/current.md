---
kind: state
first_unresolved: 02-optimize
---

# Current state

`RPR-SPEC` is verified. The workloads, states, gates, and phase schema are frozen at `369057d`
(`results/01-baseline.md`). Its external prerequisite stacks are `ruff-04-formatter-product`,
`ruff-12-rule-lifecycle`, `ruff-17-lsp`; `ruff-17`'s recorded LSP numbers were re-measured live during
`01-baseline` and hold within 1.5%.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-baseline | RPR-SPEC | verified | — |
| 02-optimize | RPR-IMPL | in progress | RPR-SPEC |
| 03-regressions | RPR-FINAL | planned | RPR-IMPL |

## `RPR-IMPL` progress (not yet verified)

Instrumentation is built and the first optimization landed. `notes/02-instrumentation.md` is the
schema as built, including four names `RPR-SPEC` specified that measurement retired.

**Done.**

- **G3 is met.** Accounted fraction went 0.9% → **90.6%** on `self` `format --check` cold and
  46.1% → **94.8%** on `mathlib-sample` `check` cold. The profile channel moved to its own leaf module
  `LeanFmt/Profile.lean` so it could bracket `Project.exactSetup`, which `Application` imports.
- **One duplicate traversal removed.** `Project.exactSetup` ran the module's Lake setup graph twice per
  file — `isCurrent` computed the value and returned a `Bool`, then `runBuild` recomputed it.
  `Project.noBuildValue?` returns what the probe already built. `exact_setup` **7,272 ± 100 ms →
  3,612 ± 55 ms** over 34 modules, a 50.3% cut. The same duplication in `officialArtifacts` is
  removed the same way, and `withoutProcessOutput` went with it.
- **The probe cannot simply be dropped**, and Lake's source says why: under `noBuild`, a stale target
  makes `finalizeBuild` call `IO.Process.exit` (`Lake/Build/Run.lean:367-368`). `noBuildValue?` stops
  short of `finalizeBuild`, so staleness is a `none` instead of a dead process.
- **Two suspicions retired by measuring.** JSON round-tripping a ~10×-source projection costs
  `envelope_decode` 20–27 ms and `child_encode` 0 ms across 34 modules. The rule registry above the
  import tier is 11 ms across 34 files and 1 ms across 62. Neither is worth touching.

**Acted on, and the largest win in this stack so far** (`results/02-optimize.md`). `cache_write` was
9,827 ms on a cold `mathlib-sample` `check`, 38% of the run. Bracketing inside it put 7,018 ms in one
call to `workspaceArtifactsDigest` — the whole-workspace fallback, reached because **one of the 62
files, `Archive/Arithcc.lean`, is not built in this mathlib checkout**, so its precise closure digest
failed and every entry paid for a walk of mathlib's entire build directory. `closureDigest?` now
distinguishes `unbuilt` (none of the four outputs Lake writes exist — a fact about the closure, and a
checked one) from `unreadable` (currency genuinely unknown — still the fallback, still `RCI-SPEC`'s
frozen direction). Cold **24,696 → 7,099 ms (−71%)**, warm **10,863 → 3,543 ms (−67%)**, output digest
`c0dc55c3…` unchanged on every row. Accounted fraction 95.1% cold, 97.2% warm.

`module_evidence` fell 5,938 → 1,606 ms with it, without any code in it changing; that is the page
cache, not a second optimization, and it is recorded as such.

**Four brackets removed for measuring zero.** `write_load`, `write_order`, `write_serialize`,
`write_collect` each read 0 ms, which retires the suspicion that serializing an index of 62 full
`SemanticAnalysis` values was the cost.

**Third optimization: 34 traversals of one Lake graph.** `exact_setup` was 3,531 ms on a cold `self`
`format --check`, one full no-build context/start/monitor cycle per target over the same graph.
`Project.exactSetups?` collects every frontend-bound target's setup job into one `startBuild` — the
shape `importClosures?` already used — and `ExactRun.primeSetups` fills a per-run map before the
analysis loop. `exact_setup` **3,531 ms over 34 probes → 0 ms over 34 hits**, `setup_prime` 105 ms
once; wall 42,676 → 36,196–38,369 ms (−13%), digest `e3b0c442…` unchanged.

Two things make it safe rather than merely fast. It is primed with the **frontend-bound subset**, not
the selection: 34 of 34 on `self`, 1 of 62 on `mathlib-sample`, where it therefore does nothing. And
the map is keyed on the **source bytes**, not the path, because `fix` and `organize` hand the frontend
a rewritten snapshot at the same path and a setup carries the header's imports — a path-keyed map
would have validated a rewritten file against imports it no longer has.

**`exact_child` is a floor, not an open target.** It is 85% of a cold `self` run after the above, and
`child_analyze` is 91% of that — the Lean frontend elaborating. The 84 ms/file around it was
attributed, not guessed: `child_setup` (the child's `ModuleSetup` read and parse) is **0 ms on all 34
files**, and bare `lean-fmt --version` startup is 42–71 ms for a 175 MB binary. The two structural
ways to remove it are both closed by `CLAUDE.md` — a shared environment would elaborate a file against
imports it does not have, and a persistent worker is the archived worker protocol.

**A variance finding that qualifies every wall-clock number in this stack.** `module_evidence` swings
**1,687–5,916 ms on page-cache state alone**, no code change, same digest. The first cold
`mathlib-sample` run after the build directory ages out is 14,028 ms; three back-to-back runs after it
are 8,136 / 7,597 / 7,610. The `RPR-SPEC` 24,696 ms baseline was itself a first-run-after-idle
measurement, so the honest comparison is 24,696 → 7,597–8,136 warm-page-cache, 14,028 cold. The −71%
claim rests on phases (`cache_write` 9,827 → 1,365; `workspace_artifacts` 7,018 → not reached), which
do not move with the page cache. **`RPR-FINAL` must build its gates from growth ratios and phase
values, not wall times.**

**The language server is profiled, and its largest single cost is a floor.** It needed no phases of
its own — every answer is `ExactRun.streamSnapshot` over one document, so the existing schema covers a
request end to end. Over `tests/lsp/acceptance.sh`'s 165 requests: `exact_child` 282 ms mean,
`child_analyze` 181 ms, and **`exact_setup` 105 ms — 27% of request latency, a full Lake no-build
traversal on every keystroke-driven request.** `primeSetups` cannot help; a request has one document.

Caching it across a session is unsound, and the split says why: `nobuild_context` is **0 ms** and
`nobuild_fetch` is **104 ms**, so none of the cost is context construction and all of it is the fetch
— and the fetch *is* the currency check, reading the artifacts on disk now. A cached setup would
elaborate against artifacts a `lake build` in another terminal has already replaced.

**Named for whoever takes it:** removing this needs a cheaper currency *signal*, not a cache — a watch
on the build directory that invalidates a session's setups. That is a design change with its own
correctness surface, not an optimization, and it is out of scope here.

**A profile-channel defect, found by using it.** `noBuildValue?` redirects stdout and stderr into its
own buffer for its whole duration, so a `withPhase` bracketed inside it emits into that buffer and is
discarded. The first attempt at the split above measured nothing and looked like zero cost. The two
sub-phases are timed with `IO.monoNanosNow` and reported in the `finally` after the streams are
restored.

**A phase measured nothing, and finding that out corrected two records.**
`withPhase "positions" <| pure (resolvePositions ..)` evaluates its argument before the bracket is
entered — Lean is strict — so `phase.positions_ms` read **0 ms on every workload in this stack** while
timing an already-computed value. A plain `let` inside a `do` does not fix it either; the compiler
floats a pure computation out of the action's closure. `IO.lazyPure` does. **Every `positions_ms`
figure recorded before this is void**, and `child_encode` — recorded in `notes/02-instrumentation.md`
as "0 ms" and used to retire the JSON-serialization suspicion — actually reads 17 ms across 8 files,
about 2 ms each. That suspicion stays retired; the number it rested on did not.

**`ruff-15`'s handoff is discharged, and its guess was right where my reading of the code was wrong.**
`experiments/run-positions-bench.sh` generates four shapes into the excluded `tests/reporting/` tree.
At 4 MB: `early` 4 ms, `late` 30 ms, `many` 43 ms, `oneline` 28 ms — **7.5× between a finding at the
start and one at the end of the same file**. I had reasoned from `positionsOf` being one linear pass
that position could not matter; it matters because the pass *stops at the last offset it needs*. The
`early` row is the floor paid by any file with a finding: `normalize` plus `toUTF8` over the whole
source. At 16 MB: 12 / 105 / 178 / 212 ms, so `oneline` is 2× `late` there and 1× at smaller sizes —
one sample, flagged rather than explained.

**The two revisits `roadmap.md` inherits are settled, and neither became work.** `ruff-10b`'s
Design B named its own trigger — a syntax rule graduating to default — and every syntax-tier rule
(FMT009–FMT014) is still `defaultEnabled := false, lifecycle := .preview`; the integrated-workload
measurement shows the default `check` recording `official_artifacts` = 0 ms and never entering the
syntax path, so there is nothing for Design B to be cheaper than. `ruff-01`'s node-table granularity
question rested on "read by nothing but the probe differential", and that premise is refuted by code
written after it: `LeanFmt/Printer.lean` walks the table end to end and follows `parent` to arbitrary
ancestors, and all six syntax rules index it. `Node` is three fields and the printer reads all three.
The one remaining lever — pruning to the 33 kinds the printer dispatches on — is refused because a
kind-pruned artifact encodes formatter implementation knowledge and would make a printer edit
invalidate every integrated module's Lake trace, which is the exact coupling this project already
removed once.

**Still open in this prompt.** Only the two-session concurrency test, which the work order puts
after all single-session work. Watch mode needs no separate profiling: a generation runs the same
`execute` path the batch modes do, and `render_report` already brackets its per-generation rendering.

**The `formatter-integrated-built` workload is closed** (`evidence/01-workloads.md` §3.1,
`results/02-optimize.md`). Four modules built with `LeanFmtCompilerPlugin`, and a syntax-tier
selection is the only command that reaches the artifact path — `check` demands nothing above source
and `format --check` skips the facet for the frontend. On that command the integrated build reads
`official_artifacts` = **105 ms with no `exact_child` at all**, against **3,283 ms of four frontend
children** for the same rule on ordinary-built modules. First measurement of the plugin's reason to
exist in this project. It also exposed that `official_artifacts` costs 101 ms on a workspace that
cannot have an artifact; recorded, not fixed, with the reason in the result.

**`tests/cache/run.sh` is verified, and the environmental diagnosis held a second time.** It had
been killed by the OS (`Killed: 9`, exit 137) at varying lines across roughly six attempts while
another session held a 3.9 GiB Python process at load average 13, and it passed clean on the next
attempt at load 8.7 with no change to the cache path in between. Throughout, the same `lean-fmt
check` on the same fixture project passed standalone at **697 MB peak RSS**, inside the recorded
441–864 MiB envelope. Twice now this signature has been OS memory reclamation and not a defect;
the rule that follows is to re-run before diagnosing, not to grow the envelope.

**The unverified check is now verified, and the environmental diagnosis held.** `tests/cache/run.sh`
had been killed by the OS (`Killed: 9`, exit 137) at three different points across four attempts while
the machine sat at 8.7 GiB of 10 GiB swap with another session's `lean` holding 1.9 GiB. It passes,
as do all twenty suites, `lake lint`, and `lean-fmt-tests`.

**One measurement was discarded rather than reported.** The `self` `format --check` cold run taken
after the fix read 97,434 ms against a 43,506 ms baseline, at load average 25 with five other `lean`
processes holding 1.3–1.6 GiB each. It is elaboration-bound (`child_analyze` 79 s of it) and the
change is a no-op on `self` by construction — `write_closures` there is 46 ms — so the note says that
instead of re-measuring under load.
Every profiled run reported a swap delta of 0 and peak RSS ≤ 0.85 GiB, so no measurement in this stack
breached the envelope.

## What `01-baseline` froze, and the one thing it found

`evidence/01-workloads.md` holds environment, five workloads, build/cache states, baselines, six
gates, and the measurement practice. `notes/01-phase-schema.md` holds the profile channel's schema.
The finding that shaped both:

- **The phase schema explains fast runs and says nothing about slow ones.** Accounted fraction —
  emitted `phase.*` values against wall time — is 97.3% on `mathlib-sample` warm and **0.9%** on `self`
  `format --check` cold (43,506 ms). Every cold run's missing time sits in one unbracketed region,
  `withExactRun` and the per-snapshot loop (`Application.lean:1431-1468`), which holds the exact
  frontend, every rule tier above import, layout, validation, and cache writes.
- So the schema is a specification with a test, not a list: thirteen names are assigned to sites that
  exist today, and **G3 requires the accounted fraction to reach 90% on every frozen workload**.
  `RPR-IMPL` closes G3 before optimizing anything cold — until then there is nothing to attribute a
  win to.
- **Warm on a large project is `cache_lookup`**: 8,187–8,994 ms of 10,863–11,706 with 62/62 entries
  already served. `ruff-16b`'s inherited result, reproduced. Serving more entries cannot help.
- **The envelope has 9.7× headroom.** Worst peak aggregate RSS 864,032 KiB = 0.82 GiB; zero swap;
  pressure never left 1.
- **"~61.7 MiB" in the completion contract is the isolated printer's envelope, not the
  application's.** Re-measured at 64.6 MiB (source grew 7.5%, toolchain moved). The application's peak
  is 441–864 MiB. Do not merge them.
- Two open items are carried, not closed: no workload is in the `formatter-integrated-built` state,
  and the adversarial `PositionIndex`-build fixture `ruff-15` asked for does not exist, because the
  phase that would measure it does not exist either. Both are `RPR-IMPL`'s.

## Inherited from `ruff-15-reporting` (verified)

The completion contract names **rendering** as a profiled phase. `ruff-15` produced its baseline, and
one result changes what to profile:

- **Rendering is linear in report size across three decades and is not a scale risk.** 100 / 1,000 /
  10,000 / 100,000 findings through all six formats; 10× the report costs ~10× the milliseconds in
  every one, `Lean.Json.pretty` over a 50 MB SARIF log included
  (`ruff-15/evidence/03-report-scale.md`, driver `lake exe lean-fmt-tests report-bench`).
- **The cost is the position index, not the serializers.** At 100,000 findings, position-free `text`
  renders 33× faster than `concise` *while emitting more bytes* (7.82 MB against 6.95 MB), and `json`
  serializes 14 MB with no lookups faster than `concise` serializes 7 MB with 200,000 of them. If this
  stack profiles rendering, the two `PositionIndex` lookups per finding are the line item — the
  serializer is not where the time is, which is the opposite of what `RRF-IMPL` assumed.
- **What the benchmark does not cover, and this stack could.** The fixture's lines are uniform, so it
  exercises index *lookup* but not index *build* on a pathological source (one enormous line, findings
  clustered at the end of a very large file). The build is one forward pass, O(source bytes) by
  construction, and is unmeasured.

## Inherited from `ruff-16-watch-incremental` (verified)

> **[REFUTED by `ruff-16b-cache-identity` `RCI-SPEC`, 2026-07-20. The in-process framing below is
> wrong; do not act on it.]** There is no in-process cache-reuse defect. `execute` opens a fresh
> `ResultCache` per call (`Application.lean:1298`) and `loadedEntries` is created inside `open?`
> (`Cache.lean:267`), so nothing is retained between calls to go stale. The compared numbers were
> different workloads: cold-after-edit against an unchanged tree.
>
> The confirmed defect is whole-project cache-key invalidation, and it is **process-independent**.
> `Cache.environmentDigest?` folds every project source's bytes into `environment`, which feeds
> `baseDigest`, which names the index file — so one edit renames the index and orphans every entry,
> in a fresh process just as much as a reused one. Reproduced at entry granularity: after appending
> one comment to one file, **0 of 112 entries hit**, not 111
> (`ruff-16b-cache-identity/results/01-contract.md`). The 135× figure below is real; its
> attribution is not.

- **`execute` does not reuse the result cache when called twice in one process.** Measured
  (`ruff-16/results/02-implementation.md`, decision 3): a second in-process `execute` after a
  one-file edit took **~70 s** — the full cold-cache price — where a *separate* process handling the
  identical edit took **0.52 s**. A 135× penalty. `ruff-16` routed around it by making every watch
  generation a fresh child process; nothing fixes it, and the root cause was not investigated because
  it lives in `Cache`/`Application`.

  **This stack owns it, per the completion-contract bullet added for it** — `ruff-16` recorded the
  measurement but never diagnosed the cause, so "affects any caller that runs `execute` more than once
  per process" is an inference from one measurement, not an established fact. Diagnose before
  optimizing: a cache that misses when it should hit is a correctness bug wearing a performance
  costume. If it is fixed, the contract also asks whether watch's re-exec workaround comes out.

> **Discharged by `ruff-16b-cache-identity` (2026-07-20).** Both halves are answered; this is no longer
> `ruff-19`'s to own.
>
> The inference was wrong — `execute` opens a fresh `ResultCache` per call and retains nothing, so
> there is no per-process penalty for any caller. The real defect was one layer down: `environment`
> folded every project source into the index *filename*. It is fixed, keyed per entry on the import
> closure's build artifacts (`RCI-IMPL`). "A correctness bug wearing a performance costume" was the
> right instinct and the right words for it.
>
> **The re-exec workaround stays**, decided on measurement rather than inherited justification
> (`RCI-FINAL` §4): spawning is 24 ms of a 490 ms warm generation, the ~400 ms fixed cost is workspace
> load and epoch computation that an in-process generation also pays, and retaining the workspace to
> avoid it would reintroduce exactly the staleness `RCI-IMPL` removed. Parent RSS is now flat at
> 51,488 KiB across 15 generations — better than the 16 KiB growth recorded below, which was measured
> before this stack.

- **Watch's own costs are measured and small.** The poll walk is 34 ms and per-generation fixed cost is
  ~400 ms (`workspace_load` 301–344 ms + `discovery` + `cache_epoch`), independent of file count;
  1 file → 110 files adds ~70 ms warm. Watch parent RSS grew **16 KiB over 13 generations**. If the
  discovery walk approaches generation cost on the frozen mathlib sample, `ruff-16` `notes` §1's
  rejection of an event-driven watcher (Lean binds no `uv_fs_event`) should be reopened rather than
  worked around.

## Inherited from `ruff-16b-cache-identity` (verified)

Measured in `RCI-FINAL` (`results/04-acceptance.md` §2), on the frozen mathlib sample. Design input
for this stack rather than trivia to rediscover:

- **On a large project, warm is bounded by fixed per-run cost, not by cache hits.** 62 / 62 entries
  served and the run still takes 6.3 s: discovery over 8,795 files, workspace load, epoch computation,
  and closure digests for closures thousands of members deep do not shrink when entries hit. Warm is
  2.3× cold there, against ~100× on a small fixture. Any speedup target for the cached path has to
  name which of those it attacks; serving more entries cannot help.
- **Two eager-work defects were found and fixed by measuring that, and the pattern is worth
  suspecting again.** The conservative whole-workspace fallback was computed on every run (~10 s on
  mathlib) for a value nothing reads when every closure resolves, and `importAllArts` was recomputed
  per (module, closure member) pair across closures that overlap almost entirely. Both were invisible
  on the fixture and neither showed up as a wrong answer.
- **Wall time on this workload is strongly page-cache sensitive.** The first warm run after a rebuild
  measured 10.9 s inside `closureDigests` where the steady-state run measures 3.6 s, reading the same
  4,125 trace files. `index_hits` does not move between them. This is the same confound that produced
  the original `ruff-16` misreading; a wall-time-only comparison here is not evidence.
- **There is no diagnostic that says the cache is disabled, or why.** `ResultCache.open?` returning
  `none` is a supported outcome and reports nothing, so a project running with the cache entirely off
  is externally indistinguishable from one running cold. `RCI-FINAL` found exactly that on mathlib —
  zero entries ever written, caused by one absent search-path directory — and fixed that one cause
  while leaving the class open: any `IO.FS.realPath` or trace-validation failure inside `open?`'s
  catch-all still disables the cache silently. Observability for this belongs to this stack.

## Inherited from `ruff-17-lsp` (verified)

Handed here because this stack's work order opens `LeanFmt/LanguageServer.lean` anyway — RPR-IMPL
profiles LSP latency, and the completion contract owns the aggregate envelope these sit inside.

- **One unbounded collection survives a session, and this stack owns closing it.** `Session.cancelled`
  is a `Std.HashSet RequestID` that `serveCancellable` erases from after every request it brackets —
  which covers every id the server actually serves. A `$/cancelRequest` naming an id the server never
  sees (a stray, a cancelled notification, a client bug) is recorded and never removed. It is a few
  dozen bytes per stray message and no mainstream client emits one, so it is not a defect anyone will
  hit; it is the one entry in `notes/01-protocol.md` §13's bounded-resource list that `ruff-17` left
  without an actual bound. The hundred-request stability run cannot see it, because that run sends no
  stray cancellations (`ruff-17-lsp/results/04-acceptance.md`). Close it by bounding or expiring the
  set, not by asserting clients behave.
- **Debounce is a default nobody measured.** 150 ms, chosen in `RLP-FEATURES` and never validated
  against real editing; `tests/lsp/run.sh` drives it at 1 ms and 80 ms only to make timing
  deterministic. `notes/01-protocol.md` §14 explicitly declines to decide the value and §12 assigns
  the duplicated-elaboration cost of two servers on one document here. The two are one measurement:
  what a keystroke costs decides what the quiet interval should be.
- **A measured floor for that work.** Formatting `LeanFmt/Application.lean` (1,700 lines) as an unsaved
  buffer costs 3,637 ms end to end, and in-flight cancellation returns in 470 ms with the child killed
  at `monitorChild`'s 50 ms poll. Session subtree RSS was flat across 100 requests: 682,880 KiB after
  the first, 690,640 KiB peak, 685,840 KiB after the hundredth (Darwin arm64, `v4.33.0-rc1`, commit
  `b37846e`). Sampled from `ps` over the server *and its descendants*, because the exact frontend child
  is the server's child.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
