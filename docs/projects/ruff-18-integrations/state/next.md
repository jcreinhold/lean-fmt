# Next Proof Packet

- Stack: ruff-18-integrations
- First unresolved: 02-acceptance
- Claim ID: RDI-FINAL
- Prompt: 02-acceptance
- Module: (no production Lean interface; a test harness may be added)
- Target file: `tests/downstream/run.sh` (extend) and `results/02-acceptance.md`

## Target Declarations

- No production decls. If a gate is added, it belongs in a `tests/*/run.sh`, not in `LeanFmt/`.

## Read Before Editing

- `results/01-recipes.md` — the recipes under test, the transcripts they were written from, and its
  §"Remaining uncertainty", which names exactly what this prompt can and cannot close.
- `docs/ci.md` — the published text. Every command in it is under test.
- `tests/downstream/run.sh` — the existing clean-workspace harness. Extend it rather than writing a
  second one, unless the shapes genuinely differ.

## Proof Task

- Deliver **RDI-FINAL**: run every published recipe against a scratch git repository with real
  commits, and smoke-test installation from a clean `git archive` unpacked in a temporary directory.
- Fix in `docs/ci.md` every gap between what a recipe says and what it does. A recipe that needed a
  fix is this prompt's most valuable output.
- Leave a persistent gate for whatever a future change could silently break, or say why a check
  cannot reasonably be automated.

## Carried Over From `01-recipes`

Three items, already recorded, that this prompt should either close or restate as standing:

- **`lake update` against a git dependency is untested.** `01-recipes` used a path `require`. If this
  prompt builds a git-dependency workspace, it closes; otherwise the observation stays labeled.
- **No recipe has run on a GitHub runner**, and the stop rules forbid the remote state change that
  would test one. Expect to record this as a standing limitation, not to narrow the claim to what
  passed.
- **`--root` on a missing directory reports a raw IO error** rather than the repository's path-error
  shape. Exit code and named path are both correct; this is an observation, not this stack's defect.

## Reuse

- The scratch-repository recipe from `results/01-recipes.md` §"The scratch repository" — lakefile,
  `lintDriver`, one clean module, one FMT005 module — rebuilt with a git `require` this time.
- `tests/reporting/run.sh`'s SARIF validation (`check-jsonschema` against the vendored 2.1.0 schema).

## Stop Rules

- Do not require full mathlib.
- No remote publishing, credentials, or state changes: no code-scanning upload, no release, no push.
- Record platform and tool limitations honestly rather than narrowing the claim to what passed.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Checks

- `LEAN_NUM_THREADS=1 lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every `tests/*/run.sh`.
- `tests/boundary/run.sh`.
- The scratch-repository and `git archive` runs, with exit codes recorded.
- `git diff --check`, read in full, before marking RDI-FINAL verified.
- `tests/watch/run.sh` §9.6 fails whenever a `.lean` file is staged (`CLAUDE.md`); re-run it with a
  clean index rather than treating it as a regression.
