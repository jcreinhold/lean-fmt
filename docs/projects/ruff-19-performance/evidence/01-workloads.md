# Frozen workloads, states, and baselines

`RPR-SPEC`. Everything `RPR-IMPL` and `RPR-FINAL` measure against.

Raw profiles are committed under `experiments/results/rpr-*` as `.meta` (states, environment, wall,
RSS, swap, pressure, digests), `.phases` (the `phase.*`/`cache.*` channel), and `.stdout` (the report
the digest is over). That directory is `.gitignore`d, so these are force-added, as previous stacks'
profiles were. The `.stderr` halves are not committed: on every run here they contain the phase
channel and nothing else, already extracted into `.phases`.

## 1. Environment

| Field | Value |
| --- | --- |
| Machine | `supermartingale.local`, Darwin 25.5.0, `arm64` (Apple M4 Pro, 12 cores, 24 GiB) |
| Toolchain | `leanprover/lean4:v4.33.0-rc1` |
| `lean-fmt` commit | `369057d9dc365c9fd54e9c8e8217cb9a99a05847` |
| Binary | `.lake/build/bin/lean-fmt`, 183,965,072 bytes |
| Binary digest | `e34911b4dbb2bfb6db56737b35af7855f39ac6707e0a9cc9b9121722ddcc6475` |
| `mathlib4` checkout | `8c79cb4f540eeb519b1a2187009a1916521fd168`, same toolchain |
| Threads | `LEAN_NUM_THREADS=1`, set by `experiments/profile-run.sh` unconditionally |

The mathlib checkout is not the revision the 62-file sample was frozen against (`783ccda4…` /
`v4.32.0`); `ruff-16b` `RCI-FINAL` recorded the same drift and the same reasoning. All 62 paths still
exist, checked at this commit, and rebuilding mathlib at the old revision is not a cost this stack
justifies. Numbers are same-shape comparable to `ruff-16b`'s, not same-run.

## 2. Build and cache states

The four states `CLAUDE.md` names, made concrete:

| State | Means |
| --- | --- |
| `ordinary-built` | the target project's `.lake/build` is current; no formatter plugin in its build |
| `formatter-integrated-built` | the target project builds with `LeanFmtCompilerPlugin`, so `leanFmtArtifact` is available. Reachable only in this repository's own fixture libraries (`CompilerFixtures`, `CheckFixtures`). `RPR-IMPL` added the workload; see § 3.1 |
| `formatter-cache-cold` | the target project's `.lean-fmt-cache` directory is absent |
| `formatter-cache-warm` | the cache was populated by an immediately preceding identical run |

**Cache identity includes the formatter binary's `(path, size, mtime)`.** Rebuilding `lean-fmt`
silently converts every subsequent run into a cache-cold run. Any measurement that rebuilds between
its baseline and its comparison is measuring that, not the change.

## 3. Workloads

| Id | Manifest | Files | Route |
| --- | --- | --- | --- |
| `self` | `experiments/workloads/lean-fmt-self.txt` | 34 | this repository, explicit paths |
| `mathlib-sample` | `experiments/workloads/mathlib-v4.32.0-sample.txt` | 62 | `~/Code/mathlib4`, explicit paths |
| `stress-largest` | `experiments/workloads/mathlib-v4.32.0-stress-largest.txt` | 1 | `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean`, 63,748 bytes — the largest module in the sample |
| `printer-envelope` | — | 1 | `LeanFmt/Printer.lean` (138,693 bytes) through the isolated printer, `lean-fmt-tests printer-format` |
| `lsp` | — | 1 | `tests/lsp/acceptance.sh`, driving the server with `Lean.Data.Lsp.Ipc` |

`self` is the manifest `lean-fmt.toml`'s own `exclude` list selects, materialized so that selection is
frozen rather than whatever discovery finds on the day. Equality with live discovery was checked, not
assumed — `lean-fmt check --output-format json` over this repository reports exactly these 34 paths,
so freezing the list changed nothing about what is measured. A future directory that discovery starts
selecting will show up as a diff against this manifest, which is the point of writing it down.

