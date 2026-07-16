---
kind: roadmap
topic: "Developer workflow and editor integrations"
main_results: [RDI-FINAL]
prereq_stacks: [ruff-15-reporting, ruff-16-watch-incremental, ruff-17-lsp]
blueprint_tracked: false
---

# Developer workflow and editor integrations

## Goal

Package the completed CLI/LSP surface for routine use through shell completions, pre-commit, CI recipes, editor setup, and clean installation guidance.

## Completion contract

- Generate Bash, Zsh, Fish, and PowerShell completions from one CLI command model or a checked canonical specification.
- Provide pre-commit hooks for lint/fix and format-check with safe ordering and pinned-version guidance.
- Document GitHub Actions and generic CI using machine formats, cache policy, exact Lean toolchains, and exit codes.
- Publish and test thin first-party VS Code, Neovim, and Emacs integration packages plus generic LSP
  setup without maintaining divergent semantic adapters. Non-Lean editor packaging is allowed only
  because those hosts require their own manifest/extension languages; it contains no formatting,
  linting, project, or cache logic.

## Work order

1. **RDI-SPEC — Freeze supported integration surfaces.** Audit packaging constraints and write canonical command metadata, hook ordering, CI cache keys, editor launch/config mapping, version compatibility, and support policy.
2. **RDI-IMPL — Implement generated completions and integration assets.** Add completion generation/drift tests, pre-commit manifests/examples, CI examples, editor configurations, and clean install/upgrade documentation.
3. **RDI-FINAL — Test integrations from clean sources.** Run shell completion syntax checks, a temporary pre-commit repository, CI command simulations, generic LSP launch, and clean `git archive` installation smoke.

## Evidence and verification

Every prompt writes `results/01-contract.md`-style result notes with commands, raw measurements,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack unless this is the
final acceptance stack and its prompt explicitly authorizes it.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker, generated-next
check, and `git diff --check`. Performance records name workload, profile, cache/build state,
machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
