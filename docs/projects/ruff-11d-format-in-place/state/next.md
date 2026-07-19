# Next Proof Packet

- Stack: ruff-11d-format-in-place
- First unresolved: 03-final
- Claim ID: FIP-FINAL
- Prompt: 03-final
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **FIP-FINAL**: Accept the in-place default adversarially. `format` writes exactly the canonical bytes and only those; it is idempotent; `--check` never writes; a file that does not elaborate is never written; the lossless write round-trips original line endings and touches no in-string byte; the stale-source check guards format's write as it guards fix's; `check`/`diff` still never write; and the `ruff-11c` format+fix confluence still holds now that `format` writes. Prove it through the product CLI and persistent tests at the owning layer, and by direct inspection.

## Reuse

- `notes/01-model.md`, `results/01-spec.md`, `results/02-impl.md`; the implementation and `tests/modes`, `tests/check`, `tests/lossless`.
- `docs/projects/ruff-11c-decouple-fix-format/results/04-final.md` — the confluence and fix-free-format acceptances that must still pass with `format` now writing.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No write skipping a `ruff-06` guard; no partial write; no in-string byte change; original line endings preserved. `check`/`diff` never write. The `ruff-11c` split and confluence hold.
- No full mathlib run. Stop rather than weakening a preserved invariant.
