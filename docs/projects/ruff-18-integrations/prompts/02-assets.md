---
claim_id: RDI-IMPL
status: planned
depends_on: [RDI-SPEC]
---

# Implement generated completions and integration assets

## Task

Deliver **RDI-IMPL**: Add completion generation/drift tests, pre-commit manifests/examples, CI
examples, thin first-party VS Code/Neovim/Emacs packages that launch the native LSP, generic editor
configurations, and clean install/upgrade documentation. Host-language code must remain protocol and
process glue only; all semantic behavior stays in the Lean executable.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Add or update focused fixtures and persistent regression tests at the owning layer.
- Put editor packages under an explicit `editors/` boundary with launch, version, settings, command,
  and packaging tests; do not copy diagnostics, formatting, fix, or configuration semantics into them.
- Write `results/02-assets.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim.
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Generated assets must be reproducible.
- Examples use `lean-fmt`, never a renamed CLI crate or binary.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use the frozen sample or synthetic saved reports for scale; complete mathlib is forbidden unless this
  prompt is `RCP-ACCEPT` and all prerequisite gates pass.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-18-integrations`.
- Run `git diff --check` and read all output before marking RDI-IMPL verified.
