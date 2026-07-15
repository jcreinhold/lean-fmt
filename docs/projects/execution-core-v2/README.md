# Execution Core v2

This maintenance stack rebuilds lean-fmt from the ground up as two binary crates: a Lean-free
`lean-fmt` application and the sole Lean-linked `lean-fmt-worker-child`. It establishes the Lean
worker as the behavioral oracle, then builds a private Rust execution core around `RunEngine` and
`LeanRun`. The result must preserve exact ordered import context, remain inside an 8 GiB aggregate
process-tree envelope, and run `lean-fmt check` over mathlib in a reasonable time.

Start with [roadmap.md](roadmap.md). Execute prompts in dependency order, keep
[state/current.md](state/current.md) accurate, and preserve measurements and command output under
`evidence/` or `results/` as directed by each prompt. The command-line check path is built first;
the long-lived service is deliberately last.

This is maintenance work and is not blueprint-tracked. The local *Philosophy of Software Design*
chapters and the deep-module and Lean-performance skills cited by the roadmap and prompts govern
the design.
