---
kind: state
first_unresolved: none
---

# Current state

**The stack is complete: `RIR-SPEC`, `RIR-IMPL`, and `RIR-FINAL` are all verified.** The import family
specified in `notes/01-semantics.md` ships and is differentially accepted: FMT005 duplicate (safe
fix), FMT006 redundant (report-only, withholding), FMT007 order/grouping (report-only), and one
private `organize` command. The external prerequisite stacks `ruff-01-lossless-source`,
`ruff-05-rule-engine`, and `ruff-06-fix-safety` remain verified and still match live code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-semantics | RIR-SPEC | verified | — |
| 02-implementation | RIR-IMPL | verified | RIR-SPEC |
| 03-acceptance | RIR-FINAL | verified | RIR-IMPL |

## What the stack delivered

- **`LeanFmt/Imports.lean`** — pure header rules (`duplicateFindings`, `orderFindings`,
  `redundantFindings … closureOf`, `organize`), outside the linear `RuleImpl` engine because the
  syntax projection drops the header region the rules read and redundancy is a graph fact a pure rule
  cannot compute.
- **`Project.importClosures`** — one shared `transImports` fetch across all targets, graceful miss.
- **`Application`** merge — import findings gated on selection, reported at `normalized` coordinates,
  the FMT005 fix recomputed at `canonical.text`; `withheldRedundant` threaded into the report; FMT006
  recomputed fresh every run (it depends on other files through the graph, so it never enters the
  source-digest cache).
- **`organize` CLI command** — pure candidate, validate-by-re-elaboration only when a file changes.
- **Gates:** `tests/imports/run.sh` (CLI pipeline: the three diagnostics, selection, organize
  check/write, suppression, fix-no-reorder, fix-conflict), `testImports` characterization (rules +
  organizer comment/modifier preservation), `rules --json` catalog golden (FMT001–FMT007), and
  `evidence/03-acceptance.lean` (header-rewrite invariants transcript).

## Acceptance measurements (`results/03-acceptance.md`)

- Comment / modifier / prelude / blank-group preservation: 18/18 evidence checks `ok`.
- Order is elaboration-significant → default `fix` never reorders; only `organize` rewrites, validated.
- Suppression composes (trailing `ignore[FMT005]` and top-of-file `ignore-file` both suppress).
- Fix conflict: dedup + trailing-whitespace fix compose to a valid file.
- On the 75-module project tree: FMT007×16, FMT005×1, FMT006×1 reported, **withheldRedundant = 18**
  (`import all` / `meta` / re-export candidates the conservative rule declines). Whole-project scan
  3.63 s / ≈1.0 GiB, import layer negligible (one shared graph fetch, no per-file subprocess).

## Notes recorded during the stack

- `notes/01-semantics.md` §6 speaks of a "`runRulesOf` synthetic-registry seam" for header rules; that
  presupposes engine `RuleImpl`s, which §1b/§7 decided against. Tests call `Imports.*` directly. Stale
  spec prose, not an unbuilt obligation.
- The source-boundary gate (`tests/boundary/run.sh`) was scoped to exclude `docs/*` evidence probes
  (run by hand, never compiled; the RIR-SPEC probe is legacy non-`module` because `parseImports'` is
  `meta`-gated). This makes the `results/01` "boundary passes" claim durably true.
- `ignore-next` / leading line directives in the header scope to the next *command*, not the next
  import, and honestly report `FMT900` when unused; a trailing directive on the import line suppresses.
  Characterized, not a defect (extending it is the RSP suppression model's charter).
- A "multi-module `check` fails with `no such file`" observation was later run down and proved to be a
  **shell artifact, not a harness bug**: the repro passed modules through an unquoted `$mods` under zsh,
  which does not word-split, so the whole list arrived as one path. Separate args pass (`files=21`).
  Fixed the diagnostic anyway — `Project.load` pre-checks existence and throws `selected file does not
  exist: <path>` in the caller's own terms; guarded in `tests/check/run.sh`. `LeanFmt/Analysis.lean` is
  a tracked-but-unglobbed orphan source (genuinely out of scope).

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
