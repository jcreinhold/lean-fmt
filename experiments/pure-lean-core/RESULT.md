# Pure Lean feasibility result

Status: feasible for a toolchain-matched executable, with launcher and API-coupling constraints.

Nothing in this directory is production architecture.

## Environment

- Host: macOS arm64.
- Target workspace: `/Users/jcreinhold/Code/mathlib4`.
- Target pin: `leanprover/lean4:v4.32.0`.
- Prototype pin: the same `leanprover/lean4:v4.32.0`.
- Every Lean and Lake command below used `LEAN_NUM_THREADS=1`.

## Build

From `experiments/pure-lean-core`:

```sh
LEAN_NUM_THREADS=1 lake build
```

Result:

```text
Built Main
Built Main:c.o
Built «pure-lean-core»:exe
Build completed successfully
```

The executable imports Lake directly, uses `supportInterpreter := true`, and links Lake with
`weakLinkArgs := #["-lLake"]`. No Rust launcher or Rust code participates.

## Workspace and file discovery

The executable parses two CLI arguments itself: a Lake workspace root and one Lean source path. It
uses `Lake.findInstall?`, `Lake.Env.compute`, and `Lake.loadWorkspace` to evaluate the target's Lake
configuration and manifest. On mathlib it observed:

```text
lean=4.32.0
target_toolchain=leanprover/lean4:v4.32.0
workspace=/Users/jcreinhold/Code/mathlib4 packages=9
lean_path_entries=10 discovered_lean_files=8795
```

The ten frontend search entries are the nine target workspace package library directories plus the
active Lean installation's `lib/lean`. The prototype deliberately does not use
`Workspace.augmentedLeanPath`: when launched with `lake exe`, that value also inherits the
prototype package's own `LEAN_PATH`, which is not part of the target workspace. Instead it uses
`workspace.leanPath ++ [workspace.lakeEnv.lean.leanLibDir]`.

File discovery is Lean-native (`FilePath.walkDir`) and excludes `.lake`. This demonstrates that no
Rust walker is required, but it is intentionally only a feasibility walker: a production tool would
need to obtain source roots/globs from Lake targets rather than assume every `.lean` file below the
root belongs to a selected library.

## Full frontend processing

Command:

```sh
LEAN_NUM_THREADS=1 lake exe pure-lean-core \
  /Users/jcreinhold/Code/mathlib4 \
  /Users/jcreinhold/Code/mathlib4/Mathlib/Algebra/CharZero/Infinite.lean
```

Observed result:

```text
frontend=ok imported_modules=2037 local_declarations=1 elapsed_ms=673
```

This is `Lean.Elab.runFrontend` over the complete file contents read into a `String`, not a header
scan or parser-only approximation. The local declaration count confirms that the file's command was
elaborated after its imports were loaded.

A second file exercises imported custom command syntax:

```sh
LEAN_NUM_THREADS=1 lake exe pure-lean-core \
  /Users/jcreinhold/Code/mathlib4 \
  /Users/jcreinhold/Code/mathlib4/Mathlib/Data/Finset/Attr.lean
```

Observed result:

```text
frontend=ok imported_modules=1318 local_declarations=1 elapsed_ms=467
```

`Mathlib/Data/Finset/Attr.lean` executes `declare_aesop_rule_sets`, so this also demonstrates that
the full frontend loads extension initializers and processes non-core command syntax.

## Toolchain behavior

Toolchain selection happens before a native Lean executable starts. The prototype reads the
target's `lean-toolchain` and rejects a version mismatch, but it cannot replace its already-loaded
Lean runtime in-process.

Using Lake's `-d` flag from the lean-fmt checkout did **not** select the target pin:

```sh
LEAN_NUM_THREADS=1 lake -d /Users/jcreinhold/Code/mathlib4 env lean --version
```

produced Lean `4.32.0-rc1`, while changing the working directory first:

```sh
cd /Users/jcreinhold/Code/mathlib4
LEAN_NUM_THREADS=1 lake env lean --version
```

