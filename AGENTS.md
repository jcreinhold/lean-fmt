# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project using Lean's private-by-default module system.
All compiled production, entry-point, test, and fixture sources begin with `module`; only executable
`lakefile.lean` configuration is exempt. The product now has one private intent-to-report operation,
an aggregate atomic semantic-result cache, preview/fix modes, and read-only compiler-integration
audit. A compiler plugin persists a silent formatter record in the successful module `.olean`, and a
Lake module facet owns supported extraction into a compact content-addressed sidecar. The application
consumes that registered facet through one private no-build Lake operation only when a selected rule
needs syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate
decomposition. Architecture work is governed by `docs/projects/execution-core-v2/` and its recorded
measurements.

## Build

```sh
lake build
lake exe lean-fmt
lake exe lean-fmt-tests
tests/compiler/run.sh
tests/check/run.sh
tests/modes/run.sh
tests/scale/run.sh
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
- Keep CLI parsing/rendering in `LeanFmt.Cli`; semantic execution, validation, stale checking, and
  publication belong to `LeanFmt.Application` and its lower capabilities.
- `check`, `format`, and `diff` never write source. `fix` publishes only a complete conflict-free
  patch validated under the exact module setup, after a stale-source check.
- Rule selection is a projection over canonical results and must not enter execution strategy or
  result-cache identity.
- `LeanFmt.Project` owns complete non-`.lake` source selection, exact Lake setup, and one shared
  typed no-build graph. Do not replace it with per-file Lake runs or module-only selection.
- A current ordinary `.olean` is successful-compilation evidence for source-input rules, not a
  serialized syntax projection. Syntax-input rules require the compiler artifact or exact frontend.
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a
  public descriptor, not authority by type alone; recompute its content hash and match module and
  the full source snapshot. Filesystem presence or a raw path is not build validity.
- Do not repeatedly run full mathlib during development. Prompt 10 uses the frozen sample and named
  stress cases; the 8,795-file run is reserved for a plausible late candidate.