**It happened immediately, and the manifest is deliberately not being regenerated.** `RPR-IMPL` added
`LeanFmt/Profile.lean`, so `lake lint` now selects 35 files where this manifest names 34. The workload
stays at 34: every run goes through `run-check-workload.sh`, which passes the manifest's paths
explicitly, so the corpus growing did not change what any baseline measured and the before/after
numbers in `results/02-optimize.md` are comparisons of the same work. Regenerating the manifest would
silently make them not that. Whoever widens the workload should do it as its own change, with a
re-baseline, and say so. It is deliberately run through
`experiments/run-check-workload.sh`, which passes every path explicitly: `profile-run.sh` requires the
command to process exactly its manifest and cannot check that, so explicit paths are how the
requirement is met literally.

The consequence is recorded rather than glossed: an explicit-path run still performs the discovery
walk (`Discovery.run` walks the root regardless), but it does not measure discovery *as selection*. On
`mathlib-sample`, `phase.discovery_ms` is the 8,795-file walk and shows up as 368–420 ms.

### 3.1 `integrated` — the workload this manifest first left open

`RPR-IMPL`. Four modules that this repository builds *with* `LeanFmtCompilerPlugin`, so each one's
`.olean` carries a `leanFmtArtifact` the formatter can read instead of re-running the frontend:

| Id | Modules | How to reach it |
| --- | --- | --- |
| `integrated` | `tests/compiler/LocalSyntax.lean`, `tests/check/{Clean,Findings,Layout}.lean` | `lake build CompilerFixtures CheckFixtures`, then pass the four paths explicitly |

It is the only state in which `phase.official_artifacts_ms` does any work. It is deliberately small:
its purpose is to exercise a path no other workload reaches, not to be a speed benchmark, and its
fixtures are owned by the suites that already maintain them.

**A syntax-tier rule is what separates the two states.** Source-tier rules need no artifact at all,
and a semantic-tier demand skips the facet and goes to the frontend regardless — `format --check` on
these same four modules records no `official_artifacts` phase and four `exact_child` runs. So the
comparison has to be a syntax-tier selection, here `check --preview --select FMT012`, four modules
each:

| State | `official_artifacts` | `exact_child` |
| --- | ---: | ---: |
| `formatter-integrated-built` (`integrated`) | 105 ms | **never runs** |
| `ordinary-built` (four `LeanFmt/` modules) | 101 ms | 2,058 + 370 + 634 + 221 = **3,283 ms** |

One Lake traversal replaces four frontend child processes, about 820 ms per module. That is what the
compiler integration exists to do, and this is the first measurement of it in this project rather
than an argument for it.

**And a cost it exposes.** On `ordinary-built` the facet fetch still runs and still costs 101 ms
before finding nothing — the same order as every other no-build traversal here (`setup_prime`,
100 ms). It has to look in order to know. But a workspace where no module declares the plugin can
never produce an artifact, and that is decidable from the workspace alone without a traversal. 101 ms
once per run is too small to spend this stack's remaining work on; it is written down so that it is a
choice rather than an oversight.

**Not yet frozen, and named so it is not mistaken for covered.** The completion contract asks for
adversarial files, and one specific adversarial shape is inherited from `ruff-15`: a pathological
`PositionIndex` **build** — one enormous line, findings clustered at the end of a very large file.

`RPR-IMPL` discharged it, by generating rather than freezing: `experiments/run-positions-bench.sh`
writes four shapes into the `tests/reporting/` tree `lean-fmt.toml` already excludes and removes them
on exit, because they are megabytes of filler the script reproduces exactly. `phase.positions_ms`
exists now too, and the first thing the fixture found was that the phase had been measuring nothing
(`results/02-optimize.md`).

## 4. Baselines

Every row is one `experiments/profile-run.sh` invocation on 2026-07-21, `LEAN_FMT_PROFILE_PHASES=1`,
`LEAN_FMT_PROFILE_BINARY` pointed at the binary in §1.

