---
claim_id: RDI-FINAL
status: verified
depends_on: [RDI-RECIPES]
---

# Test the recipes and the installation path from clean sources

## Task

Deliver **RDI-FINAL**: run every published CI recipe against a scratch repository, and smoke-test
installation from a clean `git archive`.

"From clean sources" is the whole claim. A recipe tested in this working tree proves nothing about a
consumer: this tree has a warm `.lake`, a warm `.lean-fmt-cache`, a resolved manifest, and a
`lean-fmt.toml` the consumer will not have. The point of this prompt is to remove all four and see
what the instructions actually produce.

## Read

- `results/01-recipes.md` — the recipes under test and the transcripts they were written from.
- `tests/downstream/run.sh` — the existing clean-workspace harness. Extend it rather than writing a
  second one, unless the shapes genuinely differ.

## Target

- Each published recipe run end to end against a scratch git repository with its own commits, so
  `--changed-since` and `--staged` have real history to select from.
- A `git archive` of this repository, unpacked into a temporary directory, built and run there. Record
  what it needs that the archive does not carry.
- Every gap between what a recipe says and what it does, fixed in the recipe — or recorded honestly in
  the result note when the platform, not the recipe, is the limit.
- A persistent gate for whatever a future change could silently break. A recipe verified once by hand
  and never again is a recipe that will rot; if a check cannot reasonably be automated, say so and say
  why.
- Write `results/02-acceptance.md` with exact commands, raw outputs, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Build the scratch repository and the archive extraction first, before running anything, so every
   later measurement is on a known-clean state.
2. Run the recipes in the order a consumer would meet them: install, then lint, then the CI job.
3. Record the failures. A recipe that needed a fix is the most valuable output this prompt has.

## Stop

- Do not require full mathlib.
- No remote publishing, credentials, or state changes.
- Record platform and tool limitations honestly rather than narrowing the claim to what passed.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- `LEAN_NUM_THREADS=1 lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every `tests/*/run.sh`.
- `tests/boundary/run.sh`.
- The scratch-repository and `git archive` runs, with exit codes recorded.
- `git diff --check`, read in full, before marking RDI-FINAL verified.
