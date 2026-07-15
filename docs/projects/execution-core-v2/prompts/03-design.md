---
claim_id: ECV2-DESIGN
status: planned
depends_on: [ECV2-ORACLE]
---

# Design the private execution core twice

## Task

Develop and compare two substantively different private application designs, then select the one
that best hides process state, exact context compatibility, memory enforcement, and deterministic
collection. The selected design must center concrete private `RunEngine` and `LeanRun` types and
must not create a Rust library API.

## Read

- ECV2-ORACLE protocol and fixtures.
- `crates/lean-fmt/src/main.rs` and child process facilities available from lean-rs.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/04-modules-should-be-deep.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/07-different-layer-different-abstraction.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/08-pull-complexity-downwards.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/11-design-it-twice.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/deep-module-design/SKILL.md`.

## Target

- `docs/projects/execution-core-v2/notes/03-design.md` comparing two different boundaries by depth,
  information leakage, caller cost, change amplification, context correctness, and failure modes.
- Private `RunEngine` owns one command execution, discovered inputs, deterministic ordering, cache
  coordination, memory policy, and result collection.
- Private `LeanRun` owns one child lifetime, protocol sequencing, exact ordered-context identity,
  compatible reuse, limits, and shutdown.
- Constructors return usable states; callers cannot perform protocol setup in the wrong order.

## Stop

Do not proceed with two cosmetic variants. Stop if either type becomes a pass-through wrapper, if
policy leaks into the child, or if test substitution would require a public trait.

## Check

- Run the deep-module audit over `crates/lean-fmt` before and after the design skeleton.
- Read every production caller of `RunEngine` and `LeanRun`; the common path must be obvious.
- `cargo check --workspace`
- `git diff --check`
