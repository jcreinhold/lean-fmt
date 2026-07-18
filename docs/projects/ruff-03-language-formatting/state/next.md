# Next Proof Packet

- Stack: ruff-03-language-formatting
- First unresolved: 13-reflow-accept
- Claim ID: RLF-REFLOW-ACCEPT
- Prompt: 13-reflow-accept
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLF-REFLOW-ACCEPT**: the acceptance for the **complete** reflow set. `RLF-ACCEPT` (`results/10`) accepted the subset that existed when it ran — `Term.app` β-break plus the `by`/`do` offside re-index — and cited operator/binder/`match`/record breaking as conservative-with-a-reason. Prompts `RLF-OPERATOR-BREAK` and `RLF-RECORDS` built that breadth; this prompt re-runs the acceptance over it and supersedes `RLF-ACCEPT`'s subset coverage claim.
- This is an **audit prompt**: it adds tests and evidence and changes production code only to fix a defect it finds. Read `roadmap.md`, `results/10-reflow-final.md` (the acceptance this extends), `results/11-operator-break.md` and `results/12-records.md`, `experiments/compare_tokens.py` and `experiments/run-printer-sample.sh`, `experiments/kind-inventory.txt`, and `AGENTS.md`.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Parse-preservation (token + tree) and idempotence are gates; a divergence is a blocker, not a footnote.
- Do not mark accepted any construct whose breaking is not proven parse-preserving by reparse.
- A coverage-table entry with no citation, or a *breaking* deferral with no owning prompt, is the defect this prompt exists to prevent — stop rather than ship one.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
