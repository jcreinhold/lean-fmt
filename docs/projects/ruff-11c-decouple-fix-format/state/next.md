# Next Proof Packet

- Stack: ruff-11c-decouple-fix-format
- First unresolved: 01-spec
- Claim ID: RDF-SPEC
- Prompt: 01-spec
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RDF-SPEC**: Specify the split of `prepareFile`'s single canonical patch into two independent concerns — a **layout patch** (`format`/`diff`: canonical reflow, no rule fix) and a **fix patch** (`fix`: admitted rule fixes at the file's own original coordinates, no reflow) — with `check` unchanged. Freeze the mode→patch mapping, name every mechanism that retires because fixes no longer cross the reflow, and prove the `ruff-11b` capability split and the `ruff-06` validator are untouched. Change no observable rule report; change what each mode *writes and previews*.
- Read `roadmap.md`; `ruff-06-fix-safety/notes/01-model.md` (the safe/unsafe/display-only applicability model, the atomic transaction, and the output re-elaboration validator); `ruff-10b-syntax-fix-composition/notes/01-model.md` (how a syntax `.safe` fix rides `reprojectCanonical` onto canonical text — the coordinate coupling this stack unwinds); `ruff-11b-owned-semantic-fix/notes/01-model.md` and `results/02-impl.md` §2 (FMT014's rename reaching `reprojectCanonical` with `captureOccurrences` — the decision this stack reverses in direction while keeping its result) and `results/03-final.md` §1 (the frozen fixable predicate); `ruff-04-formatter-product` and `ruff-09-import-rules` results for the origin of `RunMode.rendersCanonical` and the FMT005 canonical-coordinate fix; `AGENTS.md`; and the live seams before specifying an interface:
- `LeanFmt/Application.lean`: `RunMode` and `RunMode.rendersCanonical` (23-44), `RunRequest.unsafeFixes` (55-59), `renderCanonicalText`/`canonicalAnalysis` (379-395), `ExactRun.reprojectCanonical` and its `(captureSemantic captureOccurrences)` gate (418-440), `cacheHitServes`/`availableAnalysis` (469-519), `patchDuplicateFindings` (819-828), `prepareFile` with its `base`/`baseFindings` branch and the `admitted` gate (830-888), `RunMode.preview?` (890-899).
- `LeanFmt/Analysis.lean`: `analyzeExact`, `captureDeprecatedOccurrences`, `occurrenceOfInfo` — where the whole-file info trees are walked and occurrences resolved in normalized-source coordinates.
- `LeanFmt/ArtifactModel.lean`/`LeanFmt/Semantic.lean`: `SemanticResult`, `SemanticCaps`, the canonical sub-result (`result.canonical?`), and the capability field.

## Reuse

- see the target prompt's Read section

## Lean Work

Inspect the live goal, search relevant declarations, test plausible proof steps, and verify completed declarations.

## Stop Rules

- Do not specify `format`/`diff` applying or previewing any rule fix, or `fix` reflowing.
- Do not specify a fix computed at canonical coordinates; every fix rides the file's normalized bytes.
- Do not weaken the capability split, `Tier.satisfies` soundness, the validator, exact semantics, write safety, or cache identity, or give rules lifecycle authority.