produced Lean `4.32.0`. Thus `lake -d` is not a safe target-toolchain launcher. Building/running
from a package carrying the target pin, changing to the target directory before invoking Lake, or
an explicit `elan run <target-pin> ...` is required.

## Standalone launch investigation

Invoking the built binary directly from the repository root, without Lake's environment, failed:

```text
uncaught exception: could not locate the active Lake installation
```

Supplying only `LEAN_SYSROOT`, `LAKE_HOME`, and `ELAN_TOOLCHAIN` let Lake load the workspace but
produced an incomplete core search path and `unknown module prefix 'Init'`. Supplying the matching
core `LEAN_PATH=<target-sysroot>/lib/lean` as well made the direct binary succeed.

Therefore workspace configuration and search-path computation are available entirely from Lean,
but a standalone native executable still needs a correctly selected toolchain installation and its
bootstrap environment. A pure Lean bootstrapper could spawn `elan run` itself, but that is still a
launcher/re-exec stage; it does not remove the requirement that the frontend process start under
the target ABI.

## Other blockers and caveats

- `Lean.Elab.runFrontend` requires `unsafe Lean.enableInitializersExecution` before imports with
  extensions are loaded. Omitting it produced the explicit frontend error
  ``enableInitializersExecution must be run before calling importModules (loadExts := true)``.
- The Lake workspace loader and frontend APIs are toolchain-version-coupled. This prototype builds
  against Lean/Lake 4.32.0; supporting other project pins means compiling or launching the matching
  executable for each pin.
- `Lake.loadWorkspace` may materialize dependencies when no usable manifest exists. The tested
  mathlib workspace already had a manifest, and the experiment did not modify it.
- The initial probe processed one file per process; the follow-up below tests sequential contexts.
  It does not establish cache behavior, formatting edits, or whole-mathlib throughput.
- Frontend diagnostics are emitted by Lean directly. A product protocol would need a stable
  structured projection instead of relying on console text.

## Conclusion

A pure Lean execution core is technically viable for CLI parsing, basic file discovery, target Lake
workspace loading, exact package search paths, and full frontend processing. It does not make
toolchain launch disappear: the native executable must already match the target Lean ABI and have
enough installation environment to locate Lake and core modules. The remaining design question is
whether that per-toolchain build/launch constraint and direct dependency on Lake/frontend internals
are preferable to a small external launcher.

## Follow-up batch and analysis measurements

The prototype was extended with a multi-file mode and a second executable that invokes the existing
selective analyzer. `run-batch-probe.sh` starts a new process group, samples the whole group's RSS,
and terminates it at 8 GiB. Raw metadata and output are retained under `results/`.

Loading distinct exact contexts sequentially is not viable: the full frontend crossed the hard
limit at 8,702,992 KiB while starting the sixth file in the 20-file slice. In contrast, a fresh full
frontend process for `Mathlib/Tactic.lean` peaked at 3,208,576 KiB, and importing the complete
`Mathlib.lean` umbrella peaked at 4,880,144 KiB. Process exit is therefore an effective reclamation
boundary; dropping an `Environment` is not.

Fresh selective analysis remained expensive: `Mathlib/Tactic.lean` took 1,310 ms and peaked at
3,259,440 KiB; `Mathlib/Data/List/Basic.lean` took 861 ms and peaked at 2,381,888 KiB. These are not
corpus statistics, but they rule out assuming that fresh sequential workers can meet a ten-minute
8,795-file run. The exact-context sharing and compiler-artifact alternatives require dedicated
experiments before production design resumes.

A deterministic sample selected every 137th sorted Lean source under `Mathlib`, `Archive`, and
`Counterexamples` (62 files were available under that selection) separated import cost from body
analysis. The pure Lean parent loaded Lake once and reexecuted one exact child at a time:

| Mode | Mean child time | Wall time | Peak aggregate RSS | Serial mathlib projection |
| --- | ---: | ---: | ---: | ---: |
| Header parse plus exact imports only | 667 ms | 47 s | 2,912,624 KiB | 97.8 min |
| Selective body analysis and projection | 920 ms | 62 s | 2,943,936 KiB | 134.9 min |

