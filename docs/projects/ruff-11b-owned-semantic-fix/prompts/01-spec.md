---
claim_id: ROS-SPEC
status: verified
depends_on: []
---

# Freeze the owned-occurrence projection and the capability split

## Task

Deliver **ROS-SPEC**: Specify the owned deprecation-occurrence fact, the bare-identifier fixable
predicate, and the info-tree capability split that lets FMT014's whole-file info-tree walk be paid only
when the fix is demanded — honoring the model `ruff-11`'s RMR-SPEC §§6,8 froze, without changing the
surfaced FMT014 report, the semantic-tier soundness, or the source/syntax/semantic fast paths.

Read `roadmap.md`, `ruff-11-semantic-rules/notes/01-authority.md` §§5,6,8,10 (range recovery, the two
demand designs, the owned/fixable enhancement, toolchain behavior),
`ruff-11-semantic-rules/results/01-authority.md` (the first-hand compiler evidence and locators),
`ruff-11-semantic-rules/evidence/01-semantic-diagnostics.txt` and `evidence/fixtures/` (the reproducible
`deprecatedAttr.getParam?` query and the diagnostics fixture), `ruff-06-fix-safety/notes/01-model.md`
(the safe/unsafe/display-only applicability model and the output re-elaboration validator),
`ruff-10b-syntax-fix-composition/notes/01-model.md` (how a non-source-tier fix already rides the
`ruff-06` transaction path), `AGENTS.md`, and the live seams — `LeanFmt/Analysis.lean`
(`analyzeExact`, the snapshot-tree walk that already assembles the whole-file `MessageLog`,
`captureDiagnostics`), `LeanFmt/ArtifactModel.lean` (`SemanticProjection`, `Diagnostic`, the `v5`
schema), `LeanFmt/Rules.lean` (the surfaced FMT014 and `SemanticFacts`), `LeanFmt/Semantic.lean`
(`SemanticResult`, `ofEnvelope?`, the `tier` tag), `LeanFmt/Application.lean` (`cacheHitServes`,
`demandedTier`, the fix/publish path), and the relevant Lean sources (`InfoTree/Main.lean`,
`Frontend.lean`, `Elab/Deprecated.lean`, `Command.lean`) — before specifying an interface.

## Target

- Specify the capability behind the existing private intent-to-report architecture; keep CLI
  presentation in `LeanFmt.Cli` and lifecycle/cache/project complexity below callers. Rules gain no
  parser or application-lifecycle authority; no `Environment`, `InfoTree`, `Position`, or `FileMap`
  crosses into a rule.
- Characterize first-hand where the whole-file info trees are reachable: whether the snapshot tree
  `analyzeExact` already walks (`toSnapshotTree`/`getAll`, the path that assembles `messages`) carries
  every command's info tree, or the incremental tree (`Frontend.lean:118-122,357-358`) is required.
  Record the pitfall — info state reset per command (`Command.lean:642-643`) means
  `waitForFinalCmdState?` holds only the final command's trees — with a reproducible probe.
- Freeze the per-occurrence owned fact `(range, declName, newName?, since?, text?)` in normalized-source
  coordinates (the one system `mkInputContext` establishes, RMR-SPEC §5), and the **bare-identifier
  fixable predicate**: what an occurrence must be for a textual rename to `newName?` to preserve meaning
  (a bare identifier resolving to the deprecated constant, not dot-notation, not an applied receiver,
  not `open`-shadowed, not macro-scoped). State how the predicate is decided from the info-tree fact,
  and that every non-qualifying occurrence stays report-only.
- Freeze the capability model: the `SemanticCaps` shape, `Option` sub-fields (none = not captured vs
  some = captured-possibly-empty), the `SemanticResult v6 → v7` field recording captured caps, and the
  `cacheHitServes` extension requiring `demandedCaps ⊆ entry caps`. Give the argument that `Tier.satisfies`
  stays a **sound** gate and that a monolithic-era entry (notations + diagnostics, no occurrence cap)
  misses a fixable-FMT014 demand rather than serving a false clean. State the demand trigger — an FMT014
  selection whose fix is admissible, or an explicit render+fix — and how it reaches `demandedTier`/
  `demandedCaps` without changing the surfaced-only path.
- Freeze the fix classification: the rename is `unsafe` (withheld unless admitted), applies only under
  the fixable predicate, and rides `ruff-06`'s applicability/conflict/transaction path and the output
  re-elaboration validator unchanged — the same discipline `ruff-10b` proved for a non-source-tier fix.
- Design the capability interface twice — a sub-tier of `.semantic` vs an orthogonal caps axis beside
  the tier — and compare caller knowledge, invariants hidden, error surface, exactness, cache identity,
  critical path, and memory enforceability. Justify the choice against RMR-SPEC §6's frozen sketch.
- Enumerate the adversarial cases ROS-FINAL must drive: the rename applying and re-elaborating clean;
  unsafe gating; dot-notation / applied / `open`-shadowed / `newName? = none` staying report-only;
  idempotence; capability demand-gating both directions with a cost measurement of the info-tree walk;
  a monolithic-era entry missing a fixable demand; and pass-order independence.
- Write `results/01-spec.md` with the frozen interface, the two designs and the decision, evidence
  locators (cite file and line for each live seam), and remaining uncertainty. Update `state/current.md`
  only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the whole-file info-tree reachability and the occurrence-resolution
   substrate first-hand (a probe over a multi-command fixture), and the `ruff-06` transaction/validator
   seam the applied rename must reuse.
2. Design the capability interface twice; compare on the axes above and record the rejected alternative.
3. Specify the smallest deep seam that satisfies the frozen model, reusing `ruff-06` and the existing
   semantic capture rather than adding a parallel apply or capture path.
4. Name the demand trigger, the soundness guarantee (`demandedCaps ⊆ caps`, `Tier.satisfies` total),
   and the adversarial obligations inherited from §8.
5. Inspect callers and docs for any claim that the fix or the split is already handled or owned
   elsewhere.

## Stop

- Do not specify a rename applied to any occurrence a textual swap cannot preserve; the fix is
  bare-identifier only and `unsafe`.
- Do not let the info-tree walk be demanded by anything but the fixable capability; do not weaken
  `Tier.satisfies` soundness or let a monolithic-era entry serve a fixable demand.
- Stop rather than weakening exact semantics, write safety, cache identity, or the resource envelope, or
  giving rules lifecycle authority.

## Check

- This is a specification prompt; its checks are that the interface is complete, sourced first-hand
  against the live compiler and product seams it names (cite file and line for each), and buildable in
  principle without changing the surfaced FMT014 report or semantic-tier soundness.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11b-owned-semantic-fix`.
- Run `git diff --check` and read all output before marking ROS-SPEC verified.
