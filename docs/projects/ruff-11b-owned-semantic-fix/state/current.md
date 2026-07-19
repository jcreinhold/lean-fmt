---
kind: state
first_unresolved: 03-final
---

# Current state

**ROS-IMPL verified — the owned fixable FMT014, the info-tree capability split, and the semantic
fix's canonical re-projection are shipped (`results/02-impl.md`).** The owned
`DeprecatedOccurrence` fact is captured from the whole-file info trees **under demand only**
(`tree.getAll.filterMap (·.infoTree?)` consumer fold in `analyzeExact`, gated on `captureOccurrences`;
`artifactSchema v6`), resolved to `(range, declName, newName?, since?, text?, fixable)` in
normalized-source coordinates with the declaration-site binder excluded and dedup by range. FMT014's
`unsafe` rename attaches by range-identity match in `deprecatedUse` and rides `ruff-06`'s
applicability/conflict/transaction/re-elaboration path. The Design-B capability split ships
(`SemanticCaps`, `SemanticResult v7`, `cacheHitServes` requiring `demandedCaps.subset caps`,
`RulePlan.demandedCaps`), so a monolithic-era `.semantic` entry misses a fixable-FMT014 demand rather
than serving a false clean, and the info-tree walk is paid only by a canonical render that selects
FMT014.

**Decision changed during ROS-IMPL (recorded in `results/02-impl.md` §2):** the semantic fix reaches the
**same** `ExactRun.reprojectCanonical` seam a syntax fix does. `prepareFile` draws the patch from
`canonical.findings`, so the original-source occurrence cannot supply the patch's coordinates — the walk
re-projects onto the *rendered* text under the occurrence capability, and FMT014's rename lands at
canonical coordinates. This is a faithful, more-literal reading of the frozen model's "exactly as
`ruff-10b` routes a syntax fix" (`notes/01-model.md` §6), not a deviation; the model had not spelled out
that the semantic tier shares that re-projection seam. Also recorded: Lean's derived `ToJson` strips the
trailing `?` from an `Option` field name (wire keys `occurrences`/`newName`/`since`/`text`).

Verified against live code and the full gate set: `lake build`, `lake exe lean-fmt-tests`,
`tests/{semantic,modes,check,syntax,service,compiler,boundary}/run.sh`, the structural checker,
`write_next.py --check`, and `git diff --check` — all green (`results/02-impl.md` §6).

**ROS-SPEC verified — the interface is frozen (`notes/01-model.md`, `results/01-spec.md`).** A
first-hand probe (`evidence/infotree_probe.lean`, output `evidence/01-infotree-probe.txt`) settled the
one open question `ruff-11` §8 left: the whole-file info trees are reachable through the **same**
`toSnapshotTree(snapshot).getAll` walk `analyzeExact` already runs for the message log, via each
`Snapshot.infoTree?` — a **consumer-side fold** (`tree.getAll.filterMap (·.infoTree?)`), **not** the
"distinct producer change" §8 assumed. The probe resolved both deprecated use-sites from two distinct
command trees and read every owned-fact field (`range`, `declName`, `newName?`, `since?`, `text?`) plus
the two design obligations it surfaces: exclude the declaration site (`isBinder = true`) and dedup by
range (each use emits its `TermInfo` twice). This **refines** §8 (recorded honestly in
`results/01-spec.md` §5) and makes ROS-IMPL smaller than §8 assumed; the capability split is still
adopted, now justified by the fold + info-tree-retention cost rather than a producer rewrite.

Frozen for ROS-IMPL: the owned `DeprecatedOccurrence` fact `(range, declName, newName?, since?, text?,
fixable)`; the **bare-identifier fixable predicate** (`newName? = some`, non-binder, bare `.const`,
unambiguous re-resolving source spelling — everything else stays report-only); **Design B** the
capability split (`SemanticCaps {notations, diagnostics, occurrences}`, `Option` sub-fields with
`none`=not-captured/must-miss vs `some`=captured-possibly-empty, `SemanticResult v6 → v7`,
`cacheHitServes` requiring `demandedCaps ⊆ caps` beside the unchanged `tier.satisfies`); the `unsafe`
rename riding `ruff-06`'s admission/conflict/transaction/re-elaboration path unchanged
(`ruff-10b`'s non-source-tier discipline); and the demand trigger (`RulePlan.demandedCaps`, the
surfaced-only `check` path and integrated builds untouched). Design A′ (stay monolithic) is the
recorded rejected alternative.

This successor stack holds the one deferral `ruff-11`'s
RMR-SPEC named and no later stack owns: the **owned, fixable FMT014** (a validated `unsafe` rename of a
bare-identifier deprecated-declaration occurrence to its replacement) and the **info-tree capability
split** (`ruff-11-semantic-rules/notes/01-authority.md` §§6,8). FMT014 ships today as a *surfaced*,
report-only rule (`fixable:false`); its structured fix is deferred behind the whole-file info-tree
capture pitfall, and Design B (the capability split that keeps that expensive walk off every `format`
run) is frozen but unimplemented. This is the semantic analog of `ruff-10b`, which held the
`fix`-composition wiring `ruff-06` specified until a real syntax rule could drive it; here `ruff-11`'s
FMT014 is the real rule.

The substrate is characterized and verified in RMR-SPEC: `deprecatedAttr.getParam? env declName`
returns `{newName?, since?, text?}` from `Environment` data retained for imported public decls
(`Elab/Deprecated.lean`, `Attributes.lean`), demonstrated in
`ruff-11-semantic-rules/evidence/01-semantic-diagnostics.txt`; the per-occurrence resolution needs the
info tree (`TermInfo`/`addConstInfo`, `InfoTree/Main.lean:344-353`); and the capability model
(`SemanticCaps`, `Option` sub-fields, `SemanticResult v6 → v7`, `cacheHitServes` `demandedCaps ⊆ caps`)
is sketched in RMR-SPEC §6. ROS-SPEC re-derives these first-hand against the live compiler and product
seams rather than trusting recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | ROS-SPEC | verified | — |
| 02-impl | ROS-IMPL | verified | ROS-SPEC |
| 03-final | ROS-FINAL | planned | ROS-IMPL |

## Scope

- **In scope:** the owned deprecation-occurrence fact (whole-file info-tree capture, gated on demand),
  FMT014's `unsafe` rename through `ruff-06`'s applicability/conflict/transaction/validator path, and
  the Design-B capability split (`SemanticCaps`, schema bumps, `cacheHitServes` `⊆`).
- **Out of scope:** the four surfaced semantic rules FMT014–FMT017's report behavior (owned by
  `ruff-11`, unchanged); rule authoring and lifecycle/fixability *controls* (owned by `ruff-12`); the
  incremental cache (`ruff-16`) and the default-run cost budget (`ruff-19`). This stack owns the owned
  fact, its fix, and the capability that gates its capture.

## Blockers and prerequisites

- No blocker. Prerequisites `ruff-06-fix-safety`, `ruff-10b-syntax-fix-composition`, and
  `ruff-11-semantic-rules` are all verified. The fix-composition model (`ruff-06` RFX-SPEC), the
  non-source-tier fix wiring (`ruff-10b` RYC), and the owned-fact/capability model (`ruff-11` RMR-SPEC
  §§6,8) are frozen; this stack holds their union — the info-tree capture, the applied rename, and the
  split.
- If live code contradicts a prerequisite result, reopen the owning prerequisite rather than patching
  around it. Full mathlib is not development evidence; use the frozen sample and named stress cases.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful
evidence, and state agrees with live code. Missing, stale, unsupported, or unread checks are failures
to verify.
