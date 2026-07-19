# ROS-SPEC — result

**Claim:** the owned deprecation-occurrence fact, the bare-identifier fixable predicate, the `unsafe`
rename on `ruff-06`'s path, and the info-tree **capability split** are specified, sourced first-hand
against the live compiler and product seams, and buildable in principle without changing the surfaced
FMT014 report or semantic-tier soundness.

The frozen interface is in `notes/01-model.md`. This note is the evidence ledger: the first-hand probe,
the live-seam locators, the two designs and the decision, decisions changed while freezing, and
remaining uncertainty.

## 1. First-hand probe — whole-file info-tree reachability and occurrence resolution

`evidence/infotree_probe.lean` copies the exact-frontend core of `LeanFmt/Analysis.lean:analyzeExact`
(no `LeanFmt` import — an independent oracle) and runs it over `evidence/probe_fixture.lean`, a
five-command module with `def bar`, `@[deprecated bar (since := "1.0")] def foo`, and three later
commands using `foo` (twice) and `bar`. Run:

```
lake env lean --run docs/projects/ruff-11b-owned-semantic-fix/evidence/infotree_probe.lean
```

Output (`evidence/01-infotree-probe.txt`):

```
snapshots=72 snapshotsWithInfoTree=7
totalInfoNodes=59 termInfoNodes=34
distinctConstNames=#[Nat, …bar, …foo, …usesFooA, …usesFooB, …usesBar]
finalEnv.deprecatedAttr[foo] = none
finalEnv.deprecatedAttr[_private.ProbeFixture.0.foo] = some (newName?=(some …bar) since?=(some 1.0) text?=none)
deprecatedOccurrences=5
  tree#2: …foo @ byte[67,70)  isBinder=true  -> newName=…bar (spelled: foo)
  tree#3: …foo @ byte[163,166) isBinder=false -> newName=…bar (spelled: foo)
  tree#3: …foo @ byte[163,166) isBinder=false -> newName=…bar (spelled: foo)
  tree#4: …foo @ byte[361,364) isBinder=false -> newName=…bar (spelled: foo)
  tree#4: …foo @ byte[361,364) isBinder=false -> newName=…bar (spelled: foo)
useSiteOccurrences(non-binder)=4 distinctUseRanges=2 ranges=#[(163, 166), (361, 364)]
```

What it proves, first-hand on v4.32.0:

- **Reachability through the existing walk.** `Snapshot.infoTree?` is a direct field on `Snapshot`
  (`Lean/Language/Basic.lean`, sibling of `diagnostics`). The snapshot tree `analyzeExact` already
  walks for the message log — `toSnapshotTree snapshot |>.getAll` (`Analysis.lean:163-164`) — carried
  **7 info trees** among 72 snapshots, and the two deprecated **use-sites** resolved from **two
  distinct trees** (tree #3, tree #4 — distinct commands). The whole-file trees are reachable via
  `tree.getAll.filterMap (·.infoTree?)`, a **consumer-side fold**, with **no producer change**.
- **The §8 pitfall is real and avoided.** `waitForFinalCmdState?` holds only the last command's info
  state (info reset per command, `Command.lean:642-643`); walking the snapshot tree instead surfaces
  every command's trees. This **refines** `ruff-11` §8's "capturing them is a distinct, measured change
  to the producer" — the trees already live on the snapshot the existing walk enumerates. (Recorded as
  a refinement, not a contradiction: the prompt left reachability open; the probe resolves it.)
- **Occurrence resolution.** Each use-site `TermInfo` gives `expr.constName? = declName`; the range
  from `Info.range? (canonicalOnly := true)` (`Server/InfoUtils.lean:204`) spells exactly the
  identifier `foo`; `deprecatedAttr.getParam? ci.env declName` returns
  `{newName?, since?, text?}` (`Linter/Deprecated.lean:24-30`) — every field of the owned fact.
