---
kind: roadmap
topic: "Ground-up lean-fmt execution core"
main_results: [ECV2-FINAL]
prereq_stacks: []
blueprint_tracked: false
---

# Execution Core v2 Roadmap

## Goal

Rebuild lean-fmt around the smallest viable architecture: exactly two binary crates, no public Rust
library API, and one process boundary. `crates/lean-fmt` owns command-line behavior, discovery,
execution, caching, edits, and reports without linking Lean. `crates/lean-fmt-worker-child` is the
only Lean-linked artifact and owns the real Lean frontend behavior. The implementation must make a
full `lean-fmt check` over `~/Code/mathlib4` complete in a reasonable time while the complete
process tree remains inside an 8 GiB aggregate memory envelope.

## Design boundary

Both crates are binaries. Rust modules and types remain private unless the language requires
visibility inside their binary crate. `RunEngine` is the private application-side owner of a run:
it discovers inputs, opens one compatible Lean session at a time, sequences files, enforces memory,
and collects results. `LeanRun` is the private process-boundary abstraction for one child lifetime:
it owns protocol state, exact import-context identity, reuse, shutdown, and failure reporting.

Lean remains the oracle for parsing and semantic structure. Every file is evaluated against its
own exact ordered header imports and options. Reuse is legal only when the child confirms a
compatible ordered context; imports are never sorted, deduplicated, or replaced by a union grammar.
The Rust side must not attempt to reproduce Lean's parser or semantic decisions.

## Work order

1. Reset the workspace to the two-binary skeleton and freeze invariants.
2. Establish the Lean child as an executable behavioral oracle.
3. Design the private `RunEngine`/`LeanRun` boundary twice and select the deeper design.
4. Implement `lean-fmt check` end to end before adding other modes.
5. Reuse one child and compatible exact ordered import contexts without changing semantics.
6. Scale whole-repository execution under the 8 GiB aggregate envelope.
7. Add a coarse trace-epoch cache whose invalidation is simple and honest.
8. Add format, diff, and conservative fix behavior on the proven check core.
9. Add the long-lived service only after command-line execution is stable.
10. Run full acceptance, including mathlib performance and memory evidence.
11. Audit the final system against design, correctness, and scope claims.

## Completion contract

- The workspace has exactly the `lean-fmt` and `lean-fmt-worker-child` binary crates.
- There is no public Rust library API and no crate exists only to forward another crate's concepts.
- Only `lean-fmt-worker-child` links `libleanshared`; the parent communicates solely by a versioned
  subprocess protocol.
- Lean oracle fixtures fix the meaning of discovery inputs, ordered imports, parsing, semantic
  projection, diagnostics, and edits before Rust orchestration is optimized.
- `RunEngine` and `LeanRun` are private, concrete, and structurally enforce one owner for each child
  and its protocol state.
- A file's exact ordered import context and options determine semantic execution. Reuse never
  changes that context and never introduces syntax from unrelated imports.
- The complete child process tree stays below 8 GiB; exceeding the envelope terminates cleanly with
  a useful diagnostic rather than relying on OS OOM behavior.
- The first complete product path is `lean-fmt check`; format, diff, fix, cache, and service behavior
  reuse that core instead of creating parallel implementations.
- The cache uses a coarse trace epoch. A changed toolchain, capability, configuration, ordered
  import trace, or output-affecting rule identity advances the epoch and invalidates the affected
  stored results as a unit; no speculative fine-grained dependency graph is introduced.
- Reports are deterministic and complete. Fixes remain conflict-checked, reversible, and validated
  before any write.

## Blueprint impact

This is genuine repository maintenance with no mathematical declarations, source-facing claims,
or blueprint dependency edges. Therefore this roadmap alone sets `blueprint_tracked: false`.
Prompts must not add blueprint fields, proof targets, or placeholder mathematical sections.

## Design and performance references

- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/02-the-nature-of-complexity.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/04-modules-should-be-deep.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/07-different-layer-different-abstraction.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/08-pull-complexity-downwards.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/09-better-together-or-better-apart.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/10-define-errors-out-of-existence.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/11-design-it-twice.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/16-modifying-existing-code.md`
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/20-designing-for-performance.md`
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/deep-module-design/SKILL.md`
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`

## Risks and stop rules

- Do not optimize by changing the oracle result or broadening a file's import context.
- Do not create a third crate, a public library facade, a trait with one production implementor, or
  a pass-through abstraction.
- Do not add command modes before the check path has end-to-end oracle and memory evidence.
- Stop if the exact mathlib toolchain, ordered import behavior, or process-tree memory cannot be
  reproduced; record the failure instead of substituting a different environment.
- Stop if any change would link Lean into the application binary, bypass edit conflicts, weaken
  validation, exceed 8 GiB, or make the child protocol state ambiguous.
