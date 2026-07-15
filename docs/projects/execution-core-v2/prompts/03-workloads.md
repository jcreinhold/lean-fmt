---
claim_id: ECV2-WORKLOADS
status: planned
depends_on: [ECV2-NATIVE-RESET]
---

# Freeze semantics and distinguish the performance workloads

## Task

Define the exact formatter oracle and four non-interchangeable workloads before selecting an
execution strategy: ordinary project built with current `.olean`s, formatter-integrated build
artifacts present, formatter cache cold, and formatter cache warm.

## Read

- `notes/02-architecture-pause.md` and `experiments/pure-lean-core/RESULT.md`.
- Lean v4.32.0 `Environment`, `Elab.Frontend`, `Language.Lean`, module-linter, plugin, and snapshot APIs.
- Mathlib commit `783ccda4ee524f13cc5636237be0a1942bc04824` and its 8,795-file workload.

## Target

- A result note specifying exact ordered header/import semantics, sequential file-local syntax
  effects, syntax versus elaboration validation, diagnostic/edit projection, and deterministic output.
- A persistent profiler that records source selection, build state, cache state, toolchain, phase
  times, process-tree RSS, pressure, swap delta, and output digest.
- Fresh exact full-frontend results are the differential oracle; selective elaboration is never
  labeled exact without differential evidence.

## Stop

Do not call a formatter-integrated build an ordinary built project. Do not count project compilation
inside a formatter-cache timing without reporting it separately.

## Check

- Reproduce the existing pure Lean measurements with the exact toolchain.
- Verify deterministic workload selection and hard 8 GiB/256 MiB swap stops.
- `lake build`
- `git diff --check`
