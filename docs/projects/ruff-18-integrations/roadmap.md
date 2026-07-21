---
kind: roadmap
topic: "CI recipes and installation documentation"
main_results: [RDI-FINAL]
prereq_stacks: [ruff-15-reporting, ruff-16-watch-incremental, ruff-17-lsp]
blueprint_tracked: false
---

# CI recipes and installation documentation

## Goal

Document how a consuming project runs `lean-fmt` in CI and how it installs and upgrades it, and test
both from clean sources.

## Scope, narrowed 2026-07-21

This stack was planned with five deliverables: shell completions, pre-commit hooks, CI recipes, first-
party editor packages, and installation documentation. Three are **cut, not deferred silently**:

- **Shell completions** (Bash, Zsh, Fish, PowerShell from one command model). Entirely unbuilt —
  nothing in `LeanFmt/Cli.lean` generates them — and it is the largest of the five: a command model,
  four emitters, and a drift test that fails when a flag is added. Not needed to use the product.
- **Pre-commit hooks.** `--staged` shipped in `ruff-16` and is the whole mechanism; a hook manifest is
  a thin wrapper over it, and the interesting part (safe ordering against other hooks) is guidance,
  not code.
- **First-party VS Code / Emacs / Neovim packages.** `ruff-17` shipped `docs/editor-setup.md` with
  working stanzas for all three, and `tests/lsp/editor.sh` runs the Neovim one through Neovim's own
  LSP client. A first-party package would add TypeScript and elisp — two languages nothing else in
  this repository uses, against `CLAUDE.md`'s "prefer pure Lean" — to save users a paste. The
  documented stanzas are the cheaper answer until someone reports they are not.

Reopening any of the three is a new stack, not an amendment to this one. The old roadmap also promised
to "publish" editor packages while every prompt's stop rule forbade remote publishing; that
contradiction goes away with the deliverable.

## Completion contract

- **CI recipes.** GitHub Actions and generic CI, written from the frozen reporting and selection
  surfaces rather than invented: exit codes (0 clean, 1 findings, 2 infrastructure), machine output
  formats paired with the modes that accept them, what is safe to cache and what invalidates it, and
  exact toolchain pinning. Recipes are checked by running them, not by reading them.
- **Installation and upgrade documentation.** How a consuming project takes `lean-fmt` as a Lake
  dependency, what a toolchain bump requires, and what upgrading a pinned revision changes. Smoke-
  tested from a clean `git archive` so the instructions cannot silently depend on this working tree.

## What already exists

Do not rebuild these; cite them, and correct them if the audit finds them wrong.

- `README.md` §"Using lean-fmt in another project" — the three consumption levels (run it, wire it into
  `lake lint`, add the compiler plugin), including the guillemet requirement and the three plugin costs.
- `lakefile.lean` — `testDriver`/`lintDriver`/`lintDriverArgs`, the worked example a consumer copies.
- `.github/workflows/lean_action_ci.yml` — `leanprover/lean-action@v1`, which probes `lake check-lint`
  and runs `lake lint`. This is the minimal recipe; it is not the SARIF or changed-files one.
- `tests/downstream/run.sh` — a real two-package workspace exercising all three consumption levels.
- `docs/editor-setup.md` and `tests/lsp/editor.sh` — `ruff-17`'s editor surface, now the whole of this
  stack's editor answer.

## Work order

1. **RDI-RECIPES — Write the CI recipes and the installation/upgrade documentation.** Audit what the
   frozen surfaces actually guarantee (the inherited notes in `state/current.md` are the source), then
   write recipes and docs that cite them. No separate spec prompt: `ruff-15` and `ruff-16` froze the
   surface this documents, so there is no new interface to design twice.
2. **RDI-FINAL — Test both from clean sources.** Run the CI commands against a scratch repository, and
   smoke-test installation from a clean `git archive` in a temporary directory.

## Evidence and verification

Both prompts write `results/` notes with commands, raw measurements, decisions changed during
execution, and remaining uncertainty. Use focused fixtures and scratch repositories; do not run
complete mathlib in this stack.

Run the affected Lean build and suites, `tests/boundary/run.sh`, `lake lint`, and `git diff --check`.
A recipe this stack publishes must have been executed, with its output recorded — a documented command
nobody ran is a claim, not a recipe.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Do not document a flag, exit code, or output format the CLI does not have. Run it first.
- No remote publishing, credentials, or state changes: no marketplace, no registry, no release.
- Preserve exact ordered imports, search-path precedence, validation identity, private application
  boundaries, and atomic writes.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
