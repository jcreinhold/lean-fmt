# Next Proof Packet

- Stack: ruff-11d-format-in-place
- First unresolved: 01-spec
- Claim ID: FIP-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **FIP-SPEC**: Specify `format`'s change from a stdout preview to an in-place publisher, matching `ruff format`. Freeze, in `notes/01-model.md`, the exact interface before any code changes: what `format` writes and how; the guarded publish path it reuses from `ruff-06`; the `--check` non-writing preview; the exit-code and report-status semantics for both; the CLAUDE.md invariant change; and a precise reuse-vs-new inventory so FIP-IMPL adds the minimum. This is a specification prompt — it changes no executable behavior. Write a first-hand characterization of today's `format` (stdout framing, no write, `fix` as sole writer) into `evidence/01-current-format.md` before specifying the replacement.

## Reuse

- `LeanFmt/Cli.lean` — the `format` output branch (prints `=== path (bytes) ===` + `formatted` to stdout), `parseFileArgs`, and flag parsing (`--unsafe-fixes`, `--check-elab`, `--json`).
- `LeanFmt/Application.lean` — `RunMode`, `previewFile`/`fixFile`, `prepareFile`, `publishAtomic`, the stale-source check, the exact-setup validator, and how `fix` composes them (`ruff-06`, `ruff-11c` RDF-IMPL).
- `LeanFmt/LosslessSource.lean` — `normalize`/`denormalize`; the raw-vs-normalized byte boundary.
- `LeanFmt/Project.lean` — `Project.load` no-arg discovery (`discoverPaths` + `config.includesPath`).
- `docs/projects/ruff-11c-decouple-fix-format/notes/01-model.md` and `results/04-final.md` — the split and the confluence result that must continue to hold.
- `docs/projects/ruff-06-fix-safety/` — the publish/validation/stale-check/atomic guarantees.
- The CLAUDE.md constraint *"check, format, and diff never write source; fix publishes."*

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not weaken any `ruff-06` write guarantee or the `ruff-11c` split in the spec. `format` applies no rule fix; it publishes only layout.
- Do not design config selection or stdin/stdout here — name their owning stacks.
