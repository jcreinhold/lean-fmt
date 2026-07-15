---
claim_id: ECV2-RESET
status: verified
depends_on: []
---

# Reset to the two-binary foundation

## Task

Complete and verify the ground-up workspace reset. The workspace must contain exactly two binary
crates: the Lean-free `lean-fmt` application and the sole Lean-linked `lean-fmt-worker-child`.
Remove remaining architecture claims, dependencies, and build paths that assume any intermediate
library layer. Preserve unrelated local work.

## Read

- `AGENTS.md`, `README.md`, root `Cargo.toml`, `Cargo.lock`, and build scripts.
- `crates/lean-fmt/Cargo.toml`, `crates/lean-fmt/src/main.rs`, and its bundled Lean package.
- `crates/lean-fmt-worker-child/Cargo.toml`, `build.rs`, and `src/main.rs`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/02-the-nature-of-complexity.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/16-modifying-existing-code.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/deep-module-design/SKILL.md`.

## Target

- A buildable two-member workspace with both packages declared only as binaries.
- No public Rust library target or third workspace member.
- `docs/projects/execution-core-v2/notes/01-reset.md` containing the dependency/link boundary,
  deleted architecture inventory, invariants, exclusions, and dirty-worktree observations.
- `docs/projects/execution-core-v2/evidence/01-baseline-checks.md` containing exact commands,
  revisions, and summarized output.

## Stop

Stop if a required runtime capability cannot be owned by either binary without introducing a
pass-through crate; return to ECV2-DESIGN rather than preserving the previous decomposition. Do not
normalize or discard another contributor's changes.

## Check

- `git status --short`
- Confirm workspace members are exactly `crates/lean-fmt` and `crates/lean-fmt-worker-child`.
- Confirm neither package declares a library target.
- Inspect the dependency tree and native link directives; only the child may reach Lean linking.
- `cargo check --workspace`
- `git diff --check -- docs/projects/execution-core-v2`
