# Evidence: final performance audit (Prompt 26, `LFF-FINAL-PERF`)

Date: 2026-07-25. lean-fmt `db5da78` (post-repair), toolchain `leanprover/lean4:v4.33.0-rc1`, mathlib4
`3de5ed81cc71b9ea62597b865ba0baaeb5eb0ea9` (untouched; only `?? .lean-fmt-cache/` untracked).
Machine: Darwin 25.5.0 arm64 (Mac, 24 GiB), per-run identity in each `experiments/results/26-*.meta`.
Guard: 8 GiB aggregate RSS, 256 MiB new swap, pressure level 1 — `hard_stop=none` on every completed
run below. One run was stopped by the guard (`26-heavy4-before-7g`, `hard_stop=pressure`, another
session's 8.25 GiB worker) and its question was already answered by 24's identical measurement; one
run was stopped at start (`26-self-cold-20260725T141648Z`, pressure level 2) and re-run quiet. Wall
times are evidence, never gates; the durable gates are the counts, ratios, and digests in
`tests/performance/run.sh`, `tests/check/run.sh`, and `tests/compiler/run.sh`.

## The two repairs, measured before and after

### R1 — the child is budgeted its honest headroom (`--max-memory` double count, 24's hand-off)

Before (`08759eb`): the child was told it could use the whole envelope
(`Lean.Internal.setMaxMemory maxBytes`) while the parent tripped on parent RSS + child process-group
RSS against the same envelope (`monitorChild`). After (`db5da78`): the child is budgeted the
envelope minus the parent's current RSS (`childMemoryBudget`); the aggregate trip is unchanged.

Workload: the frozen heavy four — `Mathlib.lean`, `MathlibTest/ImportAll.lean`,
`MathlibTest/LibrarySearch/mathlib.lean`, `MathlibTest/Tactic/Grind/Field.lean` (manifest
`/tmp/lff26/heavy4.txt`, source digest `8b0725b4…`, four of 24's twelve), `format --check --json
--no-cache`, cache-cold, ordinary-project-built.

| run | envelope | outcome | trip readings (KiB vs bound) | wall | peak RSS | swap Δ |
| --- | --- | --- | --- | --- | --- | --- |
| before | 6 GiB | 4/4 parent trip | 6,293,664–6,372,640 vs 6,291,456 | 236.9 s | 6,317,024 KiB | −41,154 KiB |
| after | 6 GiB | 3 parent trip, **1 child `memory_exception`** | 6,315,136–6,372,128 vs 6,291,456 | 218.3 s | 6,340,336 KiB | −8,192 KiB |
| after | 7 GiB | 4/4 parent trip | 7,376,816–7,495,744 vs 7,340,032 | 179.1 s | 7,362,976 KiB | −16,384 KiB |

What the repair changed: the accounting is honest — the child's hard cap is now exactly the
headroom the parent grants, and `MathlibTest/Tactic/Grind/Field.lean` at 6 GiB now fails by its
**own** attributed `memory_exception` (Lean's `LEAN_MAX_MEMORY` failure mode) instead of the
parent's kill. What it did not change, and what 24 could not distinguish: these modules' binding
resource is RSS, and Lean's allocator retains ~0.4–0.5 GiB beyond the `setMaxMemory` allocation cap
at these sizes, so aggregate RSS lands ~0.5 GiB above the envelope at every envelope tried. The
trip point tracked the bound because the files' true RSS demand is just above each bound, not
because the accounting alone misplaced it. **The twelve are genuinely beyond the 8 GiB audit
envelope at any accounting**; admitting them takes `--max-memory` above the experiment stop rule,
which this stack does not run. That closes 24's parked question as measured, not hypothesized.

Gate: `tests/check/run.sh` — a recording fake analyzer asserts the budget argument is positive and
strictly below the envelope; proven to reject the old value (8,589,934,592).

### R2 — a never-built facet misses alone, not the whole batch

Before: one selected module whose `leanFmtArtifact` facet had never been built failed the whole
no-build traversal. Measured at `08759eb`: `diff --no-cache tests/compiler/ArtifactLayout.lean
Main.lean` reported `official_artifact_miss=2`, `path_exact_render=1` twice — the integrated
fixture lost its artifact route because an unrelated module had no sidecar. A consuming project
integrates the plugin on one library, not every one, so the artifact acceleration silently
disabled in exactly the configuration it was built for. Control measurements: with Main's facet
built once (even to `null`), the same selection degraded per module (`hit=1/miss=1`); a mixed
selection with a non-module file degraded per module all along.

After: `officialArtifacts` excludes modules whose sidecar and trace do not exist — a certain miss,
since `readFacet?` reads that very file — before the traversal. The same selection now reports
`official_artifact_hit=1, official_artifact_miss=1`, `path_artifact_render=1` (fixture),
`path_exact_render=1` (Main). Gate: `tests/compiler/run.sh` deletes Main's sidecar set and asserts
the split. The pre-filter duplicates the lakefile's `artifactFile` convention by construction; the
gate is what notices if the two drift.

Side effect for non-integrated projects: on the 40-file self workload the artifact phase is now
`official_artifacts_ms=105` of context construction over zero eligible modules (all 40 miss without
a traversal per module).

## The workload battery

Counts and digests are the comparable quantities; wall/RSS are this machine, this day.

| workload | operations | digest / ratio | wall | peak RSS | run |
| --- | --- | --- | --- | --- | --- |
| module builds | full build 64 jobs; focused `Formatter`/`Validator`/`Analysis` 16 jobs (16 measured 21 pre-deletion) | — | — | — | `lake build` |
| renderer-only | 8 adversarial rows, `steps = nodes + marks` exactly (n=1000 and n=8000) | linear | — | — | `lean-fmt-tests doc-step-counts` |
| self cold check, 40 files | 0 exact children (source-tier default; module evidence) | empty-report `e3b0c442…b855` | 25.9 s | 1,492,800 KiB | `26-self-cold-20260725T145458Z` |
| self exact format, 40 files | 40 exact children, 35 renders, 5 known refusals; `official_artifact_miss=40` | `b047b3c3…cfa4` | 100.8 s | 3,384,032 KiB | `26-self-exact-20260725T145700Z` |
| self warm check | 40 targets = 40 index hits = 40 served, **0 children, 0 setups** | same empty-report digest as cold | 0.68 s | 592,992 KiB | `26-self-warm-20260725T150014Z` |
| mathlib exact, heavy four | 4 exact children, envelope outcomes above | `61489977…` / `b0b3d4ee…` / `1bedf61d…` | 179–237 s | ≤7.2 GiB | `26-heavy4-*` |
| artifact route, fixture | 1 artifact child, **0 exact children**, `path_artifact_render=1` | `fef86149…63e5` | 1.33 s | 1,313,184 KiB | `26-artifact-route-…150039Z` |
| exact route, same fixture | 1 exact child, `path_exact_render=1` | **same digest** `fef86149…63e5` | 1.33 s | 893,744 KiB | `26-exact-route-…150041Z` |
| mixed selection | post-repair per-module split: artifact 1, exact 1 | counts gated in `tests/compiler` | — | — | above |
| stdin whole vs range | **1 exact child each**; range is not cheaper, by design | full-range output ≡ whole output `4a04c304…` | 2.1 s / 1.7 s child | — | `format - --stdin-filename` on `LeanFmt/Edit.lean`, `--range-lines 40:1-60:1` widened to bytes 1488–2286 |
| LSP first request / cancellation | cancelled request returned in 4,427 ms of an uncancelled 12,144 ms | fraction, gated | — | — | `tests/lsp/acceptance.sh` |
| LSP hundred-request memory | first 1,525,712 KiB → peak 1,530,288 → last 1,530,288 | **0.3% growth**, gated | — | — | `tests/lsp/acceptance.sh` |
| incremental edits | updates=115, **reused=451**, invalidated=4, failed=1, cancelled=1, retained=1 | tail/middle/comment edits reuse; start/syntax/header/setup invalidate | — | rss_kib 3,702,224 → 3,627,888 (flat) | `tests/incremental/run.sh` |

The five self-manifest refusals are the pre-existing own-source set, unchanged by this prompt:
`LeanFmt.lean` (comments gate), `LeanFmt/Cli.lean`, `LeanFmt/SyntaxArtifact.lean`,
`LeanFmtTest.lean`, `tests/lsp/Acceptance.lean` (D4-family guarded bail-outs). `format --check`
exits 2 on them, which is the loud-refusal contract, not a regression.

## Phase dominance, compared with Prompt 16

Self exact format, 40 files: `exact_child` 96,176 ms of 100,796 ms wall (**95.4%**), `child_analyze`
92,035 ms (**91.3%**), `child_encode` 127 ms, `envelope_decode` 54 ms, `workspace_load` 346 ms,
`official_artifacts` 105 ms, renderer/report below counter resolution. Prompt 16 measured 96.6% /
92.9% on 45 files with the handwritten grammar. The native-layout adapter did not move the shape:
cold exact formatting is the frontend, as it was at mid-stack, and the adapter's own cost is inside
`child_analyze`, invisible at the millisecond counter next to elaboration. Prompt 16's numeric
expectations still hold: two renders per admitted candidate (gated §0c), one setup and one child
per exact target, zero on an all-hit run (gated §1), fewer frontend operations on the artifact
route (gated §1e, and now on mixed selections), nonzero reuse on eligible incremental edits
(gated by `tests/incremental`).

## Copies, lifetimes, probes, child counts (code audit, `db5da78`)

- **Child counts.** Every child spawn goes through `runBounded`, which records
  `cache.active_children=1`; batch execution is serial (22's measured decision). The LSP spawns no
  per-request child: one in-process `IncrementalAnalyzer` per open document, `retainedSnapshots ==
  1`, recreated at most once after an infrastructure failure, cancelled into the snapshot tree.
- **Environment lifetimes.** A child's Lean environment dies with the child; the parent retains
  source snapshots, decoded envelopes, and cacheable results only. The LSP retains one
  `DocumentEnvelope` per open document (erased on `didClose`) and one setup per document *header*
  (`documentSetups`, keyed by imports, not buffer bytes, so ordinary edits do not rebuild Lake's
  setup graph per keystroke).
- **Source/syntax copies.** The exact child reads the snapshot from a temporary file, projects it,
  and returns one JSON envelope; no second source copy is held in the parent beyond the snapshot it
  already owns. Batch `format` retains each changed file's canonical text in `pendingFormats` —
  required for atomic all-or-nothing publication, bounded by the batch size.
- **Cache probes.** One environment-scoped index, one probe per run, per-entry digests; an all-hit
  run performs zero frontend or setup work (gated §1). Rule selection is not in the probe's key.

## Checks

`lake build` (64 jobs), `lake exe lean-fmt-tests`, `lake lint` (63 files, 0 findings),
`tests/performance/run.sh` (including §0's 24 negative cases and the §2 remainder gate: 53 ms of
536 ms quiet), `tests/check`, `tests/cache`, `tests/compiler` (new mixed gate), `tests/modes`,
`tests/stream`, `tests/lsp`, `tests/validator`, `tests/incremental`, `tests/lsp/acceptance.sh`,
`tests/ci/run.sh` (against committed `db5da78`), and `git diff --check`. All green.
