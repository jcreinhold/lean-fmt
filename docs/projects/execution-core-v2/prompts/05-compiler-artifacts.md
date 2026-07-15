---
claim_id: ECV2-COMPILER-ARTIFACTS
status: planned
depends_on: [ECV2-WORKLOADS]
---

# Produce exact formatter artifacts through the module system

## Task

Use Lean's module system and Lake's module build graph to retain compact formatter results from the
exact compilation. The build that owns dependency resolution, plugin loading, compiler success, and
trace identity must also own publication; no external caller reconstructs that association.

## Read

- `experiments/pure-lean-core/LeanFmtProbePlugin.lean` and its recorded timings.
- Lean `Command.ModuleLinter`, `ModuleEnvExtension`, `.ilean`, module-data serialization, plugin
  loading, file maps, module setup, and Lake module facets/build traces.

## Target

- Every production Lean file participates in the Lean module system. The root exports no application
  API; internal reach uses deliberate module visibility rather than namespace convention alone.
- Compare three substantively different representations before choosing one:
  1. ordinary `.ilean` data, if it already retains sufficient exact syntax information;
  2. one compact `ModuleEnvExtension` value persisted in `.olean`, if it can be read without loading
     the transitive frontend environment; and
  3. a compact sidecar declared and validated as a Lake module facet output.
- Prefer existing `.ilean`; otherwise prefer persistent module data only if its measured read path is
  cheap and uses supported APIs. Otherwise choose the Lake facet.
- Private Lean modules own syntax projection, rules, conservative edits, diagnostics, and artifact
  representation. The chosen module/build owner supplies identity from its actual source, toolchain,
  plugin/configuration, options, imports, and dependency trace.
- Missing, corrupt, partial, stale, or unavailable module artifacts are normal misses.
- The plugin computes results in-process and does not serialize the whole syntax tree by default.

## Stop

Do not trust source mtimes, parse a Lake-shaped JSON object as proof of build validity, use opaque
entry casts, or let an artifact claim validation it did not execute. Do not expose a temporal API
that independently accepts a candidate path, setup path, plugin path, and exit code. If supported
module APIs cannot provide cheap extraction, select the Lake facet instead of bypassing them.

## Check

- Differentially compare plugin results with the ECV2-WORKLOADS oracle.
- Test custom syntax, file-local syntax, corruption, interrupted writes, and every identity field.
- Prove compiler failure cannot publish the module artifact and plugin/configuration changes
  invalidate the owning Lake job through its real trace semantics.
- Measure plugin overhead and artifact size on the fixed sample.
- `lake build`
- `git diff --check`
