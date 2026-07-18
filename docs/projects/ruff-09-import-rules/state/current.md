---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RIR-IMPL` is **verified**: the import family from `notes/01-semantics.md` ships — FMT005 duplicate
(safe fix), FMT006 redundant (report-only, withholding count recorded), FMT007 order/grouping
(report-only), and one private `organize` command that rewrites only after re-elaboration validates.
The rules live *outside* the linear-tier `RuleImpl` engine (the syntax projection drops the header
region the rules read, and redundancy is a graph fact a pure rule cannot compute), merged into the
report post-cache/pre-selection; FMT006 is recomputed fresh every run because it depends on other
files through the Lake graph. Result note: `results/02-implementation.md`. The external prerequisite
stacks `ruff-01-lossless-source`, `ruff-05-rule-engine`, and `ruff-06-fix-safety` remain verified and
still match live code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-semantics | RIR-SPEC | verified | — |
| 02-implementation | RIR-IMPL | verified | RIR-SPEC |
| 03-acceptance | RIR-FINAL | planned | RIR-IMPL |

## What RIR-IMPL delivered (for 03-acceptance to differentially probe)

- **`LeanFmt/Imports.lean`** — pure header rules (`duplicateFindings`, `orderFindings`,
  `redundantFindings … closureOf`, `organize`), called directly rather than through the engine.
- **`Project.importClosures`** — one shared `transImports` fetch across all targets, graceful miss.
- **`Application`** merge — import findings gated on selection, reported at `normalized` coordinates;
  the FMT005 fix recomputed at `canonical.text`; `withheldRedundant` threaded into the report.
- **`organize` CLI command** — pure candidate, validate-by-re-elaboration only when a file changes.
- **Gates:** new `tests/imports/run.sh` (CLI pipeline over `module` fixtures) and `testImports`
  characterization; `rules --json` catalog golden extended to FMT001–FMT007.

## Open threads RIR-FINAL owns

- **FMT006 withholding is conservative by design** (§5): `all`/`meta`/re-export ⇒ withheld and only
  counted. `withheldRedundant` exposes the count so acceptance can measure how often it declines.
- **Elaboration-significant order:** the default `fix` must never reorder (the compiler reads the
  header in order); only the explicit `organize` command rewrites. Acceptance owns the
  order-significant and comment-preservation differentials.
- **Fix conflicts, suppressions, scoped-syntax / plugin / prelude cases, frozen-sample performance.**

## Notes recorded during RIR-IMPL

- `notes/01-semantics.md` §6 speaks of a "`runRulesOf` synthetic-registry seam" for the header rules.
  That seam presupposes the rules are engine `RuleImpl`s, which §1b/§7 of the same note decided
  against; the implementation honors §1b/§7 (rules outside the engine) and tests call `Imports.*`
  directly. The §6 phrasing is stale spec prose, not an unbuilt obligation.
- The source-boundary gate (`tests/boundary/run.sh`) was scoped to exclude `docs/*` evidence probes,
  which are run by hand and never compiled — the RIR-SPEC probe is legacy (non-`module`) on purpose
  because `parseImports'` is `meta`-gated. This makes the `results/01` "boundary passes" claim durably
  true (it was true when run, false once the untracked probe was committed).

## Blockers and prerequisites

- No blocker recorded.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