- **Two facts the design must handle, both observed:** (a) the declaration site (`def foo`) appears
  with `isBinder = true` and must be excluded — FMT014 fixes uses, not declarations; (b) each use-site
  emits its `TermInfo` **twice**, so the fact deduplicates by `(start, stop)` (4 non-binder rows → 2
  distinct ranges). (c) `newName?` is an internal, module-private-mangled `Name`
  (`_private.ProbeFixture.0.bar`); the rename replacement **text** must be the user-facing source
  spelling — a fixable-predicate obligation (`notes/01-model.md` §5).

## 2. Live-seam locators (cited first-hand)

| Seam | Location | Role in the spec |
| --- | --- | --- |
| `analyzeExact` snapshot-tree walk | `LeanFmt/Analysis.lean:162-164` | the walk that already assembles `messages`; occurrence fold reuses it |
| `captureDiagnostics` (Position→byte) | `LeanFmt/Analysis.lean:179` | the coordinate conversion the occurrence range reuses |
| `captureSemantic` gate | `LeanFmt/Analysis.lean:141,178` | generalized from `Bool` to the caps set (§7) |
| `SemanticProjection`, `Diagnostic`, `v5` schema | `LeanFmt/ArtifactModel.lean:98,128,164` | gains `occurrences?`; sub-fields become `Option` |
| `Applicability` (safe/unsafe/displayOnly) | `LeanFmt/ArtifactModel.lean:26-37` | the rename is `.unsafe` |
| `SemanticFacts`, `Facts`, `RuleImpl` semantic cases | `LeanFmt/Rules.lean:97-105,114,131` | the owned rule reads `SemanticFacts.occurrences` |
| surfaced FMT014–017 | `LeanFmt/Rules.lean:575-584` | unchanged; the owned rule adds the fix |
| `SemanticResult`, `tier`, schema `v6` | `LeanFmt/Semantic.lean:26,50,78` | records caps; schema `v6 → v7` |
| `SemanticResult.ofEnvelope?` facts/tier | `LeanFmt/Semantic.lean:159-165` | reads back the caps |
| `cacheHitServes` | `LeanFmt/Application.lean:449-459` | extend `.semantic` arm with `demandedCaps ⊆ caps` |
| `reprojectCanonical` (non-source-tier fix) | `LeanFmt/Application.lean:366,409,416-421` | the rename edits are natively canonical |
| output re-elaboration validator | `LeanFmt/Application.lean:942` | rejects a rename that fails to re-elaborate |
| unsafe admission | `LeanFmt/Application.lean:58,816-846` | `Applicability.admitted unsafeFixes` gates the patch |
| `preparePatch`/`validateConflicts`/`validateEdits` | `LeanFmt/Edit.lean:129,93,73` | the transaction path, unchanged |
| `RulePlan.demandedTier` | `LeanFmt/Config.lean:302-303` | gains sibling `demandedCaps` |
| `deprecatedAttr.getParam?`, `DeprecationEntry` | `Linter/Deprecated.lean:24-30,56-62` | the owned-fact source |
| `InfoTree.foldInfo`, `Info.range?` | `Server/InfoUtils.lean:105,204` | the fold and range API |
| `TermInfo.expr`, `isBinder` | `Elab/InfoTree/Types.lean:82` | const resolution and binder exclusion |
| `Snapshot.infoTree?` | `Lean/Language/Basic.lean` (`structure Snapshot`) | the reachability field |

## 3. The two designs and the decision

Recorded in full in `notes/01-model.md` §4. Summary: **Design A′** keeps the monolithic capture and
adds `occurrences` to the always-captured set — rejected, because it forces the info-tree fold and the
occurrence array onto every `.semantic` run and render, the exact over-capture `ruff-11` §6 said the
split exists to prevent, now concrete because `occurrences` is the info-tree-backed sub-fact §8
anticipated. **Design B (chosen)** splits the demand into `SemanticCaps {notations, diagnostics,
occurrences}`, makes each `SemanticProjection` sub-field `Option` (`none` = not captured / must miss;
`some` = captured, possibly empty / may hit), records caps in `SemanticResult` (`v6 → v7`), and gates
`cacheHitServes` on `demandedCaps ⊆ entry.caps` beside the unchanged `tier.satisfies`.

