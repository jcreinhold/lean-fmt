---
kind: roadmap
topic: "Fix applicability and atomic fix-all"
main_results: [RFX-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-05-rule-engine]
blueprint_tracked: false
---

# Fix applicability and atomic fix-all

## Goal

Classify every proposed edit as safe, unsafe, or display-only and extend the existing checked patch transaction into deterministic atomic fix-all behavior.

## Completion contract

- Safe means intended runtime/proof meaning is preserved under the rule's stated evidence; unsafe means behavior, comments, or intent may change; display-only is never applied.
- Applicability is present in JSON and text explanations and can be promoted/demoted per rule only through explicit configuration.
- Conflict resolution never guesses: incompatible edits reject the atomic file or project transaction with provenance.
- All applied candidates pass exact syntax validation and rules that claim semantic safety may require elaboration validation.

## Work order

1. **RFX-SPEC — Freeze applicability and conflict semantics.** Specify applicability definitions, per-rule overrides, formatter interaction, conflict provenance, file/project atomicity, and CLI behavior for showing versus applying unsafe fixes.
2. **RFX-IMPL — Implement applicability-aware planning and publication.** Extend findings, reports, configuration, edit planning, validation, and atomic publication. Add fix-only/unfixable selection without coupling rule selection to execution strategy.
3. **RFX-FINAL — Run adversarial fix-all verification.** Test overlapping insert/delete/replace edits, UTF-8 boundaries, comment loss, promoted/demoted applicability, formatter composition, stale files, and crashes between validation and rename.

## Evidence and verification

Every prompt writes `results/01-model.md`-style result notes with commands, raw measurements,
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
