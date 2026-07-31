# Plan: a persistent result cache — preserve everything with a consumer, store nothing without one

## Context

Goal (user, refined): not comprehensive updates on every run. A common subset that persists across invocations, built on
rather than destroyed, skipping as much redundant work as possible. Storage discipline: **the required minimum — every
stored artifact names a current consumer; nothing is stored because it is convenient or might be useful later.** No size
cap: storage is bounded by what has a consumer, and dead entries (no consumer) are pruned.

Three things destroy cache value between runs today, in increasing order of daily cost:

1. **The cone invalidation (the redundant work).** An entry's currency includes a `closureDigest`: a fold over its
   import closure's recomputed `importAllArts` — hashes of each member's *build artifacts* (`Cache.lean:354-374`). Any
   rebuild of any member M — including a **proof-only edit** — changes M's olean, so every module whose closure contains
   M misses and re-elaborates. Edit a hub file's proof and its entire reverse cone (hundreds of files, ~4s each) re-runs
   the frontend, although their findings and layout are bit-identical unless M's *elaboration-visible interface*
   changed.
2. **The overwrite regression.** `writeAll` (`Cache.lean:826`) does a bare `entries.insert` at a mode-free identity key:
   a `check` after a `format` overwrites the canonical-bearing entry with a canonical-less one, so the next `format`
   re-renders everything. Runs don't just fail to preserve — one actively destroys another's work.
3. **organize is uncached.** Every validation is a fresh frontend child, every run — even for a candidate it rejected
   minutes ago — and the child keeps only pass/fail (capture `"0"`), discarding an elaboration the next `check`/`format`
   re-runs on exactly the bytes just published.

What already works and stays: one epoch per workspace (toolchain, dependency artifacts, formatter binary,
configuration), one entry per module, selection-independent entries (rule selection is not in the identity), the accept
decision proved sound and complete in `Cache/Spec.lean`, and degradation always toward a miss.

**Non-goals (per the refined goal):** no run pays for another mode's product — `check` never renders canonical, organize
never renders canonical inside validation (the dropped "canonical harvest": speculative work whose consumer might never
arrive before the next edit); `organize --check` stays pure; FMT004 import findings stay fresh-computed (their currency
reads other files — a separate problem).

## The persistence model

One entry per key carries *capabilities* — findings at a tier/caps, canonical layout when rendered, an elaboration
verdict when validated. Runs only ever **add** capabilities; acceptance (`Decision.serves`) is unchanged and proved. A
stored artifact exists exactly when a named consumer can read it:

| Stored artifact | Consumer | Produced by |
| --- | --- | --- |
| findings analysis (tier/caps) | `check`, `fix` | any batch run |
| canonical layout | `format`, `diff` | runs that already rendered |
| verdict: candidate elaborated | organize probe | organize validation (published) |
| verdict + rejection diagnostics: candidate broken | organize probe and its report | organize validation (rejected) |

## Design

### 1. Monotonic merge on write (`Cache.lean`)

`writeAll` merges instead of replaces. Two entries at one identity key describe the same bytes under the same
environment and configuration, so their capabilities compose (higher tier/caps is a superset computation; canonical is a
deterministic function of source + format config):

- old broken / new success → keep the new (under one identity, both existing implies resource flakiness; success is the
  informative, still-sound direction);
- old success / new broken → keep the old;
- both success → `success (max tier) (caps ∪ caps) (hasCanonical || hasCanonical)`; stored analysis is the
  higher-tier/caps one, `canonical?` grafted from the other when absent.

