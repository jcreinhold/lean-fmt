# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a deliberately minimal `lake init` foundation. Do not restore the archived
Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate decomposition. Architecture
work is governed by `docs/projects/execution-core-v2/` and must be supported by the measurements in
its notes and `experiments/`.

## Build

```sh
lake build
lake exe lean-fmt
```

Use the target project's exact Lean toolchain for frontend/plugin experiments. Keep experiments out
of production modules until their owning prompt selects and verifies the interface.

## Design constraints

- Prefer pure Lean. Add another language only for a named capability or measured performance gain
  unavailable in Lean.
- Preserve exact ordered imports, search-path precedence, syntax effects, and validation identity.
- Do not call superset parsing exact.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as
  distinct workloads.
- Stop memory experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Keep public API minimal; favor private deep modules that hide lifecycle and cache sequencing.