**Soundness argument (the fixable-demand-misses guarantee).** `Tier.satisfies` stays a total lattice
gate on the tier axis; caps are an orthogonal subset gate on the sub-fact axis. A monolithic-era `v6`
entry fails to decode the `v7` caps field and misses; a hypothetical `v7` entry with
`occurrences := false` has `{occurrences} ⊄ caps` and misses. Either way a fixable-FMT014 demand
recomputes rather than serving a false-clean. The `none`-vs-`some #[]` distinction is what makes
"absent capability" (must miss) precise against "captured, none found" (clean hit). Justified against
`ruff-11` §6's frozen sketch — this **is** that sketch's `SemanticCaps`, extended by the third cap and
tied to the `v6` schema the live code already reached (`Semantic.lean:78`).

## 4. Callers/docs inspection (Plan step 5)

- No later stack (`ruff-12`…`ruff-20`) claims this fix or the split; the master roadmap row 11b and the
  `ruff-11` §8 forward-reference name this stack as the owner (verified in the prior audit;
  `ruff-class-roadmap.md:39`, `ruff-11-semantic-rules/notes/01-authority.md:217`). `ruff-12` owns rule
  *lifecycle/fixability controls*, not this rule's fix; `ruff-19` owns the *cost budget*, not this
  capability. No conflict, no double-ownership.
- The live `semanticResultSchema` is already `"…v6"` (`Semantic.lean:78`, `ruff-10b`'s bump), so
  Design B's `v6 → v7` is the correct next bump — consistent with `ruff-11` §6's "`v6 → v7`" sketch.

## 5. Decisions changed while freezing, and remaining uncertainty

- **Changed:** `ruff-11` §8 framed whole-file info-tree capture as "a distinct, measured change to the
  producer." The probe shows it is a **consumer-side fold** over the snapshot tree `analyzeExact`
  already walks — no producer change. This makes ROS-IMPL smaller and lower-risk than §8 assumed; the
  capability split is still adopted, now justified by the concrete cost of the fold + info-tree
  retention rather than a producer rewrite.
- **Uncertainty for ROS-FINAL to measure (adversarial case 5, `notes/01-model.md` §8):** the info
  trees are *present* on the snapshots under `analyzeExact`'s current options (`Elab.async` on), and
  are a byproduct of elaboration that today `analyzeExact` builds but does **not** consume (it reads
  only `·.diagnostics.msgLog`). Two costs the occurrence cap governs must be measured: (a) the marginal
  cost of the occurrence **fold** (the `deprecatedAttr` lookups + range extraction over term-info
  nodes); (b) whether info-tree **retention** itself can be declined for non-occurrence runs to save
  memory. Both are measured capture-on vs capture-off on a named module, asserting `< 8 GiB` and a
  bounded multiple. If the fold proves free, the split still buys cache-identity cleanliness and the
  memory-declinability lever (§4), so the decision to adopt it stands; the measurement records the
  actual price, per the roadmap's evidence policy.
- **Fixable-predicate residue:** the discriminators for dot-notation / applied receiver / `open`-shadow
  are specified from the info-tree fact (`notes/01-model.md` §5); ROS-IMPL decides them at capture and
  ROS-FINAL drives each as a report-only case. The `newName?` source-spelling recovery (un-mangling the
  private name to a resolvable bare identifier) is an ROS-IMPL obligation the re-elaboration validator
  backstops.

## 6. Checks

- **Specification prompt.** The interface is complete (owned fact, fixable predicate, capability split,
  fix classification, demand trigger, adversarial list), sourced first-hand (§1 probe, §2 locators with
  file and line), and buildable in principle without changing the surfaced FMT014 report or semantic
  soundness (§3 argument). No production code changed in this prompt.
- Structural checker, `write_next.py --check`, and `git diff --check`: run and recorded in the ROS-SPEC
  commit message and `state/current.md` update.
