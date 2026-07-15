# Architecture pause

On 2026-07-15 the execution-core v2 roadmap was paused before application orchestration began.

The reset remains useful: it archived the failed 60 GiB attempt and removed legacy production
layers. The architectural conclusions attached to that reset do not. The stack selected two
binaries, a Rust `RunEngine`, a Rust `LeanRun`, a custom child protocol, and a Rust-owned cache
before comparing those decisions with Lean-native facilities.

Inspection of mathlib's exact Lean v4.32.0 toolchain immediately found material untested
capabilities:

- Lake caches exact `Array Import` environments;
- Lean persists and reloads post-import frontend snapshots;
- the language processor supports incremental command snapshots;
- import loading is split into `ImportState`, `importModulesCore`, and `finalizeImport`;
- compacted import regions expose size/mapping facts and explicit release with strict lifetimes;
- the runtime exposes memory, task, snapshot, and import-worker controls; and
- a Lean executable or Lake facet can run inside the target project's exact toolchain.

Conversely, current assumptions are unproved: dropping a loaded environment may not reclaim its
mapped regions; selective elaboration does not cover arbitrary syntax-affecting commands; a
child-reported identity cannot establish a worker-free cache hit; and a custom linked child makes
toolchain compatibility a packaging problem rather than defining it away.

The new presumption is pure Lean. An external launcher survives only for a specific capability Lean
lacks or a measured end-to-end advantage. Experimental work lives under `experiments/` and cannot
become production by accretion. Prompts 03–11 are suspended until ECV2-ORACLE produces a replacement
roadmap.

## First measurements

The pure Lean prototype loads mathlib's Lake workspace, computes its ten-entry exact search path,
discovers all 8,795 source files, and runs the full frontend successfully on both ordinary and
custom-syntax files. Toolchain selection must happen before the executable starts; `lake -d` does
not provide that guarantee, while running under the target directory or an explicit `elan run`
does.

All measurements below used a prebuilt v4.32.0 Lean executable, `LEAN_NUM_THREADS=1`, mathlib commit
`783ccda4ee524f13cc5636237be0a1942bc04824`, a process-group RSS monitor, an 8 GiB hard stop, and
unchanged swap:

| Probe | Frontend time | Peak aggregate RSS | Result |
| --- | ---: | ---: | --- |
| Full frontend, `Mathlib/Tactic.lean`, fresh process | 5.127 s | 3,208,576 KiB | success |
| Selective analysis, `Mathlib/Tactic.lean`, fresh process | 1.310 s | 3,259,440 KiB | success |
| Selective analysis, `Mathlib/Data/List/Basic.lean`, fresh process | 0.861 s | 2,381,888 KiB | success |
| Full frontend, `Mathlib.lean`, fresh process | 9.407 s | 4,880,144 KiB | success |
| Six different exact files, one process | 13 s before stop | 8,702,992 KiB | killed during file 6 |
| 62-file uniform sample, exact imports only | 0.667 s/file mean | 2,912,624 KiB | 47 s wall |
| 62-file uniform sample, selective analysis | 0.920 s/file mean | 2,943,936 KiB | 62 s wall |

The last result rules out the original prepared single-session design. Lean's own language server
documents the same invariant: imports are loaded at most once per file-worker process; a header
change exits the worker so the watchdog can reclaim them. That watchdog and its children are
implemented in Lean, so reclamation and crash isolation do not justify a Rust supervisor.

Fresh exact processes are safe but the measured cost is far above the 68 ms/file average implied by
the ten-minute mathlib target. The uniform sample projects to about 98 minutes serial for header
parsing and imports alone, before body parsing, rules, or reporting. Meeting ten minutes through
parallel fresh processes would require roughly ten-way concurrency, while a single sampled process
already approaches 3 GiB RSS. Rust cannot schedule away that mismatch.

The central missing facility is a way to load compacted module data
once while constructing logically exact environments from subsets. Lean 4.32's public
`ImportState` API cannot do that: its module map is private, `importModulesCore` only grows it, and
`finalizeImport` finalizes the entire accumulated state. Parsing against that union would be the
same unsound superset semantics the reset rejected. Even a subset-environment API would need an
answer for import initializers whose process-global effects can accumulate.

Two viable directions remain to measure before architecture selection:

1. a pure Lean watchdog with short-lived, exact children and memory-aware bounded concurrency; and
2. producing formatter syntax artifacts during Lean's existing exact compilation, through compiler
   or Lake integration, so `check` does not reload imports at all.

The first must demonstrate enough concurrency inside 8 GiB to reach the target. The second must
state honestly that compiler-produced artifacts are semantic cache inputs and define behavior when
they are absent or stale. An upstream Lean facility for shared module regions plus isolated exact
environment construction is a third, longer-term option, not an API lean-fmt can assume today.

Lean's plugin API makes the compiler-integrated direction concrete: module linters are explicitly
designed to be loaded as plugins and receive the exact frontend's complete `Array Syntax` at the end
of a module. A formatter plugin can therefore compute or persist findings while the compiler already
owns the exact environment. What is not available today is retroactively obtaining that syntax from
ordinary `.olean`/`.ilean` artifacts; absent a lean-fmt artifact, an exact standalone check must pay
the import cost again. The next experiment must measure plugin-produced sidecars and their build,
size, invalidation, and read costs.

## Compiler-plugin feasibility

A pure Lean dynamic plugin under `experiments/pure-lean-core` registered a `ModuleLinter` and was
loaded by mathlib's ordinary `lean` frontend with `--plugin`. The linter received the final exact
`Array Syntax`, the file map, and the source name. On `Mathlib/Data/Finset/Attr.lean` it captured both
the module doc and the imported custom `Aesop.Frontend.Parser.declareRuleSets` command. Its 285-byte
probe artifact preserved source identity, source hash, command kinds, and exact byte ranges.

Two warm runs with and without the probe were 0.69–0.72 seconds, with no measurable probe overhead
at this resolution. `Mathlib/Data/List/Basic.lean` produced a 20 KiB command-range artifact during a
2.72-second normal full frontend run. A production plugin should run formatter rules over the exact
syntax in-process and persist only identity, diagnostics, and validated edits; it need not serialize
the syntax tree.

This establishes a preferred core, but not yet a complete product path. The plugin must be included
in the compilation trace so adding or changing it correctly rebuilds affected modules. Existing
ordinary `.olean` and `.ilean` files do not contain its results, so a checkout that has never built
with the plugin cannot acquire exact findings in under ten minutes using current Lean imports. The
remaining design question is whether lean-fmt is an opt-in compiler/Lake integration with a fast
artifact reader, or whether the product requires an upstream Lean syntax-artifact facility before
claiming transparent cold standalone performance.
