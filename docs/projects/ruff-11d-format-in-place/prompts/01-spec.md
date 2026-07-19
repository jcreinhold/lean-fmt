---
claim_id: FIP-SPEC
status: planned
depends_on: []
---

# Freeze the in-place-format interface

## Task

Deliver **FIP-SPEC**: Specify `format`'s change from a stdout preview to an in-place publisher, matching
`ruff format`. Freeze, in `notes/01-model.md`, the exact interface before any code changes: what `format`
writes and how; the guarded publish path it reuses from `ruff-06`; the `--check` non-writing preview; the
exit-code and report-status semantics for both; the CLAUDE.md invariant change; and a precise
reuse-vs-new inventory so FIP-IMPL adds the minimum. This is a specification prompt — it changes no
executable behavior. Write a first-hand characterization of today's `format` (stdout framing, no write,
`fix` as sole writer) into `evidence/01-current-format.md` before specifying the replacement.

## Read

- `LeanFmt/Cli.lean` — the `format` output branch (prints `=== path (bytes) ===` + `formatted` to
  stdout), `parseFileArgs`, and flag parsing (`--unsafe-fixes`, `--check-elab`, `--json`).
- `LeanFmt/Application.lean` — `RunMode`, `previewFile`/`fixFile`, `prepareFile`, `publishAtomic`, the
  stale-source check, the exact-setup validator, and how `fix` composes them (`ruff-06`, `ruff-11c`
  RDF-IMPL).
- `LeanFmt/LosslessSource.lean` — `normalize`/`denormalize`; the raw-vs-normalized byte boundary.
- `LeanFmt/Project.lean` — `Project.load` no-arg discovery (`discoverPaths` + `config.includesPath`).
- `docs/projects/ruff-11c-decouple-fix-format/notes/01-model.md` and `results/04-final.md` — the split and
  the confluence result that must continue to hold.
- `docs/projects/ruff-06-fix-safety/` — the publish/validation/stale-check/atomic guarantees.
- The CLAUDE.md constraint *"check, format, and diff never write source; fix publishes."*

## Target

Freeze in `notes/01-model.md`:

- **The write.** For each resolved file `format` renders the `ruff-11c` layout patch (`canonical.text`,
  no rule fix) and publishes it through the same guarded path `fix` uses: (1) stale-source check;
  (2) validation under the exact module setup; (3) `publishAtomic`; (4) lossless denormalization of the
  normalized (LF) canonical text back to the file's raw line endings. State whether validation is
  required for a pure reflow or may be elided, and justify the decision (default: **require it**, for
  parity with `fix` and because the CLAUDE.md invariant will read "format and fix publish only … validated
  … after a stale-source check"). A file that does not elaborate is `broken` and never written; a partial
  write is impossible.
- **`--check`.** The non-writing preview: no file written, report which files *would* change, exit
  non-zero if any would. Specify it precisely against `ruff format --check`.
- **Exit codes and report status.** `format` (writing) exits 0 on success even when it changed files
  (mirroring `fix`), 2 on infrastructure failure; a written file's status becomes `formatted` with a
  `written` count (like `fix`'s `fixed`). `format --check` exits non-zero when any file would change
  (mirroring today's `would-format`), 0 when all clean, 2 on infra. `diff` and `check` exit codes are
  unchanged. Pin the JSON report shape for each.
- **The invariant change.** Rewrite the CLAUDE.md rule to *"`check` and `diff` never write source;
  `format` and `fix` publish only a complete, conflict-free result validated under the exact module setup,
  after a stale-source check."* Note every doc/comment that repeats the old "format never writes" claim
  and must move (grep list).
- **Reuse-vs-new inventory.** Name the exact `fix` publish helpers `format` reuses unchanged, and the
  minimum new surface (a `format --check` flag; a writing branch in the driver/`previewFile` seam or a
  small `formatFile` analogous to `fixFile`; the Cli.lean output branch). Keep it minimal — do not
  duplicate the publish path.
- **Boundaries.** Config globs → `ruff-13`; stdin/stdout + range → `ruff-14`. If a temporary stdout escape
  hatch is unavoidable for migration, record it as a named minimal `ruff-14`-superseded stopgap, not a
  designed surface.

## Plan

1. Characterize today's `format` first-hand (run it, capture the stdout framing and non-write) into
   `evidence/01-current-format.md`.
2. Trace `fix`'s publish path and mark each reusable helper.
3. Write `notes/01-model.md` freezing the interface above, then the invariant-change grep list.

## Stop

- Do not weaken any `ruff-06` write guarantee or the `ruff-11c` split in the spec. `format` applies no
  rule fix; it publishes only layout.
- Do not design config selection or stdin/stdout here — name their owning stacks.

## Check

- Structural/architecture gates: `check_stack.py --structural`, `check_prompt_architecture.py`,
  `write_next.py --check`, `git diff --check`.
- Confirm the frozen interface is buildable from existing helpers (the reuse inventory cites real
  `Application.lean` definitions). Write `results/01-spec.md` with the characterization locators, the
  frozen decisions, the invariant-change grep list, and remaining uncertainty; update `state/current.md`
  after reading the checks; regenerate `state/next.md`.
