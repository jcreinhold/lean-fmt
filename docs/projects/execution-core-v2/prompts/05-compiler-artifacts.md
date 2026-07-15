---
claim_id: ECV2-COMPILER-ARTIFACTS
status: planned
depends_on: [ECV2-WORKLOADS]
---

# Produce exact formatter artifacts during compilation

## Task

Turn the module-linter probe into a pure Lean compiler plugin that runs rules over the exact syntax
while Lean already owns the correct environment and emits a compact, sound sidecar.

## Read

- `experiments/pure-lean-core/LeanFmtProbePlugin.lean` and its recorded timings.
- Lean `Command.ModuleLinter`, plugin loading, file maps, module setup, and Lake build traces.

## Target

- Private Lean modules for syntax projection, rules, conservative edits, diagnostics, and artifact IO.
- Artifact identity covers source content, exact toolchain/compiler, plugin/rule version, configuration,
  validation level, ordered imports/search roots, and relevant build trace.
- Atomic writes; corrupt, missing, partial, or stale artifacts are normal misses.
- The plugin computes results in-process and does not serialize the whole syntax tree by default.

## Stop

Do not trust source mtimes, omit plugin identity from the build trace, or let an artifact claim a
validation level it did not execute.

## Check

- Differentially compare plugin results with the ECV2-WORKLOADS oracle.
- Test custom syntax, file-local syntax, corruption, interrupted writes, and every identity field.
- Measure plugin overhead and artifact size on the fixed sample.
- `lake build`
- `git diff --check`
