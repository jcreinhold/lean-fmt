---
kind: state
first_unresolved: 03-impl
---

# Current state

RDF-SPEC (01) is verified: the decoupled interface is frozen in `notes/01-model.md` and
`results/01-spec.md`, with six first-hand product probes in `evidence/01-fusion-and-subsumption.md`
(fusion, printer non-subsumption of ws/newline, and the pre-existing FMT001 in-string corruption the
retirement removes).

RDF-LAYOUT (02) is verified (`results/02-layout.md`): the canonical printer now owns
trailing-whitespace/final-newline normalization as layout, sound by construction (`trimTriviaWs` over
proven-trivia slices + `normalizeEof` once in `format`; `Printer.lean:219-292,1194-1195,1918,2151`), and
FMT001/FMT002 are deleted from `ruleRegistry` with every test-vehicle migrated onto surviving rules
(FMT005/FMT013/FMT014) plus three new formatter-ownership regressions (`tests/modes/run.sh:542-585`). This
landed before the patch split, so `format` still composes fixes today but the retired rules are gone. One
known non-green: `tests/printer/run.sh`'s stale-evidence census (541 vs live 660) against a frozen ruff-03
record the prompt forbids rewriting — pre-existing and out of scope (details in `results/02-layout.md`).

Next unresolved is 03-impl (RDF-IMPL), the patch split proper. It decouples lint-fix from formatting:
`format`/`diff` reflow
only (no rule fix applied or previewed) and `fix`/`check --fix` apply admitted fixes at the file's own
original coordinates (no reflow), so a user composes them as `ruff check --fix && ruff format`.

Its external prerequisite stacks are `ruff-06-fix-safety`, `ruff-09-import-rules`,
`ruff-10b-syntax-fix-composition`, and `ruff-11b-owned-semantic-fix`, all verified. This stack is the
forward unwinding of the canonical-coordinate fix composition those stacks built: it keeps every
surviving fix and the `ruff-11b` capability split, and
re-homes the surviving fixes (import FMT005, syntax `.safe`, semantic FMT014 — FMT001/FMT002 retire into
the formatter) onto original coordinates and onto `fix` alone. A `git revert` of 10b/11b was
rejected — it would delete their fix capabilities while leaving the coupling (FMT005 still rides
`canonical.findings`, `format` still applies fixes) intact, and the decoupled end state is a state no
prior commit occupied. Before starting, confirm those prerequisite roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RDF-SPEC | verified | — |
| 02-layout | RDF-LAYOUT | verified | RDF-SPEC |
| 03-impl | RDF-IMPL | planned | RDF-LAYOUT |
| 04-final | RDF-FINAL | planned | RDF-IMPL |

## Scope

- **In scope:** moving trailing-whitespace/final-newline normalization **into the formatter's layout**
  (the canonical printer trims only the whitespace trivia it emits and guarantees one final newline) and
  **retiring FMT001/FMT002** as lint rules, migrating their test vehicle onto surviving rules (RDF-LAYOUT);
  splitting `prepareFile`'s single canonical patch into a layout patch (`format`/`diff`, no fixes) and a
  fix patch (`fix`, admitted fixes at original coordinates); `RunMode.rendersCanonical := false` for
  `fix`; moving FMT014 occurrence capture and every rule fix onto the base (original-coordinate) analysis;
  retiring `reprojectCanonical`'s fix/occurrence role, the 11b reproject parameters,
  `patchDuplicateFindings`, and the `result.canonical?`-as-patch-source branch.
- **Out of scope:** a build-free/parse-only `layout` subcommand (a separate future stack — this stack
  does not change the frontend coupling: `format` and `fix` still require the file to elaborate); rule
  authoring and lifecycle (`ruff-12`); config discovery (`ruff-13`); a `fix --diff` preview beyond the
  existing `diff`=format-preview; the incremental cache (`ruff-16`) and cost budget (`ruff-19`).

## Blockers and prerequisites

- No blocker. `ruff-06-fix-safety`, `ruff-09-import-rules`, `ruff-10b-syntax-fix-composition`, and
  `ruff-11b-owned-semantic-fix` are verified. If live code contradicts a prerequisite result, reopen the
  owning prerequisite rather than patching around it. Full mathlib is not development evidence; use the
  frozen sample and named stress cases.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
