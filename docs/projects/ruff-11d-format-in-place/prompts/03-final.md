---
claim_id: FIP-FINAL
status: verified
depends_on: [FIP-IMPL]
---

# Adversarial acceptance for in-place format

## Task

Deliver **FIP-FINAL**: Accept the in-place default adversarially. `format` writes exactly the canonical
bytes and only those; it is idempotent; `--check` never writes; a file that does not elaborate is never
written; the lossless write round-trips original line endings and touches no in-string byte; the
stale-source check guards format's write as it guards fix's; `check`/`diff` still never write; and the
`ruff-11c` format+fix confluence still holds now that `format` writes. Prove it through the product CLI
and persistent tests at the owning layer, and by direct inspection.

## Read

- `notes/01-model.md`, `results/01-spec.md`, `results/02-impl.md`; the implementation and `tests/modes`,
  `tests/check`, `tests/lossless`.
- `docs/projects/ruff-11c-decouple-fix-format/results/04-final.md` — the confluence and fix-free-format
  acceptances that must still pass with `format` now writing.

## Target

Drive each through the CLI and pin a persistent regression at the owning layer:

- **Exact bytes.** `format` on a layout-dirty, otherwise-clean fixture writes exactly `canonical.text`
  (byte-compared), and nothing else — no rule fix appears (the `ruff-11c` fix-free guarantee, now on a
  written file).
- **Idempotence.** A second `format` on the written file writes nothing (`written == 0`, byte-identical).
- **`--check` never writes.** `format --check` on a dirty fixture leaves it byte-identical and exits
  non-zero; on a clean fixture exits zero. On the same dirty fixture plain `format` then writes it.
- **Broken file is never written.** A fixture with an elaboration error is reported `broken`, the file is
  byte-identical afterward, and no temporary file survives — the stale-source/validation guard holds for
  `format` exactly as for `fix`.
- **Lossless write round-trip.** A CRLF fixture formatted in place keeps CRLF line endings (denormalized
  on write); an in-string trailing-whitespace fixture keeps its string value under `format` (the
  formatter's trivia-only trim, `ruff-11c` RDF-LAYOUT, cannot corrupt it on write either).
- **Stale-source guard.** A fixture whose source changed under a stale build is not written (or is
  re-validated), matching `fix`'s stale-source behavior.
- **Confluence with format writing.** Re-run the `ruff-11c` composition: `fix` then `format` now writes
  the fully-canonical file in place; `format` then `fix` reaches the same bytes. Both orders converge, and
  a final `format`/`check` is a no-op.
- **No-arg project-wide write.** `format` with no file args writes exactly the discovered included set
  (`config.includesPath`), and no `.lake` or excluded file, leaving out-of-set files byte-identical.
- **`check`/`diff` still never write** — assert byte-identity after each.

## Plan

1. Build the fixtures (layout-dirty, broken, CRLF, in-string-ws, project-tree) as runtime scratch under
   the root; never commit trailing-whitespace fixtures.
2. Drive each case through the CLI; pin it in `tests/modes` (verb behavior) or `tests/lossless` (write
   round-trip).
3. Confirm the frozen-sample review read-only (no full mathlib): a `format` of a real dirty sample module
   would write only canonical layout — verified via the miniatures where a live frontend run is
   affordable, and by inspection where it is not.

## Stop

- No write skipping a `ruff-06` guard; no partial write; no in-string byte change; original line endings
  preserved. `check`/`diff` never write. The `ruff-11c` split and confluence hold.
- No full mathlib run. Stop rather than weakening a preserved invariant.

## Check

- `LEAN_NUM_THREADS=1 lake build`; `tests/modes/run.sh`, `tests/check/run.sh`, `tests/lossless/run.sh`,
  `lake exe lean-fmt-tests`; `tests/boundary/run.sh` with manual boundary review.
- `check_stack.py --structural`, `check_prompt_architecture.py`, `write_next.py --check`,
  `git diff --check` — read all output before marking FIP-FINAL verified. Write `results/03-final.md`
  (commands, outputs/locators, decisions changed, remaining uncertainty); update `state/current.md`;
  regenerate `state/next.md`.
