# Next Proof Packet

- Stack: ruff-11d-format-in-place
- First unresolved: 02-impl
- Claim ID: FIP-IMPL
- Prompt: 02-impl
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **FIP-IMPL**: Make `format` publish the canonical layout in place by default through the `ruff-06` guarded path, add the `format --check` non-writing preview, and migrate every test and doc that assumed `format` prints to stdout / never writes. Implement exactly the interface FIP-SPEC froze in `notes/01-model.md` — no more surface than the reuse inventory names.

## Reuse

- `notes/01-model.md` (FIP-SPEC): the frozen write path, `--check` semantics, exit/report shapes, the invariant change, and the reuse-vs-new inventory.
- `LeanFmt/Application.lean` — `fixFile`, `previewFile`, `publishAtomic`, the stale-source check, the validator, and the driver seam (`request.mode`, the preview vs. `withExactRun` branches).
- `LeanFmt/Cli.lean` — the `format` output branch and flag parsing.
- `tests/modes/run.sh` — every `format` assertion (currently `would-format`, `formatted`, stdout); `tests/check/run.sh`; `tests/lossless/run.sh`.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- No write that skips a `ruff-06` guard; no partial write; `check`/`diff` still never write.
- Do not reintroduce rule-fix application into `format`, and do not add config selection or stdin/stdout (owned by `ruff-13`/`ruff-14`).
- Stop rather than duplicating the publish path — reuse `fix`'s helpers.
