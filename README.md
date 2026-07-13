# lean-fmt

A Ruff-style formatter and linter for [Lean 4](https://leanprover.github.io/) Lake projects.

`lean-fmt` checks, formats, fixes, diffs, and serves editor requests for Lean source while **preserving comments** and
**verifying that edited files still parse** (and, when requested, still elaborate). It is conservative by default: it
applies only edits with explicit rule support.

## Design

The tool follows the `lean-rs` charter's ownership split:

- **Rust** owns CLI UX, project discovery, caching, patching, parallelism, reporting, editor/server integration,
  packaging, and release engineering. The parent binary is **Lean-free** — it never links `libleanshared`.
- **Lean** owns parsing with the real Lean frontend, import-dependent syntax, source-span classification, syntax-aware
  rules, and safe edit computation, packaged as a downstream `lean-rs-worker` capability loaded by a Lean-linked worker
  child.

Source positions are explicit, 1-based contracts; every generated edit is source-ranged, conflict-checked, and
reversible through a diff.

## Workspace layout

| Crate | Responsibility |
| --- | --- |
| `lean-fmt-cli` | Lean-free CLI entry point (`lean-fmt` binary). |
| `lean-fmt-project` | Lake project discovery, file walking, check/fix/diff orchestration. |
| `lean-fmt-worker` | Worker-boundary runtime: loads the installed `LeanFmt` capability per toolchain. |
| `lean-fmt-runtime` | Package-owned Lean runtime payload, source digest, capability build/install. |
| `lean-fmt-diagnostics` | Diagnostic/rule-report model (severity, codes, source-ranged findings). |
| `lean-fmt-edit` | Conservative, source-ranged, conflict-checked, reversible edit/patch engine. |

The Lean capability package lives under `lean/` (root module `LeanFmt`).

## Status

Functional: `install-worker`, `check`, `format`, `fix`, `diff`, `rules`, and `serve` work end-to-end on Lean Lake
projects, with a conservative rule set, a sound incremental cache, safe-write validation, and an editor server. See
[`docs/usage.md`](docs/usage.md) for the full command, config, cache, exit-code, and editor-integration reference, and
`scripts/release-smoke.sh` for an end-to-end install-and-format check.

## Getting started

```sh
cargo build -p lean-fmt-cli --bin lean-fmt
cd my-lake-project
lean-fmt install-worker      # build + install a Lean worker for this toolchain (once)
lake build                   # so project-internal imports resolve
lean-fmt check               # report findings (exit 1 if anything would change)
lean-fmt fix                 # apply safe fixes (each edited file is re-parsed before writing)
```

## Development

```sh
scripts/fmt.sh    # cargo fmt --all -- --check
scripts/lint.sh   # cargo clippy --workspace --all-targets -- -D warnings
scripts/test.sh   # cargo test --workspace
scripts/lean.sh   # lake -d lean build
```

Topic docs: [`docs/usage.md`](docs/usage.md) (commands, config, cache, exit codes, editor integration),
[`docs/testing.md`](docs/testing.md) (property and worker-driven fuzz suites),
[`docs/performance.md`](docs/performance.md) (perf probe, benchmarks, budgets).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at your option.
