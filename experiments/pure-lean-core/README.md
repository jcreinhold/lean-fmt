# Pure Lean execution-core feasibility probe

This directory is a non-production experiment. It asks whether a Lean executable can:

1. parse its own command line and discover Lean files;
2. load another Lake workspace and obtain its augmented Lean search path without a Rust launcher;
3. run the real Lean frontend over complete source files under that workspace's toolchain.

It accepts multiple source paths only to measure sequential exact import environments in one
prebuilt process. That mode is a probe, not a proposed architecture.

The package is pinned to the toolchain used by the target mathlib checkout during the experiment.
All recorded commands set `LEAN_NUM_THREADS=1`.

Build and run from this directory:

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe pure-lean-core \
  ~/Code/mathlib4 \
  ~/Code/mathlib4/Mathlib/Tactic/Linter/DeprecatedModule.lean
```

See [RESULT.md](RESULT.md) for observed behavior and limitations.

`pure-lean-analyze` is the Lean-owned supervisor probe. It resolves the workspace once, then
reexecutes itself as a fresh exact child for every source. Set `PURE_LEAN_PROBE_MODE=import` when
using `run-batch-probe.sh` to measure header parsing and environment construction without body
analysis. Every probe is experimental and is hard-stopped by the script at 8 GiB aggregate RSS.

`header-groups` counts distinct ordered `ModuleHeader` contexts without importing them. The
`ExactReuseFixtures` pair demonstrates why identical imports do not make same-process file bodies
safe: a command elaborator can mutate process-global state that the next file observes.

`setup-audit` asks Lake for every selected file's exact `ModuleSetup` with `noBuild := true`. It
groups 16 requests per bounded Lake build context; a missing dependency stops with Lake's named
out-of-date module. The printed 64-bit setup hash is only a batched-versus-unbatched probe
diagnostic, not a cache or artifact identity.