The fourth outcome class, `unbuilt` (v0.1.9: the frontend could not open a dependency's olean), carries no information
about the bytes at all, and the merge says so twice over. It is never stored: a stored unbuilt entry would poison every
later probe with a non-verdict. On the read side of the merge this makes the cases exhaustive — old success / new
unbuilt keeps the old by not writing; old unbuilt cannot exist in the store.

Accept path untouched; the merge is a *write-side* invariant (per key, `provided` monotone over time), stated as a
comment and pinned by unit tests. `Spec.lean` quantifies over the read decision and does not change — say so explicitly.

### 2. organize joins the cache: probe, validate, store — at minimum storage

A validation verdict is an ordinary cache entry about the candidate's bytes. The candidate is already a `SourceTarget`
(`snapshot.withSource output`); the reorder does not change the import closure, so its closure digest is the module's
own. One store, one schema, one epoch discipline, one proven currency check — and nothing speculative stored:

- **Probe before dispatching to the worker pool** (validation runs over `--workers` since `22ec943`; the probe is what
  makes the pool idle) for a current entry whose source digest is the candidate's: success → "elaborates", skip; broken
  → "rejected", skip (its stored diagnostics *are* the report, so no information is lost); absent → validate. The
  verdicts come back on the batch-child *envelope* (`runAnalyzeChild`'s out/err transport), not the exit code; stores
  collect from worker results. One status class is deliberately absent from the probe's verdicts: `unbuilt` (missing
  dependency oleans) says nothing about whether the candidate elaborates, so it means *validate again*, never rejection
  — and per piece 1 it is never in the store to be probed. The predicate is not `Decision.serves` — it asks "did these
  bytes elaborate," and a broken entry (which meets any lint demand) means *rejection* here — so add it beside `serves`
  in `Decision.lean`, reusing the proven `identityCurrent` half, and prove it in `Spec.lean` (small; same quantifiers).
  One home for both decisions so they cannot drift.
- **Store after validation.** Published candidates: the full analysis entry — it is the file's new *live* entry,
  consumed by the next `check`/`format`/organize-probe (see the harvest measurement below). Rejected candidates: the
  broken entry — tiny (no findings, no canonical; diagnostics are the rejection report), consumed by the next probe and
  the report it reproduces. Nothing else: no canonical for unpublished bytes, no duplicate verdict records, no sidecar.
- **Harvest (measured, default decided by the number).** The validation child runs capture `"0"` today. Running it at
  the findings tier stores an analysis the next `check` consumes — one elaboration serving two commands. Price:
  diagnostics capture inside every validation child, paid *per worker* — if capture inflates child time, the harvest
  silently eats the parallelization win. Measure capture-tier-vs-`"0"` child time on a 10-file mathlib-closure batch; if
  the ratio is near 1 the harvest is default-on (the default belongs inside the module), if not, validation stays `"0"`
  and only the verdict bit is stored (a published file's next `check` then re-runs once — the honest price of keeping
  organize fast). Record the number either way.
- **`--no-cache` for organize** (parser + help + drift-test pin, wired through the workers config struct), for symmetry
  and for debugging the cache itself.

### 3. Live-set pruning on write (`Cache.lean`)

Not a cap — the minimum-storage rule applied to what already accumulated. An entry has a consumer exactly when its
source digest is (a) a current project target's, or (b) a current *organize candidate* digest of a current target
(recomputable purely — `Imports.organize` needs no frontend). On `writeAll`, drop everything else: deleted files,
superseded candidates, headers edited away from a rejection. A rejected header still on disk recomputes to the same
candidate digest, so its verdict survives — the rule deletes only what no run can ask for again. Cost: one digest walk
per write, no frontend. Add a `cache_entries_pruned` counter and report `cache_bytes` under `--statistics` for
observability — no threshold, no eviction policy beyond "no consumer."

### 4. (Staged, opt-in first) closure currency at interface granularity

The lever for the cone invalidation, and the only piece with a real soundness surface. Today's key is artifact identity:
any rebuild moves it. The analysis of B actually depends on (i) B's bytes, (ii) the grammar the closure exports, (iii)
the environment B elaborates against. A rebuild of M that changes none of M's elaboration-visible interface cannot
change any downstream analysis.

The compiler plugin already hooks every successfully elaborated module (`LeanFmtCompilerPlugin`) and writes the
`leanFmtArtifact` sidecar. Extend it to also write an **interface hash**: exported syntax/notation/macros, declaration
names, kinds, types, universe levels, instance priorities, reducibility, and the bodies of definitions visible at
reducible transparency. `closureDigest` then folds interface hashes instead of `importAllArts`; proof-only rebuilds stop
moving it.

The documented hole: downstream defeq can in principle unfold a theorem's proof term (kernel `isDefEq` unfolds any
definition), so a proof-body change is downstream-visible in pathological cases. Today's artifact key prices that risk
at zero and the redundancy at 100%. The premise is test-pinned: `testLakeTraceCharacterization` (unit tier)
characterizes the `importAllArts` behavior the cone invalidation rests on, and trips if Lake changes the trace shape
under the design. The redundancy has been observed live: editing one lean-fmt module stale-traced the entire suite
cone's traces, one rebuild cascade per edit. Rollout:

