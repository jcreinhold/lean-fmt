# lean-fmt

A native Lean formatter and linter for Lean 4.

The first end-to-end command checks selected modules without writing their sources:

```sh
lake build
.lake/build/bin/lean-fmt check --root .
.lake/build/bin/lean-fmt check --root . --json LeanFmt/Basic.lean
.lake/build/bin/lean-fmt check --help
```

Exit `0` means every selected file is clean, exit `1` means the report contains findings or broken
Lean files, and exit `2` means an infrastructure failure prevented a trustworthy result. The
`--max-memory GIB` option sets the operating envelope for exact frontend fallback. `check` never
writes source files.

The active implementation uses Lean 4.32's module system throughout. A compiler plugin stores a
compact formatter result in each successfully built `.olean`; Lake owns its derived sidecar. When
that exact artifact is unavailable, the application runs the ordinary Lean frontend in a fresh,
memory-bounded child. Both paths produce the same semantic result before reporting. The CLI resolves
the target root's Lean and Lake installation itself, so normal use does not wrap the binary in a
second `lake env` process.

The application exposes no library API. Workspace discovery, source snapshots, artifact validation,
fallback, resource handling, and deterministic aggregation remain behind one private execution
operation. Design and performance evidence lives in `docs/projects/execution-core-v2/`; exploratory
code remains under `experiments/`.

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
tests/compiler/run.sh
tests/check/run.sh
```
