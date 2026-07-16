# Exact `check` vertical slice

Date: 2026-07-16

## User boundary

`lean-fmt check` is the first complete product operation. Its request contains only root, selected
files, report format, and a memory envelope. One private `execute` function owns workspace loading,
module selection, immutable source snapshots, trusted artifact lookup, exact fallback, deterministic
aggregation, and cleanup. The only application declaration exported from its module is `runCli`, the
binary entry point.

The CLI accepts:

```text
lean-fmt check [--root PATH] [--json] [--max-memory GIB] [FILE...]
```

Exit `0` means clean, exit `1` means findings or broken source, and exit `2` means infrastructure
failure. A syntax or import error is a file result. Failure to resolve the workspace, execute the
frontend, or stay inside the resource envelope is infrastructure failure. Per-file infrastructure
failures are aggregated; one failure does not omit later selected files.

## Exact target context

Workspace loading resolves `lean --print-prefix` with the target root as its working directory. This
lets the Elan shim select that root's toolchain without changing process-global state. The running
binary rejects a target whose declared Lean version or resolved Git hash differs from the version and
revision it was built against. Lake is derived from that exact co-located Lean installation.

The fallback child receives the workspace's complete augmented environment: ordered Lean search
path, source path, shared-library path, binary path, toolchain identity, and cache settings. It uses
the target module's `ModuleSetup` when Lake can produce one without building. Broken headers fall
back to the module's package/name/options plus the real source header so Lean can report the actual
syntax or unresolved import rather than an orchestration error.

The child runs `Lean.Language.Lean.process`, waits for sequential command processing, and projects
the same nonterminal syntax snapshots and rules as the compiler plugin. No environment, parser state,
or syntax extension survives process exit. A direct custom-syntax differential test proves the
compiler-integrated and fallback envelopes are equal.

## Artifact path

A current module `.olean` is a prerequisite for artifact use. The private Lake job binds that
artifact and the current application to a derived JSON file, then `readFacet?` checks schema, module,
source length, source digest, rules, and payload shape against the held source snapshot. Missing,
stale, corrupt, or absent compiler data is an ordinary miss and selects exact fallback.

This vertical slice deliberately does not call the derived artifact a product result cache. Prompt
08 adds the strategy-independent semantic cache and its worker-free fast path.

## Memory and process ownership

The ordinary fallback starts exactly one child with `LEAN_NUM_THREADS=1` and Lean's allocator limit
set to the requested envelope. The parent samples its own RSS plus the child's process group every
50 ms. It terminates the child and reports infrastructure failure when their aggregate exceeds the
envelope. A preflight rejects an envelope already consumed by the parent.

Running through `lake env` was measured and rejected for product use: it retained another Lean/Lake
process and roughly doubled the one-file sampled process tree. Native target discovery reduced the
artifact-hit sample from 1,303,120 KiB to 648,272 KiB. The current envelope is proven for exact
fallback, not yet for every Lake-owned artifact operation or a whole project. Prompt 10 remains
responsible for the aggregate whole-run guarantee.

## Module boundaries

Every compiled source begins with Lean 4.32's `module` command. `LeanFmtCore` owns the small semantic
model and rules, `LeanFmtApplication` owns analysis and execution, and `LeanFmtCompilerPlugin` owns the
compiler integration. The plugin shared library deliberately bundles the semantic core from the same
sources so it is self-contained; application changes do not invalidate formatter-integrated target
modules. The root `LeanFmt` module exports no application API.

No full-mathlib run was used for this prompt. The fixture differential, failure matrix, direct-process
profile, and memory cutoff answer the vertical-slice questions without spending the release-scale
acceptance budget.
