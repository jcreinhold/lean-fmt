---
claim_id: ECV2-MODES
status: planned
depends_on: [ECV2-CACHE]
---

# Add format, diff, and conservative fix modes

## Task

Layer format, diff, and fix behavior over the proven check execution core. Keep analysis identical
across modes; only presentation and the final validated write decision may differ.

## Read

- Check and cache result representations and oracle edit fixtures.
- Existing edit invariants documented in `AGENTS.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/07-different-layer-different-abstraction.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/10-define-errors-out-of-existence.md`.

## Target

- Format emits formatted text, diff emits deterministic unified diffs, and fix is the only mode that
  writes source files.
- Every edit set is range-checked, conflict-checked, reversible, and revalidated through the oracle
  before a write; bypassing semantic validation never bypasses structural checks.
- Check, format, diff, and fix consume the same private execution result rather than duplicating
  discovery or Lean calls.
- Cached results retain enough epoch and validation identity to prevent unsafe reuse.

## Stop

Do not make mode-specific parser paths. Do not write after a parse/validation failure or conflicting
edit. Stop if a cached result cannot prove the validation identity required for fix.

## Check

- Golden tests compare all modes over clean, dirty, broken, conflicting, stale, and custom-syntax files.
- Property tests cover edit reversal, overlap rejection, and unchanged-source behavior.
- Verify only fix changes filesystem contents.
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `git diff --check`
