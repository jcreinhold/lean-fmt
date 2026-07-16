---
kind: roadmap
topic: "Inline and file-level rule suppressions"
main_results: [RSP-FINAL]
prereq_stacks: [ruff-05-rule-engine]
blueprint_tracked: false
---

# Inline and file-level rule suppressions

## Goal

Add precise source-level suppressions for one finding, one line, or a whole file, plus a first-party diagnostic and safe fix for unused suppressions.

## Completion contract

- Choose and document one Lean comment grammar such as `-- lean-fmt: ignore[CODE]`; parse it from lossless comments, never substring search.
- Suppression scopes are byte/range based, deterministic under formatting, and cannot suppress syntax/infrastructure failures.
- Unknown codes, malformed directives, blanket suppressions, and unused directives have explicit policy.
- Per-file configuration ignores and source suppressions remain different layers with predictable precedence.

## Work order

1. **RSP-SPEC — Specify suppression grammar and scope.** Write a grammar with inline, next-item, and file forms; define selectors, placement, formatting preservation, precedence, and malformed/unknown behavior using adversarial Lean comments.
2. **RSP-IMPL — Implement suppression projection and unused-directive rule.** Parse directives from lossless trivia, apply them after canonical findings, expose suppressed counts in diagnostics, and implement the unused-suppression rule and safe removal fix.
3. **RSP-FINAL — Verify scopes, formatting stability, and recovery.** Test nested syntax, same-line comments, doc comments, custom commands, formatting movement, unknown rules, file ignores, per-file config, and unused fixes.

## Evidence and verification

Every prompt writes `results/01-spec.md`-style result notes with commands, raw measurements,
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
