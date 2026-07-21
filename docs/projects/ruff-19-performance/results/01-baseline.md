---
claim_id: RPR-SPEC
prompt: 01-baseline
status: verified
---

# RPR-SPEC — Freeze feature-complete workloads and budgets

## What this claim delivers

The machine, toolchain, commit, and binary digest; five frozen workloads with their manifests and
their build/cache states; the phase schema the profile channel speaks; expected output digests; the
latency, RSS, pressure, and swap gates; the variance policy; and the stop rules — recorded as measured
numbers at `369057d`, not as targets.

Two documents carry it and this note is the index:

- `notes/01-phase-schema.md` — the channel, the frozen names, the names `RPR-IMPL` must add, and the
  completeness gate.
- `evidence/01-workloads.md` — environment, states, workloads, baselines, gates, measurement practice.

## The finding that shaped it

**The phase schema explains the runs that are already fast and says nothing about the runs that are
slow.** Summing every `phase.*` value a run emits against its wall time:

| Workload | Wall | Accounted |
| --- | ---: | ---: |
| `mathlib-sample` `check`, cache-warm | 10,863 ms | 97.3% |
| `self` `check`, cache-warm | 564 ms | 74.1% |
| `mathlib-sample` `check`, cache-cold | 24,696 ms | 46.1% |
| `stress-largest` `format --check`, cache-cold | 19,152 ms | 21.3% |
| `self` `check`, cache-cold | 21,099 ms | 1.8% |
| `self` `format --check`, cache-cold | 43,506 ms | **0.9%** |

The missing time is in one place in every case: `withExactRun` and the per-snapshot loop under it
(`Application.lean:1431-1468`) are unbracketed end to end. That single region contains the exact
frontend, every rule tier above import, layout, validation, and cache writes — five of the phases the
completion contract asks this stack to profile separately, presently reported as one unnamed
43-second gap.

So this prompt made the schema a falsifiable specification rather than a list of names. Thirteen
phase names are assigned to sites that exist today (`notes/01-phase-schema.md` §4), and the schema is
finished when **the accounted fraction reaches 90% on every frozen workload** — not when the names
exist. The table above is the before picture, kept so the after picture can be compared to it.

## Commands

Environment and binary:

```sh
LEAN_NUM_THREADS=1 lake build
shasum -a 256 "$(lake -q query lean-fmt --text)"
```

Each baseline run, with the states named explicitly (`self` `check` cold shown; the rest differ only
in `--name`, `--project-root`, `--sources`, the mode, and whether `.lean-fmt-cache` was removed first):

```sh
app=$PWD/.lake/build/bin/lean-fmt
rm -rf .lean-fmt-cache
LEAN_FMT_PROFILE_PHASES=1 LEAN_FMT_PROFILE_BINARY="$app" experiments/profile-run.sh \
  --name rpr-self-check-cold --project-root "$PWD" \
  --build-state ordinary-built --cache-state formatter-cache-cold \
  --sources experiments/workloads/lean-fmt-self.txt \
  -- experiments/run-check-workload.sh "$app" "$PWD" \
     experiments/workloads/lean-fmt-self.txt check --output-format concise
```

Isolated-printer envelope and LSP baseline:

```sh
lake setup-file LeanFmt/Printer.lean > "$setup"
lake env "$app" __analyze-exact "$setup" LeanFmt/Printer.lean LeanFmt/Printer.lean 8589934592 > env.json
/usr/bin/time -l "$tests" printer-format env.json LeanFmt/Printer.lean 100   # x5
bash tests/lsp/acceptance.sh
```

Raw evidence: `experiments/results/rpr-*-20260721T17*.{meta,phases,stdout,stderr}`.

## Measurements

Full table in `evidence/01-workloads.md` §4. The load-bearing rows:

