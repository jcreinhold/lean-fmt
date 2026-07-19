# Next Proof Packet

- Stack: ruff-11c-decouple-fix-format
- First unresolved: 03-impl
- Claim ID: RDF-IMPL
- Prompt: 03-impl
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RDF-IMPL**: Implement the frozen split. `format`/`diff` render canonical layout and apply **no** rule fix; `fix` applies admitted fixes at original coordinates and does **not** reflow; `check` is unchanged. Move every rule fix and FMT014's occurrence capture onto the base (original-coordinate) analysis, retire the canonical-coordinate fix machinery, and keep the `ruff-11b` capability split and the `ruff-06` validator/transaction intact. Remove the retired path; do not leave a parallel one.
- Read `roadmap.md`, `results/01-spec.md` (the frozen interface and the chosen design), `results/02-layout.md` (ws/newline is now the formatter's layout and FMT001/FMT002 are retired — do **not** treat them as live rules or as the fix vehicle here), `notes/01-model.md`, `AGENTS.md`, and the current implementation and tests before changing an interface. Write or update the characterization tests that pin `format`-applies-no-fix and `fix`-at-original-coordinates before the implementation where the behavior is not already frozen.
- RDF-LAYOUT precedes this prompt: the printer already owns trailing-whitespace/final-newline normalization and FMT001/FMT002 no longer exist, so the surviving fix vehicles are **import** (FMT005), **syntax** (a `.safe` fix such as FMT013), and **semantic** (FMT014). There is no source-tier fixable rule left; a default `format`/`check` still resolves to `requiredTier == .source` via FMT003/FMT004 (report-only) and keeps the source-only shortcut.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- `format`/`diff` must apply no rule fix; `fix` must not reflow. Do not blend them to make a test pass.
- No fix computed or applied at canonical coordinates. Do not weaken the capability split, the validator, exact semantics, write safety, or cache identity.
- Stop rather than leaving both the new and the retired path live, or giving rules lifecycle authority.
