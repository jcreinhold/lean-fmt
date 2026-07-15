# Next Proof Packet

- Stack: execution-core-v2
- First unresolved: 05-compiler-artifacts
- Claim ID: ECV2-COMPILER-ARTIFACTS
- Prompt: 05-compiler-artifacts
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Use Lean's module system and Lake's module build graph to retain compact formatter results from the exact compilation. The build that owns dependency resolution, plugin loading, compiler success, and trace identity must also own publication; no external caller reconstructs that association.

## Reuse

- `experiments/pure-lean-core/LeanFmtProbePlugin.lean` and its recorded timings.
- Lean `Command.ModuleLinter`, `ModuleEnvExtension`, `.ilean`, module-data serialization, plugin loading, file maps, module setup, and Lake module facets/build traces.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not trust source mtimes, parse a Lake-shaped JSON object as proof of build validity, use opaque entry casts, or let an artifact claim validation it did not execute. Do not expose a temporal API that independently accepts a candidate path, setup path, plugin path, and exit code. If supported module APIs cannot provide cheap extraction, select the Lake facet instead of bypassing them.
