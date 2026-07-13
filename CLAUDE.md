# lean-fmt

A Ruff-style formatter and linter for Lean 4. Rust owns the CLI UX, Lake project discovery, caching,
patching, reporting, and runtime packaging; Lean owns parsing and semantics through the real frontend,
exposed as a downstream `lean-rs-worker` capability that a Lean-linked worker child loads. The parent
and CLI crates never link `libleanshared`; they drive Lean by spawning the worker child as a subprocess.

## Read first

Before writing code, read this file and the topic doc that governs the area you are touching (the index
lives in [`README.md`](README.md); performance work is covered by [`docs/performance.md`](docs/performance.md)).

## Workspace shape

Seven published crates:

| Crate | Role |
| --- | --- |
| `lean-fmt-diagnostics` | Diagnostic and rule-report model: severity, codes, source-ranged findings. |
| `lean-fmt-edit` | Conservative, source-ranged text-edit and patch engine: conflict-checked, reversible. |
| `lean-fmt-runtime` | Package-owned Lean runtime payload, source digest, and capability build/install. |
| `lean-fmt-worker` | Worker-boundary runtime: locates and loads the installed `LeanFmt` capability per toolchain. Does **not** link `libleanshared`. |
| `lean-fmt-project` | Lake project discovery, file walking, and check/fix/diff orchestration over mixed files. |
| `lean-fmt-cli` | Command-line interface and the Lean-free `lean-fmt` parent binary. Spawns the worker child as a subprocess. |
| `lean-fmt-worker-child` | Lean-linking worker-child host and the `lean-fmt-worker-child` binary. The **only** artifact in the workspace that links `libleanshared`, via its lone `lean-rs-worker-child` dependency. |

Layering: `lean-fmt-edit` and `lean-fmt-runtime` are the leaves; `lean-fmt-diagnostics` builds on `edit`;
`lean-fmt-worker` builds on `edit` + `runtime`; `lean-fmt-project` builds on `diagnostics` + `edit` +
`worker`; `lean-fmt-cli` sits on top. Lean enters the workspace only through the `lean-rs-worker-*` crates
(crates.io), and only `lean-fmt-worker-child` links the shared library — every other crate stays Lean-free
and reaches the frontend across the process boundary.

## Build and verify

```sh
scripts/fmt.sh     # cargo fmt --all -- --check
scripts/lint.sh    # cargo clippy --workspace --all-targets -- -D warnings
scripts/test.sh    # cargo test --workspace
scripts/lean.sh    # lake -d lean build (the LeanFmt capability package)
```

CI runs the same commands on `ubuntu-latest`, stable Rust only.

## Discipline

- **`libleanshared` is linked in exactly one crate: `lean-fmt-worker-child`.** No other crate may depend
  on `lean-rs-worker-child` or add a `libleanshared` link directive. The CLI/parent crates stay Lean-free
  and spawn the child as a subprocess; new Lean-runtime reach goes through `lean-fmt-worker`. The edit-time
  guard is `.claude/hooks/lean-boundary-guard.sh`.
- **`unsafe-code = "deny"` at workspace level, with no opt-out crate.** lean-fmt declares no raw Lean FFI.
  Any new `unsafe` needs a `// SAFETY:` comment naming the invariant and reviewer sign-off; never reopen
  it with `allow(unsafe_code)`.
- **No `unwrap()`, `expect()`, `panic!`, `unreachable!()`, or direct indexing/slicing** in non-test code.
  Test modules opt out locally with `#![allow(...)]`.
- **No `TODO`, `unimplemented!()`, `todo!()`.** Build the intended functionality or stop.
- **The edit engine stays conservative.** Patches are conflict-checked and reversible; the re-check gate is
  bypassed only through the explicit `--unsafe-no-validate` flag, and the patch conflict check runs
  regardless (`crates/lean-fmt-cli/src/lib.rs:273-286`).
- **Fix bugs at their root.** If the cause lives in a different crate, fix it there.
- **Update the relevant doc** in the same change when its design shifts.

## When this file is wrong

This file should drift slowly. If a session reveals something here is stale, fix it in the same change.
The same rule applies to the docs and contract claims.