| Run | Wall | Peak RSS | Swap Δ | Pressure | `index_hits` / `targets` | Exit | Output digest |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `self` `check` cold | 21,099 ms | 717,536 KiB | 0 | 1 | 0 / 34 | 0 | `e3b0c442…` |
| `self` `check` warm ×3 | 564 / 559 / 559 ms | 441,920–591,056 KiB | 0 | 1 | 34 / 34 | 0 | `e3b0c442…` |
| `self` `format --check` cold | 43,506 ms | 728,192 KiB | −16,384 | 1 | 0 / 34 | 0 | `e3b0c442…` |
| `self` `format --check` warm ×2 | 559 / 560 ms | 480,640–588,432 KiB | 0 | 1 | 34 / 34 | 0 | `e3b0c442…` |
| `mathlib-sample` `check` cold | 24,696 ms | 864,032 KiB | 0 | 1 | 0 / 62 | 1 | `c0dc55c3…` |
| `mathlib-sample` `check` warm ×3 | 10,863 / 11,706 / 11,394 ms | 838,176–839,392 KiB | 0 | 1 | 62 / 62 | 1 | `c0dc55c3…` |
| `stress-largest` `format --check` cold | 19,152 ms | 738,624 KiB | 0 | 1 | 0 / 1 | 0 | `e6cf397c…` |

`e3b0c442…` is the SHA-256 of the empty string. This repository is lint-clean *and* canonically
formatted, so `check` and `format --check` both emit nothing over `self`. That is a real frozen
digest, not a missing measurement — but it is a weak one, and §6 says what to do about it.

`c0dc55c3…` is 27 findings, all `FMT007` import-order, identical cold and warm. Exit 1 is the
findings exit code, not a failure.

Phase records for each run are in the matching `.phases` file;
`notes/01-phase-schema.md` §3 tabulates what fraction of each wall time they account for.

### `printer-envelope`

`lean-fmt-tests printer-format /tmp/printer-env.json LeanFmt/Printer.lean 100`, five runs,
`/usr/bin/time -l`, single process. Envelope produced by `lean-fmt __analyze-exact` over the same
module (516,625-byte projection).

| Metric | Now | `RLF-REFLOW-ACCEPT` record |
| --- | ---: | ---: |
| Wall (min of 5) | 0.16 s | 0.14 s |
| Peak RSS (min of 5) | 67,780,608 B ≈ **64.6 MiB** | 64,651,264 B ≈ 61.7 MiB |
| Output | byte-identical to input | byte-identical to input |

**This is the ~61.7 MiB the completion contract calls "the recorded envelope", and it is the isolated
printer's envelope — not the application's.** The distinction matters and the contract's phrasing
invites confusing them: the application's peak aggregate RSS on the same machine is 441–864 MiB (§4),
seven to thirteen times larger, because it loads a Lake workspace and spawns exact-frontend children.
Both are far inside the 8 GiB gate; only one of them is what "61.7 MiB" ever meant.

The +4.7% RSS against the record is not treated as a regression: the source grew from 129,041 to
138,693 bytes (+7.5%) and the toolchain moved `v4.32.0` → `v4.33.0-rc1`. Two confounds, both in the
direction of the change, and the change is smaller than either.

### `lsp`

`tests/lsp/acceptance.sh`, full pass, reproduced against `ruff-17` `RLP-ACCEPT`:

| Metric | Now | `ruff-17` record |
| --- | ---: | ---: |
| Uncancelled format of `LeanFmt/Application.lean` | 3,632 ms | 3,637 ms |
| In-flight cancellation | 465 ms | 470 ms |
| Session subtree RSS, first / peak / last of 100 | 682,544 / 692,656 / 687,936 KiB | 682,880 / 690,640 / 685,840 KiB |

All three within 1.5% of the recorded values. The `ruff-17` LSP baseline holds at this commit and is
adopted unchanged.

## 5. Gates

Frozen here; `RPR-FINAL` installs them as checks.

