# ECV2-COMPILER-ARTIFACTS result

Status: verified on 2026-07-15 after local gates and an independent post-design audit with no
P0, P1, or P2 findings.

## Selected design

The exact compiler callback stores one silent formatter record in Lean 4.32's built-in persistent
lint log. Lean itself transfers that record into the `.olean` only after error-free elaboration.
The private `leanFmtArtifact` facet then owns a supported import/extraction action and a compact
content-addressed sidecar. It returns a `Lake.Artifact` descriptor, not an independently trusted
path; the descriptor is consumed only inside the future private Lake-fetch operation because its
public type is not unforgeable authority.

The application-side reader recomputes the returned artifact's content hash and checks its schema,
module, full source digest, and source byte count. Missing, corrupt, partial, stale, or mismatched
artifacts are ordinary misses. Frontend failure cannot produce the persistent entry. A later code-generation failure may
leave an unaccepted `.olean`, but the failed `leanArts` job prevents the facet from publishing it.

## Why this boundary

- `.ilean` does not retain exact command syntax and ranges.
- A custom `ModuleEnvExtension` cannot be transparently populated from a state-restored module
  linter, and raw opaque-entry casts are unsupported.
- Lean's existing persistent lint log was specifically designed to retain compiler linter results
  in `.olean`; using it defines compiler-success association rather than reconstructing it.
- The facet action—not a later promoter—imports that exact module and creates its own declared,
  atomic output. Lake traces the `.olean`, extractor executable, and sidecar together, and an
  isolated-cache test proves deletion restores the declared JSON artifact without extraction.
- Exact-path binding is exercised against a same-named shadow module earlier on `LEAN_PATH`;
  plugin binary and rule-configuration changes both invalidate the real owning module trace.

## Evidence and remaining cost

See [the Prompt 05 gate](../evidence/05-module-system-gate.md). The frozen 62-file sample matched the
independent exact-context oracle for every command projection. Mean plugin overhead was 0.375 ms;
mean supported extraction was 791.638 ms; sidecars averaged 3.45 KiB; peak aggregate RSS was
2,157,936 KiB with normal pressure and no swap growth.

The ownership design is sound. Per-module extraction startup is not yet acceptable as an assumed
mathlib-scale path: its measured serial projection is roughly 116 minutes before scheduling
overhead. Prompt 06 must compare at least a batched supported extractor and direct facet consumption,
while preserving bounded environments and the same private Lake-owned fetch-and-validate boundary.
The publicly constructible `Lake.Artifact` remains a descriptor, not a capability or authority.
