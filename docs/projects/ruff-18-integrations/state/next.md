# Next Proof Packet

- Stack: ruff-18-integrations
- First unresolved: 01-recipes
- Claim ID: RDI-RECIPES
- Prompt: 01-recipes
- Module: (docs only)
- Target file: `README.md` or `docs/ci.md`, and `results/01-recipes.md`

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

- `state/current.md`, all three "Inherited from" sections — the frozen facts this prompt documents.
- `roadmap.md` §"Scope" and §"What already exists", and every file the latter names.
- `LeanFmt/Cache.lean`'s `ResultCache.open?`, for what is actually in cache identity.

## Proof Task

- Deliver **RDI-RECIPES**: CI recipes for GitHub Actions and generic CI, and installation/upgrade
  documentation for a consuming project, written from the frozen reporting and selection surfaces.
- Run every command a recipe will contain before writing the recipe. A recipe is written from a
  transcript, not from help text.

## Reuse

- `README.md` §"Using lean-fmt in another project" — the three consumption levels, already written.
- `.github/workflows/lean_action_ci.yml` — the minimal recipe, already running.
- `tests/downstream/run.sh` — a real two-package consuming workspace.

## Stop Rules

- Do not document a flag, exit code, or output format the CLI does not have. Run it first.
- No remote publishing, credentials, or state changes.
- Do not add shell completions, pre-commit manifests, or editor packages: the roadmap cut them, and
  reopening one is a new stack, not an amendment to this one.
