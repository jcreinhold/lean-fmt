---
claim_id: RDI-RECIPES
status: verified
depends_on: []
---

# Write the CI recipes and the installation/upgrade documentation

## Task

Deliver **RDI-RECIPES**: CI recipes for GitHub Actions and generic CI, and installation/upgrade
documentation for a consuming project.

The surface is already frozen — `ruff-15` froze the report formats and exit codes, `ruff-16` froze the
changed-files selection, and `state/current.md` records the facts a recipe gets wrong if it guesses.
Read those first. This prompt writes documentation *from* them; it does not reopen them.

## Read

- `state/current.md`, all three "Inherited from" sections. They are the source for this prompt.
- `roadmap.md` §"What already exists" and every file it names.
- `ruff-15-reporting/notes/01-report-formats.md` and `ruff-16-watch-incremental/results/` for anything
  the inherited summary compresses.

## Target

- CI recipes, sited where a reader will find them: `README.md` already owns "Using lean-fmt in another
  project", so extend it or add `docs/ci.md` and link it, but do not open a third place that says the
  same thing differently.
- Cover at least: the minimal `lake lint` job that exists today; a SARIF job feeding
  `github/codeql-action/upload-sarif`; a pull-request job using `--changed-since`; and a non-GitHub
  recipe that depends on exit codes alone.
- State the cache policy explicitly — what may be cached across runs, what invalidates it, and what a
  toolchain bump does to it. `ResultCache.open?` (`LeanFmt/Cache.lean`) is the authority for what is in
  cache identity; read it rather than describing it from memory.
- Installation and upgrade: how a consumer pins a revision, what changes when they move the pin, and
  what a toolchain bump requires. `README.md`'s "no prebuilt binary, Lean's ecosystem has no artifact
  server" is the standing reason and should not be re-litigated.
- Write `results/01-recipes.md` with exact commands, raw outputs, decisions changed during execution,
  and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Run each command a recipe will contain, against this repository or a scratch one, and keep the
   output. A recipe is written from a transcript, not from the CLI's help text.
2. Check the claim in every sentence against live behavior — particularly exit codes, which format each
   mode accepts, and what `--changed-since` does when it selects nothing.
3. Correct what you find wrong in the existing documentation rather than adding a second, disagreeing
   description beside it.

## Stop

- Do not document a flag, exit code, or output format the CLI does not have. Run it first.
- No remote publishing, credentials, or state changes.
- Do not add shell completions, pre-commit manifests, or editor packages: `roadmap.md` §"Scope" cut
  them, and reopening one is a new stack.

## Check

- `LEAN_NUM_THREADS=1 lake build`, `lake lint`, and the suites covering anything you touched.
- `tests/boundary/run.sh`.
- Every command quoted in a recipe, executed, with its exit code recorded in the result note.
- `git diff --check`, read in full, before marking RDI-RECIPES verified.
