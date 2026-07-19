# RDF-SPEC results — the decoupled patch interface, frozen

Status: **verified** (specification prompt). The interface is complete, sourced first-hand against the
live seams (file:line below) and against runtime probes (`evidence/01-fusion-and-subsumption.md`), and is
buildable in principle without changing any rule's report. Full model in `notes/01-model.md`.

## Commands run

- `LEAN_NUM_THREADS=1 lake build` → clean (42 jobs); with the temporary `StringWs` fixture, 57 jobs.
- Six product probes through `.lake/build/bin/lean-fmt` (`--no-cache`), transcript in
  `evidence/01-fusion-and-subsumption.md`. Probe fixture `tests/check/StringWs.lean` and its
  `lakefile.lean` root were added, exercised, then removed; `git status` and a clean 42-job rebuild
  confirm the tree is restored.
- `check_prompt_architecture.py` and `write_next.py --check` (below).

## Frozen interface

**Two concerns, one mapping.**

| Mode | `rendersCanonical` | Patch base | Patch carries | Publishes |
| --- | --- | --- | --- | --- |
| `check` | false | normalized | (no published patch) | no |
| `format` | true | `canonical.text` | **no rule fix** (layout only) | no |
| `diff` | true | `canonical.text` | **no rule fix** (layout only) | no |
| `fix` | **false** (was true) | `normalized` | admitted fixes at original coords | yes |

Layout patch iff `renderCanonical`; fix patch iff `!renderCanonical`. `check`/`fix` share the fix-patch
computation; only `fix` publishes. Report (`FileReport.findings`) is `result.findings` at original
coordinates in **every** mode — invariant under the split.

**Whitespace/newline → formatter layout; FMT001/FMT002 retire.** The printer subsumes neither today
(probe 5); ws/newline moves into the canonical printer as trivia-only trim + guaranteed final newline
(RDF-LAYOUT, before the patch split), and FMT001/FMT002 retire as lint rules. This also kills the
pre-existing FMT001 in-string-corruption defect by construction. No source-tier fixable rule survives;
surviving fix tiers are import/syntax/semantic. FMT003/FMT004 stay report-only source-tier → default
`requiredTier == .source` and the source-only fast path are preserved.

**Report policy.** `format`/`diff` keep reporting original-coordinate findings; only the patch loses
fixes. Rejected: silent `format` (Ruff-style) — deferred, out of scope.

## Evidence locators (live seams, verified this commit)

| Fact | Location |
| --- | --- |
| `RunMode.rendersCanonical` (`format\|diff\|fix => true`) — flip `fix` to false | `Application.lean:42-44` |
| `prepareFile` base/findings branch on `renderCanonical` | `Application.lean:865-872` |
| Report `selected` from `result.findings ++ reportImports` (original coords, invariant) | `Application.lean:856` |
| `reprojectCanonical` + `(captureSemantic captureOccurrences)` — retire entirely | `Application.lean:418-428` |
| `analyzeSnapshot` reprojection arm — retire with it | `Application.lean:439-441` |
| `availableAnalysis` `renderCanonical && requiredTier == .syntax` branch — remove | `Application.lean:511-517` |
| Source-only fast shortcut (preserved for default check/format) | `Application.lean:495-510` |
| `cacheHitServes` tier + `demandedCaps.subset caps` gate (preserved) | `Application.lean:485-486` |
| `patchDuplicateFindings` / canonical `patchImports` — retire | `Application.lean:824-828`, `:871` |
| `renderCanonicalText` `findings := runSourceRules` (canonical source-rule surface, dead after split) | `Application.lean:379-382` |
| `demandedCaps.occurrences := renderCanonical && selectsOccurrenceRule` — rewire to apply signal | `Config.lean:326-331` |
| `demandedTier` (renderCanonical → `.semantic`) — no rewire needed | `Config.lean:302-303` |
| FMT001 byte-level trim (source-tier, in-string corruption) — retire | `Rules.lean:197-215` |
| FMT002 final-newline (source-tier) — retire | `Rules.lean:217-230` |
| FMT003/FMT004 report-only source-tier (`fix? := none`) — keep, hold the fast path | `Rules.lean:697,707` |
| FMT014 `deprecatedUse` fix from `occ.range` (original coords) | `Rules.lean:633-642` |
| Registry FMT001/FMT002 `defaultEnabled := true`, `.source` | `Rules.lean:668-688` |
| Surviving syntax `.safe` fixables FMT010/FMT011/FMT013 | `Rules.lean:729-768` |

## First-hand probe results (see `evidence/`)

1. Fusion — `format` applies FMT001 (`findings=1 changed=1`, trailing ws gone).
2. Non-subsumption (ws) — FMT001 deselected → `changed=0`, ws retained.
3. StringWs — FMT001 (in-string) and FMT002 both fire, both `.safe`.
4. Default `format` on StringWs → `"alpha   \n…"` becomes `"alpha\n…"` (in-string corruption) **and**
   final newline appended.
5. Non-subsumption (both) — FMT001+FMT002 off → canonical text equals input exactly (`changed: False`).
6. `fix` **writes** the corrupted string (`written=1 rejected=0`); the re-elaboration validator misses it.

## Boundary design decision

**Design A — a `PatchKind` (`layout | fix | none`) inside `prepareFile`** — chosen over **Design B**
(`prepareLayout`/`prepareFix` split dispatched by the caller). A keeps the coordinate-system choice inside
`prepareFile` and shares the suppression/admission/conflict/count body by construction; B pushes
coordinate knowledge up to the caller and duplicates the shared body. Full comparison in
`notes/01-model.md` §8.

## `demandedCaps` rewire trigger (frozen)

`occurrences` is demanded iff the run **applies** fixes (mode `= fix`) **and** selects an occurrence-fix
rule. Thread an `applies : Bool` (true only for `.fix`) into `demandedCaps`/`cacheHitServes` in place of
`renderCanonical` for the `occurrences` field; keep `notations := renderCanonical`,
`diagnostics := requiredTier == .semantic`. `demandedTier` unchanged. Details in `notes/01-model.md` §6.

## Structural checks

- `check_prompt_architecture.py` → `checked 1 stack(s): 0 error(s), 0 warning(s)`.
- `write_next.py --check` → `OK: state/next.md matches first_unresolved='01-spec'`.
- `git diff --check` → clean.

## Remaining uncertainty

- `CanonicalText.findings` deletion vs leave-unpopulated is RDF-IMPL's call; grep for a non-patch reader
  first.
- The exact printer trivia mechanism (trim `Doc` nodes as built vs token/trivia-aware post-pass) is
  RDF-LAYOUT's; this spec freezes only *sound by construction, trivia-only*.