- opt-in: `[cache] closure = "interface"` (default `"artifacts"`, today's behavior);
- evidence run on kan-proofs: cone miss count after a proof-only edit to a hub module (expect: cone-size with artifacts,
  ~0 with interface) and a staleness hunt — force the hole (edit a proof body whose term a downstream `rfl`/`decide`
  reduces through), confirm the miss or record the hit honestly;
- flip the default only on that evidence; the kill switch stays.
- `Spec.lean` is generic in `GDigest`, so the proof's *form* survives — but the meaning of the digest changes, and the
  implication "interface identity ⇒ analysis identity" is an assumption, not a theorem. State it in the Spec commentary;
  do not claim it proved.

## Module-design review

1. Surface: one new predicate in `Decision.lean`, a merge and a prune in `Cache.lean`, one config key (piece 4), one
   flag. No new module, schema, or cache file.
2. Independent concerns stay apart: probing is organize's, merging/pruning the cache's, interface hashing the plugin's.
3. Storage minimum is enforced structurally: the live set is *defined by consumers* (targets + their candidates), not by
   a size policy — nothing exists to tune.
4. Callers get simpler: organize stops special-casing "have I seen these bytes"; check and format stop losing each
   other's work.
5. No new error paths: probe-absent and prune fall to existing paths.
6. Each piece ships behind its own evidence; piece 4's default flip is gated on the staleness hunt, not enthusiasm.

## Performance method (lean-performance + repo rules)

Measure first; gates are **counts, ratios, digests — never wall time** (repo AGENTS: the same warm corpus measured 3,977
ms vs 19,968 ms under load). The profile channel already counts children and phases (`active_children`,
`cache_epoch_ms`, `exact_child`).

Baselines recorded *before* changing code, then gated in `suite-performance`:

| Measurement | Today | After |
| --- | --- | --- |
| `format` → `check` → `format` (children) | 0 / 0 / 0 — measured 2026-07-30 on kan-proofs (3-file mathlib-closure batch): the bare insert cannot overwrite an entry a run never recomputes, and today's demands align so `check`/`fix` are *served* by `format`'s entries. The regression is structural, and goes live exactly when piece 2 stores capture-"0" analyses — the merge is piece 2's precondition, not a response to an observed loss | 0 / 0 / 0 (merge unit tests + piece-2 store path) |
| proof-only hub edit, then `check` (children = cone misses) | cone size | cone size in artifacts mode, 0 in interface mode — measured 2026-07-30 (`suite-downstream`, `interface-closure-mode` case): proof-only edit to `Consumer.Basic` (`rfl` → `by decide` and back) costs `Dup` in artifacts mode and nothing in interface mode; A/B asserted as served +1 with byte-identity against `--no-cache` in both modes |
| `organize` → `organize`, rejected candidate (children) | 1 + 1 — measured 2026-07-30 (sabotaged import header; exit 1 both runs, one child each) | N + 0 |
| validation capture tier vs `"0"` (child-time ratio) | — | 8052/8158 ≈ 0.99 — measured 2026-07-30 (kan-proofs 8-file mathlib-closure batch, min of two runs, summed `exact_child_ms`): noise. **Harvest default-on**; a `--preview --select FMT012` check after organize is served (tier `.semantic`), with capture `"0"` it misses |
| organize `cache_epoch_ms` | not paid | 2324–2357 ms warm / 10064 ms cold on kan-proofs (piece-2 runs): the price of cache participation, paid once per run; still below one frontend child (~4 s) and amortized across every verdict hit |
| `cache_entries_pruned` / `cache_bytes` | — | reported |

## Files to modify

- `LeanFmt/Cache.lean` — `mergeEntry`; `writeAll` merge; live-set prune; probe-by-source digest; counters.
- `LeanFmt/Cache/Decision.lean` — elaboration-verdict predicate beside `serves`.
- `LeanFmt/Cache/Spec.lean` — proof for the new predicate; commentary on piece 4's assumption. `#print axioms` review
  after.
- `LeanFmt/Application.lean` — organize: open cache (unless `--no-cache`), probe before dispatching to the worker pool,
  store verdicts from the child envelope, measured-harvest capture.
- `LeanFmt/Cli.lean`, `LeanFmt/CliHelp.lean` — `--no-cache` for organize; help notes; drift-test pin.
- `LeanFmt/Config.lean`, `docs/configuration.md` — `[cache] closure` key (piece 4 only).
- `LeanFmt/ArtifactModel.lean`, `LeanFmt/ArtifactStore.lean` — the interface hash, computed in the facet extractor (the
  plugin dylib stays untouched) and carried by the sidecar (piece 4 only).
- `tests/` — unit tier: merge cases, prune cases; imports suite: reject-then-reorganize spawns no child,
  publish-then-check is warm; `suite-performance`: the gates above.
- `README.md` — cache paragraph names what persists and why.

## Reuse

- `Cache.Decision.Entry.identityCurrent` — the proven currency half the verdict reuses.
- `writeAll` / `loadEntries` / `closureDigests` — the store path organize joins.
- `snapshot.withSource`, `Imports.organize` — candidate construction and pure candidate digests for the live set.
- The compiler plugin's per-module record — where the interface hash rides.
- Profile counters for every measurement above.

## Steps

- [x] Record baselines (table) into this plan.
- [x] Piece 1: merge-on-write + unit tests + the `format→check→format` zero-children gate.
      `unbuilt` is never stored (merge cases stay exhaustive). (`7003d2a`)
- [x] Piece 2: verdict predicate + Spec proof; organize probe/store *on the `--workers`
      path (probe before dispatch, store from the child envelope); `--no-cache` through the
      workers config; harvest measurement priced per worker; imports-suite verdict tests.
      `unbuilt` probed as "validate again", never as rejection. (`1a90bcd`)
- [x] Piece 3: live-set prune + counters + prune unit tests. (`4451889`)
- [x] Piece 4: interface hash behind `[cache] closure = "interface"`; evidence run above.
      Shipped shape, refined during implementation: the hash is computed in the facet
      **extractor** (`moduleInterfaceHash?`, `LeanFmt/ArtifactStore.lean`) — the plugin dylib
      is untouched, so existing `.olean`s keep working; per-member fallback to artifact hashes
      for modules without a current sidecar (dependencies never build the facet); a sidecar
      older than its `.olean` is treated as absent (the facet is fetched on demand and can
      lag a rebuild); artifact schema v10 → v11. **Default stays `artifacts`** — the two
      documented gaps (kernel-unfoldable proof terms, attribute extension state) stand; the
      opt-in and kill switch are the mechanism.
- [x] Docs: README cache paragraph; `docs/configuration.md` `[cache]` section — landed once the
      other session's `import-layout` work in that file was committed and the file was clean
      (the deferred text below is what shipped, verbatim).
- [x] `lake build`, `lake lint`, unit tier 37/37; suites green per-suite (the full-lane run
      was perturbed by a concurrent session's suite execution against the shared fixtures).

### Deferred doc text for `docs/configuration.md`

In the example block, after the `[format]` keys:

```toml
[cache]
closure = "artifacts"                # or "interface" — see "Selection and the cache"
```

In "Cache and compiler integration", one paragraph: `closure = "interface"` keys each closure member by the
elaboration-visible interface its `leanFmtArtifact` sidecar records instead of its build artifacts, so proof-only
rebuilds stop invalidating dependents; members without a current sidecar (dependencies, or a facet that lags its
`.olean`) keep artifact-hash currency. The mode requires the integrating project to build the facet; its two documented
gaps — kernel-unfoldable proof terms and attribute extension state — are why it is opt-in.

## Verification

1. Suites green, including new gates; `per-command-help` updated for `--no-cache`.
2. kan-proofs sequences match the After column; prune leaves exactly the live set (digest comparison: index entries vs
   recomputed live digests).
3. `Cache/Spec.lean` builds; `#print axioms` shows no new assumptions.
4. Honesty check: a sabotaged candidate (header importing a nonexistent module) is rejected and its broken entry serves
   the re-run with the same diagnostics — no child spawned.
5. Piece 4: the staleness hunt is recorded in this plan, hit or miss.
