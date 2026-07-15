# Execution Core v2

This maintenance stack rebuilds lean-fmt as the native Lean project created by `lake init`. It
preserves the failed Rust implementation on an archive branch and uses its measurements to avoid
repeating the same memory model.

The stack distinguishes an ordinarily built project, a formatter-integrated build, a formatter-cache
cold run, and a formatter-cache warm run. Sub-ten-minute cache-cold execution over ordinarily built
mathlib is the optimization goal; exactness and the 8 GiB aggregate envelope remain hard constraints.

Start with [roadmap.md](roadmap.md), execute prompts in dependency order, keep
[state/current.md](state/current.md) accurate, and preserve raw measurements under `evidence/`,
`results/`, or the isolated `experiments/` packages. This is maintenance work and is not
blueprint-tracked.
