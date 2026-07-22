# Next Proof Packet

- Stack: ruff-12b-rule-graduation
- First unresolved: 03-graduate
- Claim ID: RGR-IMPL
- Prompt: 03-graduate
- Module: `LeanFmt/Rules.lean` (catalog fields, new preview-path field), `LeanFmt/Cli.lean` (`explain`),
  `LeanFmtTest.lean` (catalog invariant), `docs/rules/` (generated)
- Target file: `results/03-graduate.md`

## Target Declarations

- `RuleInfo.previewPath?` (or equivalent) — the §4 DOC-3 field carrying a preview rule's graduation
  condition, rendered by `explain` and the generated doc page.
- The catalog invariant pinning it nonempty **iff** `lifecycle == .preview`.
- `FMT013`: `lifecycle := .stable`, `defaultEnabled := false`.

## Read Before Editing

This file, `prompts/03-graduate.md`, `results/02-evidence.md` (the verdicts), `results/01-criteria.md`
§1 and §4 (outcomes and documentation standard), and the named source ranges only.

## Proof Task

Deliver **RGR-IMPL**: apply `results/02-evidence.md`'s verdict table. It is designed to be applied
without re-deciding anything — do not reopen a verdict here.

1. **FMT013 → `stable-optional`.** Set `lifecycle := .stable`, keep `defaultEnabled := false`. No new
   machinery: `LeanFmt/Config.lean:668-671` already expands `all` and category to every `.stable` rule
   regardless of `defaultEnabled`. Confirm by test that FMT013 becomes reachable by `all` and by
   `redundancy` **without** `--preview`, and stays absent from `default`.
2. **The other nine stay `.preview`,** each carrying its §1.5 graduation condition from
   `results/02-evidence.md`, in the DOC-3 field — **not** in prose in a result note. Prompt 03 requires
   the condition appear where a user sees it.
3. **Nothing is retired.** §1.3 and the verdict table both say so; `reservedCodes` is permanent and
   eight of these rules were judged on a corpus that could not exercise them.
4. **Record the Design B decision with the CP-2 measurement.** The trigger is unfired (no syntax rule
   reaches default), but unlike `ruff-19`'s bare re-check this stack measured what firing it would have
   cost: 33× against a 1.25× budget, 62 frontend children against 1.
5. **`ruff-19`'s gates need no re-derivation.** The default set is unchanged, and CP-1 showed the warm
   §1a/§1b/§1c gates survive even all ten preview rules selected. Confirm they still pass; do not
   re-derive what did not change.

## Reuse

- The lifecycle/selector machinery is complete (`ruff-12`). This prompt sets fields and adds one
  documented, invariant-enforced field. It does not need new selector logic.
- `LeanFmtTest.lean`'s `testCatalogInvariants` is where the DOC-3 invariant belongs, beside the existing
  lifecycle/default coherence checks at 895-905.
- The generated docs regenerate from the registry; `lake exe lean-fmt docs --check` gates drift.

## Lean Work

Inspect the live goal, search relevant declarations, test plausible steps, and verify completed
declarations. A rule's tier is its `RuleImpl` constructor and never a field (`CLAUDE.md`); this prompt
changes `lifecycle` and adds a documentation field, and moves nothing between tiers.

## Stop Rules

- Do not reopen a verdict. If one looks wrong, record the disagreement per `CLAUDE.md` and stop; do not
  silently re-decide.
- Do not add a declared tier field, and do not make `defaultEnabled` depend on build state (§1.4 refused
  that explicitly).
- Do not retire a rule to tidy the catalog.
- The DOC-3 field must be **enforced by an invariant**, or it will rot exactly as `CLAUDE.md` says a
  declared tier field would. An unenforced field is not an implementation of DOC-3.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- `LEAN_NUM_THREADS=1 lake build`, `lake exe lean-fmt-tests`, `lake lint`.
- `tests/catalog/run.sh`, `tests/syntax/run.sh`, `tests/semantic/run.sh`, `tests/modes/run.sh`,
  `tests/reporting/run.sh`, `tests/suppression/run.sh`, `tests/discovery/run.sh`.
- `tests/boundary/run.sh`; inspect every changed module boundary manually.
- `tests/performance/run.sh` and `tests/performance/negative.sh` — expect pass without re-derivation.
- `lake exe lean-fmt docs --check`.
- `lean-fmt explain` for FMT013 (must show `stable`, default off) and for one preview rule (must show
  its graduation condition).
- `git diff --check`, read in full.
- Structural checkers: expect the same 5 pre-existing `implementation_route` failures every lean-fmt
  stack has; confirm no new stack-shaped failure.