- **Cold-to-warm is 37–78×.** `self` `format --check` 43,506 ms → 559 ms; `self` `check` 21,099 ms →
  564 ms; `mathlib-sample` `check` 24,696 ms → ~11,300 ms (only 2.2×, and §"What this says to
  `RPR-IMPL`" explains why the large project behaves differently).
- **Output digests are stable across the cold/warm pair**, which is what makes them usable as G1
  behavior gates: `mathlib-sample` produced byte-identical 27-finding output cold and warm.
- **The envelope has 9.7× headroom.** Worst peak aggregate RSS across every run: 864,032 KiB =
  0.82 GiB against the 8 GiB gate. Zero swap growth on every run; pressure level never left 1.
- **The `ruff-17` LSP baseline holds unchanged** at this commit: 3,632 ms uncancelled (recorded
  3,637), 465 ms cancelled (470), subtree RSS 682,544 / 692,656 / 687,936 KiB over 100 requests
  (682,880 / 690,640 / 685,840). All within 1.5%. Adopted rather than re-derived.

### The 61.7 MiB envelope is the printer's, not the application's

The completion contract calls ~61.7 MiB "the recorded envelope". Traced to source, that is
`RLF-REFLOW-ACCEPT`'s **isolated printer** measurement — `lean-fmt-tests printer-format` on one
module, single process, no Lake workspace. Re-measured here: **64.6 MiB**, 0.16 s, output
byte-identical.

The application's peak aggregate RSS on the same machine is 441–864 MiB: seven to thirteen times
larger, because it loads a Lake workspace and spawns exact-frontend children. Both are far inside the
8 GiB gate, but they are different numbers about different things, and the contract's phrasing invites
merging them. `evidence/01-workloads.md` §4 records them separately and under separate names.

The printer's +4.7% against the record is not called a regression: the source grew 129,041 → 138,693
bytes (+7.5%) and the toolchain moved `v4.32.0` → `v4.33.0-rc1`. Two confounds, both pointing the same
way, each larger than the effect.

## Decisions changed during execution

1. **The schema gets a completeness gate, not just a name list.** Planned as an enumeration. Once §3's
   numbers existed, an enumeration was obviously insufficient — a schema can have every name in it and
   still explain 0.9% of the run. G3 (accounted fraction ≥ 90%) is the actual specification.
2. **`profile-run.sh` now retains `cache.*` counters, not only `phase.*_ms`.** The harness dropped
   them, which preserved exactly the wall-time-only ambiguity that made `ruff-16` misattribute a
   cache-key invalidation (`ruff-16b` `RCI-SPEC`). One-line grep change; the counters are in every
   `.phases` file recorded here.
3. **The `self` selection is materialized as a manifest.** `profile-run.sh` requires the command to
   process exactly its manifest, and discovery-selected runs cannot satisfy that. Checked equal to
   live discovery rather than assumed: `lean-fmt check --output-format json` reports exactly the
   frozen 34 paths.
4. **A rejected design is recorded** — a `--profile` CLI flag (`notes/01-phase-schema.md` §6). It
   would make execution strategy a public surface, which `roadmap.md`'s stop rules forbid.

## Measurement practice this established

Four rules, each from something that went wrong while producing the table
(`evidence/01-workloads.md` §6):

1. **A rebuild silently makes every run cold.** Cache identity includes the binary's
   `(path, size, mtime)`. The first `self` `check` measured 19.8 s and a repeat measured 0.45 s;
   nothing was wrong except that `lake build` had run in between.
2. **Peak RSS is undersampled below ~2 s.** The wrapper polls at 250 ms. Three `self` warm runs of
   559–564 ms — 0.9% wall variance — reported 441,920 / 449,504 / 591,056 KiB, a 34% spread that is
   entirely sampling artifact. On the ≥ 10 s workloads the spread is 0.15%.
3. **Wall variance is workload-dependent**: 0.9% (`self` warm) against 7.8% (`mathlib-sample` warm).
   G6's 1.25× regression threshold clears both by a wide margin.
4. **`self`'s digest is a weak oracle.** It is the SHA-256 of the empty string, because this
   repository is both lint-clean and canonically formatted. It stays empty under many wrong changes.
   `mathlib-sample` (27 findings) and `stress-largest` (2) are the discriminating digests.

## What this says to `RPR-IMPL`

Recorded as measurement; the prompt decides what to do with it.

- **Cold time is the exact frontend and it is unmeasured.** Closing G3 comes before optimizing
  anything cold, because today there is nothing to attribute a win to.
- **Warm time on a large project is `cache_lookup`, and serving more entries cannot help it.** On
  `mathlib-sample` warm, `phase.cache_lookup_ms` is 8,187–8,994 ms of 10,863–11,706 — 75–79% of the
  run — with 62/62 already served. This is `ruff-16b`'s inherited result reproduced: warm is bounded
  by fixed per-run cost, not hit rate. The named cost inside it is per-entry closure digests.
- **`workspace_load` is a floor of 321–330 ms here, 588–644 ms on mathlib**, paid whether one file is
  selected or 62. A single-file `check` on this repository is 369 ms end to end, 321 ms of it
  workspace load.

## Checks read

| Check | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | 52 jobs, success |
| `lake lint` | clean (this repository is its own workload `self`; digest `e3b0c442…`) |
| `lake exe lean-fmt-tests` | pass |
| `tests/boundary/run.sh` | pass |
| `tests/lsp/acceptance.sh` | pass, numbers above |
| `check_stack.py` / `write_next.py --check` | pass |
| `git diff --check` | clean |

## Remaining uncertainty

- **`formatter-integrated-built` has no frozen workload.** The state is defined and reachable only
  through this repository's own fixture libraries; nothing in §4 exercises it. `RPR-IMPL` owns adding
  one if it profiles the artifact path, or recording why the ordinary-built path is sufficient.
- **The adversarial `PositionIndex` build fixture does not exist.** `ruff-15` handed forward the shape
  — one enormous line, findings clustered at the end of a very large file — and it is not frozen here,
  because the phase that would measure it (`phase.positions_ms`) does not exist yet either. Both are
  `RPR-IMPL`'s.
- **`mathlib-sample` warm is 11.3 s here where `ruff-16b` `RCI-FINAL` recorded 6.3 s.** Same shape,
  different run: different mathlib page-cache state, a moved commit (`ruff-17` and `ruff-18` landed
  since), and explicit-path selection rather than whatever route that prompt used. Not diagnosed. It
  is recorded because a 1.8× difference on the workload this stack will optimize against should not be
  discovered later and mistaken for a regression this stack caused.
- **Mathlib is not at the revision the sample was frozen against** (`8c79cb4f` / `v4.33.0-rc1` against
  `783ccda4` / `v4.32.0`). All 62 paths exist; the toolchain matches this repository's. Same-shape,
  not same-run, comparable to `ruff-16b`'s numbers — which recorded the identical drift for the
  identical reason.
- **Concurrency is untouched.** Every measurement is `LEAN_NUM_THREADS=1` by construction. The
  two-session adoption rule belongs to `RPR-IMPL` and is not prejudged here.
