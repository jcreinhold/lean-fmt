# Ordinary-built cold API audit

## Outcome

Lean 4.32 does not expose a sound, memory-bounded way to reuse one imported environment across
arbitrary source files. The best current pure-Lean fallback is therefore a fresh exact frontend
process per file. Process exit is the correct reclamation boundary, and the measured sample stayed
inside the envelope, but a full-corpus maximum is not yet evidence. The fallback is already far
above the ten-minute mathlib goal. The production design must keep it honest and prefer
compiler-produced semantic artifacts when present; it must not disguise a union environment or
same-process batch as exact.

The missing facility is not a Rust scheduler. It is a Lean-internal lazy/compact exact environment
representation that avoids rebuilding large constant and persistent-extension indexes from `.olean`
module data. A fresh-process-loadable header image is one possible mechanism only if ordinary
compilation already produced it. Lean's experimental incremental header snapshot demonstrates part
of that mechanism on tested inputs, but its current representation is too large to use once per
mathlib import context and does not establish general exactness.

## What the import path actually costs

The self-contained pure-Lean probe now measures `Parser.parseHeader`, `importModulesCore`, and
`finalizeImport` separately in a fresh child. It deliberately omits Lake `ModuleSetup`, making it a
lower bound on the exact fallback rather than the differential oracle. On the fixed 62-file sample:

| Phase | Sum | Mean/file | Share of load + finalize |
| --- | ---: | ---: | ---: |
| Header parse | below 1 ms timer resolution | below 1 ms | — |
| Load module closures and compacted regions | 16,066 ms | 259.1 ms | 37.2% |
| Build exact constants/extensions and run import initialization | 27,163 ms | 438.1 ms | 62.8% |
| Profiled process-per-file wall | 49,197 ms | 793.5 ms | — |

Peak aggregate RSS was 2,842,992 KiB, the sampled memorystatus pressure level stayed normal (`1`),
and swap growth was zero. The
first complete-corpus attempt failed its built-artifact preflight and is retained only as failed
evidence. After the exact Lake setup preflight passed all 8,795 files, the corrected full lower-bound
run remained pending. The sample projects to 116.3 minutes. This is an import-only lower bound: body
parsing, rules, validation, and reporting can only add work.

## Alternatives measured

### Fresh exact child

The setup-aware fresh child is the correctness and reclamation baseline. It gives each file a newly
initialized runtime, current Lake `ModuleSetup`, exact ordered imports, and a process exit that safely
releases compacted regions and arbitrary metaprogram state. It is the only generally exact path
available without compiler integration. The cheaper setup-free import measurement already cannot
reach ten minutes under the 8 GiB envelope.

### Exact-context grouping

A full-corpus pure-Lean header pass found 8,357 distinct ordered `ModuleHeader` contexts among 8,795
files. Of those, 8,090 are singletons. In Lean/Lake 4.32, each `setupServerModule` path used by the
frozen workload leaves `ModuleSetup.imports?` as `none`; other setup fields can therefore split but
cannot merge these source-header groups. Reusing one import per identical exact context could
eliminate at most 438 imports (4.98%); the largest header group contains 58 files. This is an upper
bound for this workload, not a generic claim about arbitrary `ModuleSetup` values, whose `imports?`
field can override source imports. Header discovery itself took 3,222 ms, 4,854 ms profiled wall,
and 709,552 KiB peak RSS.

Even that upper bound is not generally sound for full frontend runs whose bodies share a process.
The committed adversarial
fixture imports the same module in two files. The first file invokes a command elaborator that sets
an imported process-global `IO.Ref`; the second asserts the reference is clean. The second file
succeeds in a fresh Lean process and fails after the first file in a shared process. Lean command
elaborators are arbitrary programs, so identical import environments do not imply isolated runtime
state. This fixture rejects same-process body processing; it does not by itself prove that a
read-only imported base could never be shared across isolated runtimes.

