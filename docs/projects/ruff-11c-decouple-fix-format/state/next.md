# Next Proof Packet

- Stack: ruff-11c-decouple-fix-format
- First unresolved: 02-layout
- Claim ID: RDF-LAYOUT
- Prompt: 02-layout
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RDF-LAYOUT**: Make the canonical reflow the sole, sound owner of trailing-whitespace and final-newline normalization, and retire FMT001/FMT002 as lint rules. After this prompt, `Printer.format` output trims the trailing horizontal whitespace it lays down (in the whitespace *trivia* it emits — never token text, so string literals are safe **by construction**) and ends with exactly one final newline; FMT001 and FMT002 are gone from `ruleRegistry` and their rule definitions are deleted; and every persistent test that used FMT001/FMT002 as its fixable-source vehicle is migrated onto a surviving import/syntax/semantic rule. This lands **before** the RDF-IMPL patch split so `format` never regresses: while `format` still composes fixes (pre-split), the printer already owns ws/newline and FMT001/FMT002 no longer exist.
- Read `roadmap.md`, `results/01-spec.md` (the frozen resolution and the first-hand evidence that the printer does *not* subsume ws/newline today, and the FMT001 string-corruption defect), `notes/01-model.md`, `AGENTS.md`, `docs/adding-a-rule.md`, and the live seams before changing an interface.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- The formatter's ws/newline trim must be sound **by construction** — trivia only, never token/string bytes. If a test shows a string value changing under `format`, stop and fix the trim rather than narrowing the test.
- Do not leave FMT001/FMT002 dormant in the registry, and do not reintroduce a "format applies a rule fix" coupling — the ws/newline normalization is layout, unconditional, no `--unsafe-fixes` gate.
- Do not rewrite historical prerequisite-stack records. Do not give rules lifecycle authority.
