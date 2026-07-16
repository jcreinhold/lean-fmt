# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project using Lean's private-by-default module system.
Its current lower layer is a one-root compiler plugin that persists a silent formatter record in the
successful module `.olean`, plus a Lake module facet that owns supported extraction into a compact
content-addressed sidecar. The product execution operation and CLI modes are not yet implemented.
Do not restore the archived Rust workspace, worker protocol, `libleanshared`
boundary, or seven-crate decomposition. Architecture work is governed by
`docs/projects/execution-core-v2/` and its recorded measurements.

## Build

```sh
lake build
lake exe lean-fmt
lake exe lean-fmt-tests
tests/compiler/run.sh
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
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a
  public descriptor, not authority by type alone; recompute its content hash and match module and
  the full source snapshot. Filesystem presence or a raw path is not build validity.
