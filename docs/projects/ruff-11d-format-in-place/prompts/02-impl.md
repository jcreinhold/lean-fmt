---
claim_id: FIP-IMPL
status: verified
depends_on: [FIP-SPEC]
---

# Route format through the guarded publish

## Task

Deliver **FIP-IMPL**: Make `format` publish the canonical layout in place by default through the
`ruff-06` guarded path, add the `format --check` non-writing preview, and migrate every test and doc that
assumed `format` prints to stdout / never writes. Implement exactly the interface FIP-SPEC froze in
`notes/01-model.md` — no more surface than the reuse inventory names.

## Read

- `notes/01-model.md` (FIP-SPEC): the frozen write path, `--check` semantics, exit/report shapes, the
  invariant change, and the reuse-vs-new inventory.
- `LeanFmt/Application.lean` — `fixFile`, `previewFile`, `publishAtomic`, the stale-source check, the
  validator, and the driver seam (`request.mode`, the preview vs. `withExactRun` branches).
- `LeanFmt/Cli.lean` — the `format` output branch and flag parsing.
- `tests/modes/run.sh` — every `format` assertion (currently `would-format`, `formatted`, stdout);
  `tests/check/run.sh`; `tests/lossless/run.sh`.

## Target

- **Writing `format`.** Route `format` through the guarded publish (a `formatFile` analogous to `fixFile`,
  or the minimal seam FIP-SPEC chose): render `canonical.text`, run the stale-source check, validate under
  the exact module setup, denormalize losslessly, `publishAtomic`. Status `formatted` + `written` count
  on write; `broken` and no write when the file does not elaborate; never a partial write.
- **`format --check`.** Parse the flag; when set, run the same rendering but write nothing and report
  `would-format` / clean with the exit code FIP-SPEC froze.
- **`Cli.lean`.** Replace the stdout-dump branch: writing `format` prints a concise per-file summary
  (path, written/unchanged), not the file body; `format --check` prints what would change. Keep `--json`.
- **`diff`/`check` unchanged** — still never write.
- **Invariant + docs.** Apply the CLAUDE.md invariant change and update every doc/comment on FIP-SPEC's
  grep list that repeats "format never writes."
- **Test migration.** Update `tests/modes` format assertions from stdout/`would-format`-by-default to
  in-place write + `--check` preview; keep the `ruff-11c` confluence test meaningful (order A's `fix;
  format` now has `format` actually writing). Trailing-whitespace fixtures stay runtime-built (never
  committed — `git diff --check`).

## Plan

1. Add the writing seam reusing `fix`'s publish helpers; add `--check`.
2. Update `Cli.lean` output.
3. Apply the invariant/doc changes.
4. Run the owning suites; migrate each broken assertion to the new default, preserving what it proves.

## Stop

- No write that skips a `ruff-06` guard; no partial write; `check`/`diff` still never write.
- Do not reintroduce rule-fix application into `format`, and do not add config selection or stdin/stdout
  (owned by `ruff-13`/`ruff-14`).
- Stop rather than duplicating the publish path — reuse `fix`'s helpers.

## Check

- `LEAN_NUM_THREADS=1 lake build`; `tests/modes/run.sh`, `tests/check/run.sh`, `tests/lossless/run.sh`,
  `lake exe lean-fmt-tests`; `tests/boundary/run.sh` with a manual review of every changed module
  boundary.
- `check_stack.py --structural`, `check_prompt_architecture.py`, `write_next.py --check`,
  `git diff --check`. Write `results/02-impl.md` (commands, outputs/locators, decisions changed, files
  changed, checks read, remaining uncertainty); update `state/current.md`; regenerate `state/next.md`.
