---
kind: roadmap
topic: "Complete Lean language formatting"
main_results: [RLF-FINAL]
prereq_stacks: [ruff-02-layout-core]
blueprint_tracked: false
---

# Complete Lean language formatting

## Goal

Implement canonical, idempotent formatting for Lean modules, headers, commands, declarations, terms, types, patterns, tactics, `do` notation, quotations, macros, and file-local syntax without losing comments or changing exact semantics.

## Completion contract

- Every supported parser category has an explicit ownership table and formatter fallback; accepted syntax is never silently dropped.
- Unknown/custom syntax preserves its token subtree and comments conservatively until a registered structural formatter exists.
- Formatting twice is byte-identical to formatting once, and syntax validation always passes under the original exact context.
- Style fixtures are reviewed as product policy; mathlib is characterization input, not an authority that forces unstable accidental style.

## Work order

1. **RLF-COMMANDS — Format modules, headers, imports, namespaces, and declarations.** Add category dispatch and canonical layouts for module headers, imports, namespaces/sections, attributes, binders, declarations, structures, inductives, and command comments. Establish golden and idempotence tests.
2. **RLF-EXPRESSIONS — Format terms, types, patterns, and notation.** Implement precedence-aware formatting for applications, operators, binders, matches, records, projections, patterns, strings, numerals, syntax quotations, and antiquotations using parser/category information rather than textual guessing.
3. **RLF-TACTICS — Format tactic sequences, `do` notation, and layout-sensitive blocks.** Implement deterministic blocks for tactic scripts, bullets, case alternatives, `do`, `where`, `let`, and nested layout. Add deep nesting and comment-placement fixtures.
4. **RLF-EXTENSIONS — Handle macros and file-local syntax conservatively.** Define the extension registration boundary for known syntax kinds and a lossless default for custom syntax. Test syntax declared earlier in the same file, scoped notation, macro quotations, and mixed built-in/custom trees.
5. **RLF-FINAL — Close whole-language coverage and style policy.** Run the generated syntax-kind inventory, repository corpus, frozen mathlib sample, malformed cases, idempotence loop, and exact fresh-frontend differential. Record unsupported constructs explicitly and eliminate them or block.

## Evidence and verification

Every prompt writes `results/01-commands.md`-style result notes with commands, raw measurements,
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
