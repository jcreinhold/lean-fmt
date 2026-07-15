---
claim_id: ECV2-REUSE
status: planned
depends_on: [ECV2-CHECK]
---

# Reuse the child without changing context

## Task

Keep one `LeanRun` alive across compatible files and reuse imported state only when the child
confirms that the next file's exact ordered import context and options are compatible. Measure the
saved startup/import work and preserve oracle-equivalent output.

## Read

- Check-path traces and oracle fixtures.
- Lean environment/import APIs and lean-rs child lifecycle behavior.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/20-designing-for-performance.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/references/compilation-and-build.md`.

## Target

- A child-owned ordered-context identity and compatibility decision.
- Reuse common exact prefixes or already-established identical contexts without exposing unrelated
  syntax or changing import order.
- Incompatible contexts transition through a fresh, explicit Lean state while retaining the same
  private `LeanRun` interface.
- Evidence separates child startup, import establishment, parse/semantic work, and reporting time.

## Stop

Do not compute compatibility from sorted module names on the Rust side. Do not parse a file in an
environment containing imports absent from its Lean-defined context. Stop on any oracle divergence.

## Check

- Differential tests compare fresh-child and reused-child output byte-for-byte over representative
  mathlib files and adversarial import orderings.
- Trace tests show when contexts are reused and when a clean state is established.
- Record before/after wall time and RSS.
- `cargo test --workspace`
- `git diff --check`
