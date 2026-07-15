# ECV2-RESET evidence

Captured 2026-07-15 on the current macOS development machine.

## Revision evidence

```text
$ git rev-parse HEAD
0f1f1561b9c7974dd802de70c45cb31b01660f43
$ git rev-parse codex/archive-execution-core-attempt
629d157694c9cbaa4dae29323db4711b9004ee39
```

`git show --stat codex/archive-execution-core-attempt` reports 30 archived paths, 1,304 insertions,
and 688 deletions.

## Workspace and boundary

```text
$ cargo metadata --no-deps --format-version 1 | <package/target projection>
lean-fmt               bin
lean-fmt-worker-child  bin,custom-build

$ cargo tree --workspace -i lean-rs-worker-child
lean-rs-worker-child v0.3.1 (.../lean-rs-worker-child)
└── lean-fmt-worker-child v0.1.0 (.../lean-fmt-worker-child)

$ scripts/check-boundary.sh
# exit 0, no output
```

The metadata contains no library target. The inverse dependency tree contains exactly the worker
child package below the Lean-linking runtime.

## Build gates

```text
$ cargo check --workspace
Finished `dev` profile ...

$ LEAN_NUM_THREADS=1 scripts/lean.sh
Built LeanFmt.Frontend
Built LeanFmt
Built LeanFmt:shared
Build completed successfully

$ scripts/fmt.sh
Finished successfully

$ scripts/lint.sh
Finished successfully with `-D warnings`

$ scripts/test.sh
lean-fmt: 0 passed, 0 failed
lean-fmt-worker-child: 0 passed, 0 failed
scripts/check-boundary.sh: exit 0

$ git diff --check
# exit 0, no output
```

The zero-test count is expected for the reset skeleton; ECV2-ORACLE establishes behavioral fixtures
before the application vertical slice is implemented.