The current-tree control was rerun after the fixture was committed. A fresh invocation of
`lake env lean fixtures/B_Observe.lean` exited `0`. One invocation of `pure-lean-core` over
`A_Poison.lean` followed by `B_Observe.lean` exited `1`; the first frontend completed and the second
reported `formatter reuse leaked process-global command state`. This is a differential isolation
test, not an inference from the implementation.

### Parser-only or selective processing

Header parsing is negligible; constructing the imported parser and command environment is not.
Imported syntax, macros, command elaborators, attributes, and persistent extensions live in the
environment assembled by import finalization. File-local commands may introduce syntax needed by
later commands, and arbitrary command elaborators may mutate global state. Lean 4.32 has no public
API that constructs a parser-only exact environment from `ModuleData`, nor a sound general test for
which commands may be skipped. A selective path remains a candidate optimization only after it
byte-compares with the fresh full frontend and sends unsupported files to the exact fallback.

### Shared module regions and environment views

`ImportState` owns a private module-name map and an ordered module array. `importModulesCore` only
adds modules or raises their effective import level. `finalizeImport` then traverses every selected
module to build flat constant maps, module indexes, extension arrays, server data, persistent
extension state, and initializer effects. It cannot finalize an exact subset view from a previously
loaded superset.

`Environment.freeRegions` is explicitly unsafe: no environment-derived or initializer-cached object
may remain, and Lean's own server documentation says safe manual reclamation is effectively
impossible. It is not an implementation option. A union environment is also rejected because extra
constants, parser extensions, macros, attributes, and name resolution change semantics.

### Existing compiler and incremental artifacts

Normal `.olean` files contain declarations and persistent extension entries; `.ilean` files contain
editor/reference data. Neither contains the source command syntax needed by formatter rules.
`.setup.json` identifies exact import artifacts but does not contain a finalized environment.

Lean's `--incr-header-save` and `--incr-load` preserve a post-import snapshot for the setup supplied
to that frontend. The measurements below used the setup-free CLI path, so they establish mechanism
and one lower-level differential, not the exact Lake project oracle or general initializer-safe
reuse:

| Source | Create wall | Fresh load wall | Load peak RSS | Snapshot | Dependency metadata |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Mathlib/Tactic.lean` | 4,900 ms | 1,104 ms | 1,312,912 KiB | 150,145,927 B | 1,750,928 B |
| `Mathlib/Data/Finset/Attr.lean` | not separately profiled | — | — | 42,558,687 B | 556,291 B |

Fresh and snapshot-loaded setup-free plugin projections for `Mathlib/Data/Finset/Attr.lean` were
byte-identical (SHA-256
`9a858f93b87b615964eca5fb149b453fe8a4a68442e8471be7bf461c2d74e984`), including its custom Aesop
command. This demonstrates the desired semantic shape for that tested case. It does not cover Lake
plugins, dynamic libraries, import overrides, options, package identity, arbitrary initializers, or
in-place dependency replacement. The snapshot is not present in an ordinary build, costs the cold
import it is meant to avoid, and duplicates tens to hundreds of MiB per source context. At 8,357
header contexts it cannot be the lean-fmt corpus cache in its current format.

## Upstream boundary designed twice

Three boundaries were compared before choosing what, if anything, should become public.

### A. Public `ImportState` / reusable `ModuleStore`

This would load module closures once and expose `realizeExact(imports)` to construct subset
environments. It could remove repeated mappings and enable new import experiments, but it exposes
effective-level and region-lifetime concepts to callers, still pays most finalization cost, and
cannot isolate arbitrary process-global command or initializer state. It is a useful Lean-internal
refactor, not a sufficient lean-fmt capability.

### B. Compact fresh-process `HeaderImage`

This could move the entire import/finalization result behind one immutable artifact while a fresh
process remains the isolation boundary. The existing snapshot demonstrates a mechanism on tested
inputs, but not the proposed compact representation or general exactness. More importantly, an
image created only after lean-fmt pays a cold import cannot improve the first ordinary-built,
cache-cold run. It helps that workload only if normal compilation already emits the image or Lean
can derive a compact lazy view from ordinary artifacts without paying `finalizeImport` first.

The first interface sketch exposed `InitialSnapshot` and `unsafe`, required callers to sequence
capture and load, and could not derive complete `ModuleSetup` identity while writing. That boundary
was shallow and is rejected. A future image belongs inside Lean's existing frontend/import boundary;
application callers should never receive it.

### C. Standard compiler syntax/result artifact

Persisting syntax or formatter projections while the compiler already owns the exact frontend is
smaller and faster than a header image. It is the preferred lean-fmt product path and prompt 05 owns
it. It does not improve a checkout built without that artifact, so it cannot by itself implement the
ordinary-built cold fallback. The current probe establishes command-range feasibility only; prompt
05 must still prove source fidelity, failed-compilation behavior, identity, and atomicity.

## Smallest honest upstream facility

No new public Lean lifecycle API is justified by this evidence. The deepest boundary is the existing
exact frontend operation: it receives source plus `ModuleSetup` and either processes that source or
reports diagnostics. Lean should change the representation behind that boundary so callers do not
learn about import stores, image identities, compacted regions, initializer replay, or snapshots.
The smallest application-facing contract remains equivalent to:

```lean
-- Conceptual contract; existing Lean shell/language APIs own the concrete types.
processExactSource (source : String) (setup : Lean.ModuleSetup) : IO FrontendResult
```

This is a contract sketch, not a claim that `FrontendResult` is a current Lean declaration. The
concrete integration should extend the existing shell/language processor rather than publish a new
`HeaderImage` type. If Lean uses an image internally, a missing, stale, or corrupt image is an
ordinary internal miss followed by the normal exact import. I/O failures that prevent the normal
path remain reportable infrastructure failures.

Any internal image or lazy environment representation must satisfy these invariants:

- imported `.olean` regions remain separate shared mappings and are named by content identity;
- constant lookup and persistent extension state use compact/lazy indexes instead of serializing
  the fully materialized flat environment maps into every header image;
- identity covers exact ordered headers/imports and modifiers, module-system level, ordered artifact
  paths **and their content identity**, toolchain and executable ABI, options, trust level, dynamic
  libraries, plugins, package/module identity, and schema;
- module order and effective import level are preserved exactly as `importModulesCore` computes
  them; a superset store may share bytes but never becomes the visible environment;
- source-body state, file maps, cancel tokens, and other input-specific objects are not shared merely
  because headers match;
- the frontend-owned prepared state owns every mapped region for its full lifetime; no caller sees
  `unsafe` region loading or manually frees regions;
- dynamic libraries, plugins, and regular initializers run or replay in Lean's required order in a
  pristine process. Arbitrary initializer behavior is not generally classifiable, so an
  “unsupported initializer” miss cannot be promised without a concrete detection mechanism;
- arbitrary body-command/runtime state remains isolated by process exit. An in-process
  “initializer scope” cannot reset user-created `IO.Ref`s or foreign side effects; and
- corruption, missing dependency regions, and identity mismatch produce a normal fallback, never a
  partially prepared environment.

The existing incremental snapshot implementation is compiling mechanism evidence for the tested
custom-syntax case. It does not prove these invariants, the compact representation, or usefulness on
the first ordinary-built/cache-cold run. The required upstream work is therefore a substantial Lean
environment-representation change, not a small wrapper around `ImportState` or `InitialSnapshot`.

## Design consequence

Prompt 06 should design around two honest capabilities: trusted compiler-side semantic artifacts,
and a slow fresh-process exact fallback. A future Lean-internal compact environment can replace the
fallback's import mechanism without changing application callers, but it is not part of the current
ordinary-built result. Same-process body batching, superset pinning, unsafe region release, and
public worker controls remain excluded.