- **G1 — Output digest.** Each workload's stdout digest equals the §4 value. An optimization that
  changes a digest is a behavior change and stops the work, not a faster run.
- **G2 — Resource envelope.** Peak aggregate RSS < 8 GiB, new swap ≤ 256 MiB, pressure level ≤ 1,
  enforced live by `profile-run.sh` (which kills the process group and reports `hard_stop`). Worst
  observed: 864,032 KiB = 0.82 GiB, 9.7× headroom; zero swap; pressure never left 1.
- **G3 — Accounted fraction ≥ 90%** per workload, `notes/01-phase-schema.md` §5.4.
- **G4 — Cache accounting.** A warm run reports `cache.index_hits == cache.targets`. Wall time alone
  cannot assert this and has already been misread once (`ruff-16b` `RCI-SPEC`).
- **G5 — Growth ratios, not wall-clock budgets**, for anything installed per commit. This is the
  existing convention (`tests/layout/bench.sh`, `tests/security/bench.sh`): a machine-time threshold
  is a number invented on one machine that fails on a slower one while catching nothing.
- **G6 — Regression against a recorded baseline** is min-of-3 wall time exceeding **1.25×** the §4
  min, on this machine, same states. Justified by §6's measured variance, not chosen for roundness.

## 6. Measurement practice this baseline established

Four rules, each from something that happened while producing §4.

1. **Rebuild invalidates the cache.** The first `self` `check` measured 19.8 s where a repeat measured
   0.45 s. Nothing was wrong: `lake build` had just changed the binary's mtime, so the "warm" run was
   cold. Never compare across a rebuild.
2. **Peak RSS is undersampled on short runs.** `profile-run.sh` polls the process group every 250 ms.
   Three `self` warm runs of 559–564 ms — 0.9% wall variance — reported 441,920, 449,504, and 591,056
   KiB: a 34% spread that is entirely sampling. Peak RSS from a run under ~2 s is an upper-bound
   sample, not a measurement, and must be reported as one. The long workloads (≥ 10 s) do not have
   this problem: `mathlib-sample` warm spread 0.15% across three runs.
3. **Wall variance is workload-dependent.** `self` warm 0.9%; `mathlib-sample` warm 7.8% (10,863 /
   11,706 / 11,394 ms). G6's 1.25× clears both.
4. **`self`'s clean digest is a weak oracle.** An empty stdout stays empty under a great many wrong
   changes. `mathlib-sample`'s 27 findings and `stress-largest`'s 2 are the digests that can actually
   fail; `self` is the fast per-commit shape, not the discriminating one.

## 7. What this baseline says to `RPR-IMPL`

Recorded as measurement, not as instruction — the prompt decides what to do about it.

- **Cold is the exact frontend, and it is unmeasured.** `self` `format --check` spends 43.1 s of 43.5 s
  inside one unbracketed region. Every cold number in §4 is dominated by it. Closing G3 is a
  prerequisite for attacking any of it, because right now there is nothing to attribute a win to.
- **Warm on a large project is `cache_lookup`, and serving more entries cannot help.** On
  `mathlib-sample` warm, `phase.cache_lookup_ms` is 8,187–8,994 ms of 10,863–11,706 — 75–79% of the
  run — with 62/62 entries already served. This is exactly the shape `ruff-16b` handed forward: warm
  is bounded by fixed per-run cost, not by hit rate. The named cost inside it is per-entry closure
  digests over closures thousands of members deep.
- **`workspace_load` is a floor on every run.** 321–330 ms on this repository, 588–644 ms on mathlib,
  paid whether one file is selected or 62. A single-file `check` on this repository is 369 ms end to
  end, of which 321 ms is loading the Lake workspace.
- **Two eager-work defects of exactly this shape were already found by measuring** (`ruff-16b`): a
  whole-workspace fallback computed for a value nothing reads, and `importAllArts` recomputed per
  (module, closure member) pair. Both were invisible on small fixtures. Suspect the pattern again.
