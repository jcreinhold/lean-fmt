# Next Proof Packet

- Stack: ruff-11b-owned-semantic-fix
- First unresolved: 01-spec
- Claim ID: ROS-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **ROS-SPEC**: Specify the owned deprecation-occurrence fact, the bare-identifier fixable predicate, and the info-tree capability split that lets FMT014's whole-file info-tree walk be paid only when the fix is demanded — honoring the model `ruff-11`'s RMR-SPEC §§6,8 froze, without changing the surfaced FMT014 report, the semantic-tier soundness, or the source/syntax/semantic fast paths.
- Read `roadmap.md`, `ruff-11-semantic-rules/notes/01-authority.md` §§5,6,8,10 (range recovery, the two demand designs, the owned/fixable enhancement, toolchain behavior), `ruff-11-semantic-rules/results/01-authority.md` (the first-hand compiler evidence and locators), `ruff-11-semantic-rules/evidence/01-semantic-diagnostics.txt` and `evidence/fixtures/` (the reproducible `deprecatedAttr.getParam?` query and the diagnostics fixture), `ruff-06-fix-safety/notes/01-model.md` (the safe/unsafe/display-only applicability model and the output re-elaboration validator), `ruff-10b-syntax-fix-composition/notes/01-model.md` (how a non-source-tier fix already rides the `ruff-06` transaction path), `AGENTS.md`, and the live seams — `LeanFmt/Analysis.lean` (`analyzeExact`, the snapshot-tree walk that already assembles the whole-file `MessageLog`, `captureDiagnostics`), `LeanFmt/ArtifactModel.lean` (`SemanticProjection`, `Diagnostic`, the `v5` schema), `LeanFmt/Rules.lean` (the surfaced FMT014 and `SemanticFacts`), `LeanFmt/Semantic.lean` (`SemanticResult`, `ofEnvelope?`, the `tier` tag), `LeanFmt/Application.lean` (`cacheHitServes`, `demandedTier`, the fix/publish path), and the relevant Lean sources (`InfoTree/Main.lean`, `Frontend.lean`, `Elab/Deprecated.lean`, `Command.lean`) — before specifying an interface.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not specify a rename applied to any occurrence a textual swap cannot preserve; the fix is bare-identifier only and `unsafe`.
- Do not let the info-tree walk be demanded by anything but the fixable capability; do not weaken `Tier.satisfies` soundness or let a monolithic-era entry serve a fixable demand.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope, or giving rules lifecycle authority.