The import-only result is the relevant lower bound. Reaching ten minutes with the public fresh-import
primitive would require about ten concurrent children even if parsing, rules, and reporting were
free; the measured per-process footprint does not fit that concurrency inside 8 GiB. The bottleneck
is Lean environment construction, not Rust orchestration or process startup.

## Compiler plugin probe

`LeanFmtProbePlugin.lean` registers a pure Lean `ModuleLinter`. Loaded through the standard
`--plugin` option, it receives the exact frontend's final command syntax and file map while the
compiler already owns the correct environment. On `Mathlib/Data/Finset/Attr.lean` it emitted a
285-byte sidecar containing exact ranges for the module doc and custom Aesop command. Alternating
warm plain/plugin runs measured 0.69, 0.69, 0.69, and 0.72 seconds, so the probe added no detectable
overhead. `Mathlib/Data/List/Basic.lean` emitted a 20 KiB command-range artifact.

The probe proves that a pure Lean module linter can project top-level command syntax during ordinary
exact compilation without a second import. It does not yet prove byte-complete source coverage,
formatter rules, edits, failed-compilation behavior, or validation. It also does not make old build
artifacts sufficient: the plugin must participate in the module's build trace, and adding it to a
previously built project must cause a rebuild. Production design must choose and document that
integration contract rather than hiding the initial compilation cost behind a cache claim.

## Ordinary-built cold follow-up

The fixed 62-file sample was rerun with fresh children while timing header parsing,
`importModulesCore`, and `finalizeImport` separately. Module loading averaged 259.1 ms/file and
finalization averaged 438.1 ms/file; finalization was 62.8% of those two phases. The profiled wall
time was 49.197 seconds with 2,842,992 KiB peak aggregate RSS and zero swap growth.

After exact setup preflight, a sorted-prefix characterization completed 2,031 mathlib files before
being deliberately terminated once the conclusion was decisive. Loading plus finalization averaged
742.9 ms/file, projecting to 108.9 minutes; profiled wall projected to 120.9 minutes. There were no
file failures. Sampled aggregate RSS peaked at 6,797,232 KiB, pressure remained normal, and swap
delta was negative. `DownstreamTest/DownstreamTest.lean` alone spent 4,294 ms loading and 8,098 ms
finalizing its 10,406-module environment. This is retained as a terminated characterization, not a
complete mathlib benchmark; continuing could not make the fallback competitive and would have
wasted roughly another hour.

Across all 8,795 mathlib files there are 8,357 distinct ordered source-header contexts; 8,090 are
singletons, so header-equivalent reuse can eliminate at most 438 imports in this fixed Lake 4.32
workload. It is also not sufficient for same-process body processing: two committed files with
identical imports demonstrate that a command elaborator's process-global mutation leaks into the
next full frontend run, while the second file passes alone in a fresh process.

Lean's experimental header snapshot loads exact state substantially faster for a repeated header:
`Mathlib/Tactic.lean` loaded in 1.104 seconds at 1,312,912 KiB peak RSS. The image took 4.900 seconds
to create and occupied 150,145,927 bytes plus 1,750,928 bytes of dependency metadata. A smaller
custom-syntax file still produced a 42,558,687-byte image. Fresh and loaded compiler-plugin
projections were byte-identical in that setup-free case. The facility demonstrates the desired
mechanism on a tested input, but not general exactness or a scalable per-context representation; it
is also absent from an ordinary build and costs a cold import to create.

The checkout initially lacked current dependencies needed by support scripts. After building the
named project and script prerequisites, a batched `noBuild := true` Lake preflight obtained an exact
`ModuleSetup` for all 8,795 selected files in 394.199 seconds. It peaked at 1,434,896 KiB aggregate
RSS, remained at macOS pressure level 1, and had no positive swap delta. This establishes the
ordinary-built premise; it is setup validation time, not formatter time. The printed setup hash is
only a probe diagnostic and is not a semantic cache identity.
