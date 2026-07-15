# lean-fmt

A Ruff-style formatter and linter for [Lean 4](https://leanprover.github.io/) Lake projects.

The execution core is being rebuilt from first principles after the previous parallel-worker design
reached roughly 60 GiB of resident memory on a mathlib-scale run. The replacement preserves product
contracts only after they are characterized and reintroduced through the execution-core v2 stack.

## Design

The workspace has exactly two binary crates:

| Crate | Responsibility |
| --- | --- |
| `lean-fmt` | Lean-free application: CLI, project discovery, cache, rules, edits, reporting, packaging, and private execution policy. |
| `lean-fmt-worker-child` | Toolchain-specific worker host and the sole `libleanshared` boundary. |

There is no published Rust library API. The common product path is a private intent-to-result
operation inside `lean-fmt`; worker lifecycle, exact Lean context, caching, and resource accounting
are implementation details. Lean owns header interpretation, import-dependent parsing, syntax
projection, and validation. Rust owns conservative formatting policy and writes.

The default runtime design is one worker process with one Lean task thread. A memory option is an
aggregate operating envelope for the complete parent-plus-child process tree, not permission to
multiply per-process limits. See [the execution-core v2 roadmap](docs/projects/execution-core-v2/roadmap.md).

## Status

The repository is at the clean two-crate foundation. Previous command and performance claims are not
claims of the replacement implementation. `check` is the first vertical slice; formatting modes,
cache, and the editor service follow only after exact-context and memory acceptance.

## Development

```sh
scripts/fmt.sh            # cargo fmt --all -- --check
scripts/lint.sh           # cargo clippy --workspace --all-targets -- -D warnings
scripts/test.sh           # cargo test --workspace + boundary guard
scripts/lean.sh           # build the bundled LeanFmt capability
scripts/check-boundary.sh # verify the two-crate Lean-link boundary
```

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at your option.
