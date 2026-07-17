---
kind: roadmap
topic: "Complete Lean language formatting"
main_results: [RLF-ACCEPT]
prereq_stacks: [ruff-02-layout-core, ruff-05b-semantic-facts]
blueprint_tracked: false
---

# Complete Lean language formatting

## Goal

Implement canonical, idempotent, **reflowing** formatting for Lean modules, headers, commands,
declarations, terms, types, patterns, tactics, `do` notation, quotations, macros, and file-local
syntax without losing comments or changing exact semantics. "Reflowing" (ruff/Black-class, decided with
the user 2026-07-17) means: normalize spacing *and* rebreak over-width constructs to a target margin,
respecting Lean's offside and column-sensitivity, not merely canonicalize within the author's existing
line structure. The governing ceiling is Lean's whitespace-sensitivity: a reflow that changes the parse
is a bug, never a style choice.

This stack runs in two phases. **Phase 1** (`RLF-COMMANDS`..`RLF-FINAL`, verified) shipped the
formatting provably safe with the facts and primitives available, and characterized — with parser
citations — why the rest was deferred; it is a no-op on already-canonical Lean by construction. **Phase
2** (`RLF-NOTATION`..`RLF-ACCEPT`) builds the deferred capability: it *consumes* declared notation
spacing from the `ruff-05b-semantic-facts` foundation, adds a parse-preserving offside re-indent,
margin-driven line breaking, and record/tactic/`do` layout. The declared-spacing fact is **not** built
here — it needs the frontend `Environment`, so it is a semantic-tier fact owned by `ruff-05b`; phase 2
only reads it. The architecture, the design-twice, and the layer map are
`notes/05-reflow-architecture.md`.

## Completion contract

- Every supported parser category has an explicit ownership table and formatter fallback; accepted syntax is never silently dropped.
- Unknown/custom syntax preserves its token subtree and comments conservatively until a registered structural formatter exists.
- Formatting twice is byte-identical to formatting once (**idempotence**), and the output reparses to
  the same token and comment stream as the input (**parse-preservation**), verified by a fresh-frontend
  differential rather than asserted.
- Reflowed constructs are rebroken only where the break provably preserves the parse (`checkColGt`/
  `checkColGe`/`checkColEq` respected); a construct whose reflow would drop a comment or change the
  parse keeps its bytes.
- Operator/notation spacing is the *declared* atom string, read from the parser table as a fact while
  the frontend `Environment` is live — the printer never holds an `Environment`.
- The target margin (default 100, mathlib convention) is reviewed product policy and enters cache
  identity; mathlib is characterization input, not an authority that forces unstable accidental style.

## Work order

### Phase 1 — conservative foundation (verified)

1. **RLF-COMMANDS — Format modules, headers, imports, namespaces, and declarations.** Add category dispatch and canonical layouts for module headers, imports, namespaces/sections, attributes, binders, declarations, structures, inductives, and command comments. Establish golden and idempotence tests.
2. **RLF-EXPRESSIONS — Format terms, types, patterns, and notation.** Implement precedence-aware formatting for applications, operators, binders, matches, records, projections, patterns, strings, numerals, syntax quotations, and antiquotations using parser/category information rather than textual guessing.
3. **RLF-TACTICS — Format tactic sequences, `do` notation, and layout-sensitive blocks.** Implement deterministic blocks for tactic scripts, bullets, case alternatives, `do`, `where`, `let`, and nested layout. Add deep nesting and comment-placement fixtures.
4. **RLF-EXTENSIONS — Handle macros and file-local syntax conservatively.** Define the extension registration boundary for known syntax kinds and a lossless default for custom syntax. Test syntax declared earlier in the same file, scoped notation, macro quotations, and mixed built-in/custom trees.
5. **RLF-FINAL — Close conservative-coverage inventory and style policy.** Run the generated syntax-kind inventory, repository corpus, frozen mathlib sample, malformed cases, idempotence loop, and exact fresh-frontend differential for the conservative subset. Record unsupported constructs explicitly. (Phase 1's acceptance; its "whole-language coverage" is the *conservative* subset — the reflow coverage is `RLF-ACCEPT`.)

### Phase 2 — reflowing formatter (`notes/05-reflow-architecture.md`)

6. **RLF-NOTATION — Consume the notation-spacing fact to canonicalize operator spacing.** Use the declared notation/atom spacing fact produced by `ruff-05b-semantic-facts` (carried in the `v4` artifact) to give operators and notations their declared spacing (`a+b` → `a + b`); conservative fallback where no fact is present. The printer gains no `Environment` — it reads the immutable fact. The fact itself is `ruff-05b`'s, not this stack's.
7. **RLF-OFFSIDE — Provide a parse-preserving re-indent for offside blocks.** Deliver the capability to emit a multi-line block at a canonical base column preserving every internal `colEq`/`colGt`/`colGe`, proven by fresh-frontend reparse. Design twice (new `Doc` constructor vs printer-side reconstruction); reopen `ruff-02` only if a constructor wins. Not column-alignment.
8. **RLF-REFLOW — Reflow expressions to the target width.** Emit `group`/`nest`/`line` so applications, operators, notations, binders, and matches break across lines when they exceed the margin (default 100), every break respecting `checkColGt`. First layout that makes the engine decide.
9. **RLF-BLOCKS — Lay out records and offside blocks.** Apply `RLF-OFFSIDE` to `structInst` records and tactic/`do`/`where`/`let` blocks at canonical indentation, preserving the offside separators; conservative fallback where a re-layout cannot be proven parse-preserving.
10. **RLF-ACCEPT — Close the reflowing formatter.** Idempotence loop, exact fresh-frontend differential, reflow coverage table with citations, and the performance envelope over the corpus and frozen mathlib sample. Supersedes `RLF-FINAL`'s coverage claim; zero silently unowned reflow behaviour.

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
