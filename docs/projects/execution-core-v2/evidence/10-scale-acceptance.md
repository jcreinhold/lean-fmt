# Prompt 10 scale acceptance

Date: 2026-07-16

Prompt status: verified.

## Frozen identities

- Machine: `supermartingale.local`, Darwin 25.5.0 arm64.
- Project: mathlib `783ccda4ee524f13cc5636237be0a1942bc04824`.
- Toolchain: `leanprover/lean4:v4.32.0`.
- Workload: 8,795 sorted non-`.lake` Lean sources; manifest digest
  `a74d51b39a9c4fe01c7d06ccb2d60325c89784c0244d6ceea1a9a927e1173286`.
- Candidate binary digest:
  `1cfe628b6c85bade65ee56c086c1e2e86d509afc36db649b77738f29d6f13374`.
- Successful full-report digest:
  `4cc843aa976ca0fa67ef51474f0affc39408f4c313523917c36af7ab39a02646`.
- Resource gate: 8,388,608 KiB aggregate RSS, normal pressure only, and at most 262,144 KiB new swap.

Raw profiler records are under `experiments/results/` and are intentionally ignored machine evidence;
the stable names below bind this summary to their metadata, phase, stdout, and stderr records.

## Accepted complete runs

| State | Profile | Command distinction | Wall | Peak RSS | Pressure | Swap delta | Coverage |
| --- | --- | --- | ---: | ---: | --- | ---: | --- |
| Ordinary built, formatter cache cold | `scale-cache-index-cold-full-acceptance-20260716T052410Z` | normal release `check --root … --json` | 109.649 s | 1,315,248 KiB | normal | −16,384 KiB | 8,795/8,795 |
| Formatter cache warm | `scale-cache-index-warm-full-final-20260716T052259Z` | module evidence and artifact disabled; analyzer set to `/usr/bin/false` | 16.290 s | 1,150,528 KiB | normal | 0 KiB | 8,795/8,795 |

The cold phases were workspace 493 ms, selection/snapshot 522 ms, environment epoch 14,238 ms,
cache lookup 0 ms, shared module evidence 14,056 ms, and official artifacts 0 ms. The warm phases were
workspace 477 ms, selection/snapshot 547 ms, epoch 9,220 ms, and aggregate-index lookup 3,719 ms.
Both runs exited 0 with exactly one unique, bytewise path-sorted clean result per selected source and
the same output digest. The warm command forced every post-cache evidence source to fail if reached,
so it proves the all-hit return constructs no frontend/analyzer/extractor path.

The prerequisite ordinary mathlib build is excluded from both timings. Mathlib was not rebuilt with
the formatter plugin: current rules are source-input rules, so the official syntax artifact operation
is not on their semantic path. The focused compiler suite, rather than a wasteful full integrated
build/run, validates registered-facet no-build consumption, source/config/plugin trace invalidation,
content-hash checking, corrupt output rejection, explicit rebuild, cache restoration, and failed
elaboration nonpublication.

## Targeted remainder and atomic merge

The 12 stale/standalone sources in
`experiments/workloads/mathlib-v4.32.0-remainder.txt` completed exact fallback in 86.297 seconds at
1,141,184 KiB peak RSS (`scale-cache-index-remainder-12-20260716T052007Z`). A subsequent full partial-
cache run merged their entries with the ordinary module results in one atomic index and completed in
28.487 seconds at 1,274,064 KiB (`scale-cache-index-merge-full-20260716T052214Z`). The final index
contains 8,795 entries in 3,362,610 bytes.

## Rejected cache designs and enforced stops

The first result-cache representation used one file per source. Its full lookup phase took 46.868
seconds and a complete warm run took 63.243 seconds. It was replaced by the aggregate index because
the filesystem work was both slower and more complex.

Three diagnostic cache-population attempts were stopped by the profiler when system-wide pressure
rose above the allowed normal level:

| Profile | Stop wall | Product peak RSS | Finding |
| --- | ---: | ---: | --- |
| `scale-cache-population-full-20260716T045331Z` | 86.127 s | 1,276,064 KiB | file-per-entry lookup and missing-file exceptions |
| `scale-cache-index-population-full-20260716T050908Z` | 177.053 s | 1,276,176 KiB | empty index still performed per-target identity/setup work |
| `scale-cache-index-population-full-final-20260716T051300Z` | 150.333 s | 1,308,624 KiB | candidate correct, but unrelated system pressure crossed the gate |

These are deliberately stopped diagnostics, not OOMs or acceptance runs. They demonstrate that the
resource monitor enforced the system-pressure condition independently of product RSS. After the
machine returned to 83% free memory, the unchanged final candidate passed the complete cold gate.

## Semantic and cache checks

Focused suites prove current/stale/missing/corrupt ordinary evidence; standalone and malformed files;
source, dependency, external-configuration, toolchain, validation, and runtime invalidation; corrupt
index-as-miss; deterministic cache merge; official artifact verification; exact fallback equality;
and complete deterministic selection. In particular, changing a dependency source while leaving its
artifact and compact trace untouched now invalidates the coarse source-aware epoch.
