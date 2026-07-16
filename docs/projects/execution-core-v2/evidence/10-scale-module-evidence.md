# Prompt 10 major step: complete selection and ordinary module evidence

Date: 2026-07-16

## Delivered boundary

- `LeanFmt.Project` now owns exact toolchain/workspace loading, filesystem-complete source selection,
  immutable snapshots, module/standalone classification, one shared typed Lake no-build graph, exact
  edited-source setup, and configuration identity.
- `LeanFmt.Semantic` separates product findings and diagnostics from compiler-only command shapes.
  FMT001/FMT002 declare source input; a current ordinary `.olean` can therefore authorize their
  result without pretending to contain syntax.
- Default selection now covers every root-relative `.lean` outside `.lake`. The frozen mathlib
  checkout classifies as 8,788 Lake modules plus seven standalone sources; 8,781 module outputs are
  current and seven script/tool modules are stale.
- Lake configuration files use Lake's own evaluator as their exact source-only evidence. Importing
  `all Lake.DSL` is necessary to link the command-elaborator implementations; importing only the
  public syntax surface produced honest “elaboration function ... has not been implemented” errors.
- The semantic cache now accepts generalized source targets, including standalone and configuration
  sources. The all-hit branch still precedes module evidence and frontend construction.

## Measurements

Machine: `supermartingale.local`, Darwin 25.5.0 arm64. Target: mathlib
`783ccda4ee524f13cc5636237be0a1942bc04824`, Lean v4.32.0, ordinary artifacts built,
formatter cache cold, `LEAN_NUM_THREADS=1`.

| Path | Sources | Wall | Key phase | Peak RSS | Pressure | Swap delta | Result |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| Old per-file production path, stopped | 8 | 180.958 s | no result before stop | 4,776,128 KiB | normal | −8,192 KiB | decisively losing |
| Typed module-evidence probe | 8 | 5.303 s | evidence 3.318 s | 678,384 KiB | normal | 0 KiB | 8 current |
| Typed module-evidence probe | 62 | 4.409 s | evidence 3.679 s | 699,056 KiB | normal | 0 KiB | 62 current |
| Production release fast path | 62 | 1.967 s | workspace 470 ms; evidence 1.139 s | 709,936 KiB | normal | 0 KiB | 62/62 clean |

The current release sample used binary SHA-256
`ba70d340e479efa3c355f22765a18aa0cd0a93159b7395e2aec0e85a85492784`, sample digest
`1936bdb60e01c14fdc986a535ef9317d63775506708e35f4155a9c4c5c6eeeef`, and output digest
`c8cff2f3fed6fc0fd367d05c39b31d565b9ed0c584925fd6439d4417551d3a84`. Raw records are ignored
build evidence under `experiments/results/scale-*-20260716T*.{meta,stdout,stderr,phases}`.

## Harness corrections

- The first eight-file attempt backgrounded `xargs` with no preserved stdin and processed zero
  sources. It is not evidence.
- A later `/bin/bash` wrapper used `mapfile`, which macOS Bash 3.2 does not provide. It passed no
  positionals and accidentally exercised default full selection. That diagnostic run completed all
  8,795 sources in 63.647 seconds at 958,080 KiB but reported both lakefiles broken before Lake DSL
  implementation modules were linked. It proves the candidate is plausible but is not acceptance.
- The valid manifest wrapper is POSIX `sh` and expands every line into one positional argument. The
  profiler now records an explicit binary path and SHA-256 in addition to repository revisions.

## Focused gates

- `lake exe lean-fmt-tests`: pass.
- `tests/compiler/run.sh`: pass.
- `tests/check/run.sh`: pass with the private exact-oracle substitution disabling module evidence.
- `tests/modes/run.sh`: pass.
- `tests/scale/run.sh`: pass for complete deterministic selection, ordinary module evidence,
  standalone source, nested/root lakefiles, all-hit worker avoidance, and stale-source invalidation.
- The current 62-file profile has no crash, broken file, infrastructure failure, pressure excursion,
  or swap growth.

## Remaining work

This major step does not complete ECV2-SCALE. The full acceptance must be rerun intentionally from a
committed binary after the complete gates pass. The seven stale modules and five non-lakefile
standalone sources require fresh exact fallback; their individual behavior must be checked before
acceptance. Formatter-integrated direct facet consumption and a genuine complete warm-cache run also
remain to be measured.
