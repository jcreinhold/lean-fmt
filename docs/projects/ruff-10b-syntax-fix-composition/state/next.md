# Next Proof Packet

- Stack: ruff-10b-syntax-fix-composition
- First unresolved: 01-spec
- Claim ID: RYC-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RYC-SPEC**: Specify the seam that lets `fix` apply a syntax-tier rule's `.safe` fix by re-projecting the rendered canonical text, honoring the model `ruff-06`'s RFX-SPEC froze, without changing `check`, cache identity, or the source-only fast path.
- Read `roadmap.md`, `ruff-06-fix-safety/notes/01-model.md` §3 (the frozen composition model), `ruff-06-fix-safety/results/03-acceptance.md` (the handed-forward adversarial cases), `AGENTS.md`, and the live fix lifecycle — `LeanFmt/Application.lean` (`renderCanonicalText`, `canonicalAnalysis`, the fix/publish path), `LeanFmt/Rules.lean` (the FMT010/011/013 `.safe` fixes and their coordinate basis), and the `ruff-06` transaction/applicability/conflict code — before specifying an interface.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not specify translating original-coordinate edits onto moved canonical bytes; the frozen model is re-projection.
- Do not let the applied artifact depend on fix pass order.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope, or giving rules lifecycle authority.
