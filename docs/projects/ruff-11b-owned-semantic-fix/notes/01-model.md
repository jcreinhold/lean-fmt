# ROS-SPEC — the owned deprecation-occurrence fact, the fixable predicate, and the capability split

This note freezes the interface ROS-IMPL implements and ROS-FINAL drives. It honors the model
`ruff-11-semantic-rules/notes/01-authority.md` §§5,6,8,10 and refines exactly one of its claims
first-hand (§2 below). Every live seam is cited by file and line in `results/01-spec.md`; this note
is the reasoning, that note is the ledger.

## 1. What ships and what does not change

- The **surfaced** FMT014 (`Rules.lean:575-584`) — report-only, keyed on the `` `deprecatedAttr ``
  message tag, reading `SemanticFacts.diagnostics` — is unchanged. Its report text, range, severity,
  and `fixable:false` presentation stay byte-identical. This stack **adds** an owned occurrence fact
  and a fix that rides on it; it does not rewrite the surfaced path.
- The source / syntax / semantic fast paths (`cacheHitServes` `Application.lean:449-459`, `Tier`
  lattice) keep their current behavior for every run that does not demand the fix.
- No `Environment`, `InfoTree`, `Position`, or `FileMap` crosses into a rule. Occurrence capture and
  coordinate conversion happen inside `analyzeExact` (the reporting process), exactly where
  `captureDiagnostics` already converts `Position → byte offset`; the rule reads a pure fact.

## 2. Info-tree reachability — first-hand, refining §8

`ruff-11` §8 deferred the owned fix behind a stated pitfall: info state is reset per command
(`Command.lean:642-643`), so `waitForFinalCmdState?` — the state `analyzeExact` reads for the final
environment — holds only the **last** command's info trees, not the module's. §8 concluded that
"the whole-file trees live in the incremental snapshot tree (`Frontend.lean:118-122,357-358`);
capturing them is a distinct, measured change to the producer." The prompt (01-spec.md, Target)
correctly leaves the reachability question **open** — snapshot-tree walk vs incremental tree — and
asks for a first-hand answer.

**The probe answers it (`evidence/infotree_probe.lean`, output `evidence/01-infotree-probe.txt`).**
On a five-command fixture with a deprecated declaration used in two later commands, running the exact
`analyzeExact` core (copied, no `LeanFmt` import, so an independent oracle):

- `Snapshot.infoTree? : Option Elab.InfoTree` is a **direct field on `Snapshot`** (a sibling of
  `diagnostics`, `Lean/Language/Basic.lean`), populated per command. The snapshot tree that
  `analyzeExact` **already walks** for the message log — `toSnapshotTree snapshot |>.getAll`
  (`Analysis.lean:163-164`) — visited 72 snapshots, of which **7 carried an info tree**.
- The two deprecated **use-site** occurrences resolved from **two distinct info trees** (tree #3 and
  tree #4 — different commands), and the declaration site from a third (tree #2). This is decisive:
  the walk surfaces every command's trees, not only the last command's. **The §8 pitfall is real and
  is avoided by walking the snapshot tree instead of `waitForFinalCmdState?`.**

**Refinement recorded honestly:** capturing the whole-file trees is **not** "a distinct change to the
producer." It is a pure **consumer-side fold** — `tree.getAll.filterMap (·.infoTree?)` — over the
snapshots `analyzeExact` already enumerates. The producer already emits the trees on the snapshot
tree. This *strengthens* feasibility; it does not remove the reason for the capability split (§4): the
occurrence **fold** and the resulting fact are a demand-gated cost, and info-tree **retention** itself
is a memory cost a non-fix run should be able to decline (§4, remaining uncertainty in
`results/01-spec.md`).

## 3. The owned occurrence fact

Per deprecated **occurrence**, in normalized-source coordinates (the one system `mkInputContext`
establishes, §5 of the model):

```lean
structure DeprecatedOccurrence where
  range    : SourceRange     -- normalized-source byte offsets of the identifier token
  declName : Name            -- the resolved deprecated constant at this occurrence
  newName? : Option Name     -- the deprecation's replacement, if any
  since?   : Option String   -- the `since :=` string, if any
  text?    : Option String   -- the custom deprecation message, if any
  fixable  : Bool            -- decided at capture from the fixable predicate (§4)
```

Every field is available first-hand (probe): `range` from `Info.range? (canonicalOnly := true)`
(`Server/InfoUtils.lean:204`) converted to byte offsets exactly as `captureDiagnostics` converts
diagnostic positions; `declName` from `TermInfo.expr.constName?`; `newName?/since?/text?` from
`Lean.Linter.deprecatedAttr.getParam? ci.env declName : Option DeprecationEntry`
(`Linter/Deprecated.lean:24-30`). The probe printed
`some (newName?=(some …bar) since?=(some 1.0) text?=none)` and resolved the two use ranges
`(163,166)` and `(361,364)`, each spelling exactly `foo`.

**Capture procedure (inside `analyzeExact`, under demand only):**
1. `let trees := tree.getAll.filterMap (·.infoTree?)` — the whole-file info trees (§2).
2. For each tree, `InfoTree.foldInfo` (`Server/InfoUtils.lean:105`) over `Info`; for each
   `.ofTermInfo ti` with `ti.expr.constName? = some declName` and
   `deprecatedAttr.getParam? ci.env declName = some entry` and `Info.range? = some r`, emit
   `(r, declName, entry.newName?, entry.since?, entry.text?, ti.isBinder)`.
3. **Exclude the declaration site.** The probe shows the `foo` in `def foo` carries `isBinder = true`
   while both use-sites carry `isBinder = false`. FMT014 reports and fixes **uses**, never the
   declaration, so the fact drops `ti.isBinder = true` occurrences.
4. **Deduplicate by range.** Each use-site emitted its `TermInfo` twice (probe: 4 non-binder rows → 2
   distinct ranges). The fact is deduplicated on `(range.start, range.stop)`.

The fact is stored on `SemanticProjection` beside `diagnostics` (`ArtifactModel.lean:128`), as
`occurrences : Array DeprecatedOccurrence` (a **new** sub-fact, §4). It is a *fact, never a finding*:
the rule that maps an occurrence to a `Finding` with an `unsafe` fix runs outside the compiler, in the
reporting process, exactly like every other rule (CLAUDE.md artifact rule; `Rules.lean` stays out of
the plugin glob).

## 4. The capability split — designed twice

`ruff-11` §6 froze **Design A (monolithic)**: whenever `.semantic` is demanded, capture *both*
sub-facts (`notations` + `diagnostics`), so a `.semantic` artifact is always complete and
`Tier.satisfies` / `cacheHitServes` need no change. §6 named **Design B (capability split)** as the
required successor "when a sub-fact becomes expensive — i.e. the info-tree walk." This stack adds a
**third** sub-fact, `occurrences`, whose capture requires the info-tree fold (§2-3). We design the
interface both ways and choose.

### Design A′ — keep monolithic, add `occurrences` to the always-captured set
Every `.semantic` demand (a `check --select FMT015`, a `format` render) would additionally run the
info-tree fold and store occurrences. `cacheHitServes` is unchanged. **Rejected**: it forces the
occurrence fold and info-tree traversal onto every semantic run and every render, and stores the
occurrence array in every `.semantic` cache entry, whether or not any run will ever apply the rename.
That is exactly the cost §6 said the split exists to prevent — now concrete, because the sub-fact is
the info-tree-backed one §8 anticipated.

### Design B — capability-tracked `.semantic` *(chosen)*
Split the semantic demand into a capability set and gate each sub-fact on its capability:

```lean
structure SemanticCaps where
  notations   : Bool        -- the notation-spacing descriptor walk (ruff-05b)
  diagnostics : Bool        -- the surfaced-diagnostic MessageLog filter (ruff-11)
  occurrences : Bool        -- the owned deprecation-occurrence info-tree fold (this stack)
  deriving …

-- Each SemanticProjection sub-field becomes optional: `none` = capability not captured;
-- `some xs` = captured, possibly empty. (Absence and empty are distinct — an absent cap must
-- MISS the cache, an empty capture is a HIT that legitimately found nothing.)
structure SemanticProjection where
  notations?   : Option (Array NotationSpacing)
  diagnostics? : Option (Array Diagnostic)
  occurrences? : Option (Array DeprecatedOccurrence)
```

- `SemanticResult` records the captured caps and bumps its schema `v6 → v7`
  (`Semantic.lean:78`, currently `"lean-fmt.semantic-result.v6"`). A pre-`v7` entry fails to decode the
  new field and **misses** — the existing stale-miss discipline, no false serve.
- `cacheHitServes` (`Application.lean:449-459`) extends its `.semantic` arm: a cached `.semantic`
  entry serves a demand iff `demandedCaps ⊆ entry.caps` (in addition to the existing
  `tier.satisfies` and `renderCanonical → canonical?.isSome` guards). `Tier.satisfies` stays a
  **total** lattice gate on the tier axis; caps are an **orthogonal** subset gate on the sub-fact
  axis. Neither weakens the other.

**Why the choice is sound (the trap Design B must not spring).** The danger is a monolithic-era
(`v6`, notations + diagnostics, **no** occurrence cap) entry serving a run that demands the fix. Two
independent guards close it: (a) the `v6 → v7` bump makes every pre-split entry fail to decode and
miss; (b) even a hypothetical `v7` entry captured with `occurrences := false` has
`demandedCaps = {occurrences} ⊄ {…}`, so `cacheHitServes` returns false. A fixable-FMT014 demand
therefore **misses and recomputes** rather than reading a false-clean; it never sees an absent cap as
"no occurrences." The interface for absence (`none`) vs empty (`some #[]`) is what makes this precise:
`occurrences? = none` is "not captured, must miss"; `occurrences? = some #[]` is "captured, none
found, a clean hit."

### Interface comparison (the axes the prompt names)

| Axis | Design A′ (monolithic) | Design B (caps) — chosen |
| --- | --- | --- |
| Caller knowledge | none extra; every `.semantic` is complete | caller passes `demandedCaps`; one new fold in the demand computation |
| Invariants hidden | tier completeness only | tier completeness **and** per-cap capture, both below `cacheHitServes` |
| Error surface | occurrence fold errors leak into every render | fold runs only under the occurrence cap; a non-fix render cannot trip it |
| Exactness | identical facts, over-captured | identical facts, captured on demand |
| Cache identity | occurrence array in every `.semantic` entry | occurrence array only in entries that demanded it; caps recorded, `⊆`-gated |
| Critical path | info-tree fold on every `format`/semantic run | fold only when the fix is demanded |
| Memory enforceability | whole-file info trees retained + folded for every render | retention/fold declinable per the `occurrences` cap (the 8 GiB lever) |

Design B is chosen. It is the split `ruff-11` §6/§8 reserved, now justified by a concrete
info-tree-backed sub-fact rather than a hypothetical one. Design A′ is recorded as the rejected
alternative: strictly simpler, but it re-introduces the exact over-capture the split exists to
prevent.

## 5. The bare-identifier fixable predicate

An occurrence is **fixable** (eligible for the `unsafe` rename to `newName?`) only when a textual
replacement of the occurrence range with the source spelling of `newName?` preserves meaning. From the
info-tree fact, the predicate requires **all** of:

1. **`newName? = some n`.** No replacement exists otherwise — `newName? = none` (message-only
   deprecation) stays report-only. (Probe: `newName?` is present and resolvable.)
2. **`ti.isBinder = false`.** The occurrence is a use, not the declaration (§3 step 3).
3. **Bare identifier resolving to the deprecated constant.** `ti.expr.constName?` is `some declName`
   *and* the occurrence's syntax is a single identifier token whose spelled text (the range) is an
   identifier, not a projection/dot-notation head, not an applied receiver with the constant implicit,
   not a qualified path whose prefix must move with the rename. Decided from the fact: the range spells
   exactly one identifier token (probe: range `(163,166)` spells `foo`), and `declName` resolves from a
   direct `.const` (not from an `.app` spine or a `.proj`). Dot-notation (`x.foo`), an applied receiver,
   and `open`-shadowed spellings do **not** satisfy this and stay report-only.
4. **The replacement spelling is unambiguous and re-resolves.** `newName?` is an internal `Name`
   (the probe shows the module-private mangling `_private.ProbeFixture.0.bar`); the fix text must be the
   **user-facing source spelling** that resolves back to the same constant in the occurrence's scope.
   If no such unambiguous bare spelling exists (the new name needs qualification, or is `open`-shadowed
   at the site), the occurrence stays report-only. ROS-IMPL recovers the spelling and, because the
   applied output is re-elaborated (§6), a spelling that does not resolve is caught by the validator,
   never published.

Every non-qualifying occurrence is **report-only** (the surfaced FMT014 finding, unchanged). The fix
is added **only** to occurrences satisfying 1-4, and even then it is `unsafe` (§6). The predicate is
decided at capture and recorded as `DeprecatedOccurrence.fixable`, so the rule reads a pure boolean and
never inspects syntax.

## 6. Fix classification — `unsafe`, on `ruff-06`'s path unchanged

The rename is **`unsafe`** (`Applicability.unsafe`, `ArtifactModel.lean:28`): a textual name swap is
"plausibly intended" but cannot be proven to preserve behavior, comments, or intent
(`ArtifactModel.lean:18-20`), so it is shown by default and applied **only** under explicit opt-in
(`--unsafe-fixes`; admission is `Applicability.admitted unsafeFixes`, `Application.lean:816-846`). It
is never `safe`.

The applied rename reuses `ruff-06`'s machinery **with no new apply path**, exactly as `ruff-10b`
proved for a non-source-tier fix:

- The finding carries `fix? := some { applicability := .unsafe, edits := #[{ range, replacement }] }`
  in canonical coordinates. Because `fix`/`format` render canonical text and re-project when a selected
  rule needs a higher tier (`ExactRun.reprojectCanonical`, `Application.lean:366,409,416-421`), the
  occurrence fact is captured against the **rendered** text and its edits are natively canonical —
  `ruff-06`'s "re-project, don't translate" (the same discipline `ruff-10b` shipped).
- Admission, `Edit.validateEdits`/`Edit.validateConflicts`/`Edit.preparePatch`
  (`Edit.lean:73,93,129`), atomic publication, and the **output re-elaboration validator**
  (`analyzeSnapshot candidate (validator := true)`, `Application.lean:942`) all handle any-tier
  findings already. A rename that produces a file that fails to re-elaborate clean is rejected by the
  validator and never written — the safety net for the `unsafe` classification.

## 7. Demand trigger and the surfaced-only path

The fix's capture is demanded by, and only by, the **fixable capability**:

- **Trigger:** a run that (a) selects FMT014 **and** will apply its fix — i.e. `fix`/`format` (a
  rendering mode, `renderCanonical`) with FMT014 selected and `--unsafe-fixes` admitting it — **or**
  an explicit render+fix request. That run's `demandedCaps` includes `occurrences`. A `check` (no
  render, no apply) selecting FMT014 demands only `diagnostics` (the surfaced report), **not**
  `occurrences`.
- **Where it enters:** `RulePlan.demandedTier` (`Config.lean:302-303`) gains a sibling
  `RulePlan.demandedCaps (renderCanonical, unsafeFixes)` that folds the selected rules and the mode
  into a `SemanticCaps`. The occurrence cap is set iff a selected rule has an admissible occurrence-fix
  under this run's admission. This is the single gating seam — capture runs iff `demandedCaps.occurrences`
  reaches `analyzeExact`'s `captureSemantic`, generalized from a `Bool` to the caps set.
- **The surfaced-only path is untouched.** A `check --select FMT014` never sets the occurrence cap, so
  it never triggers the info-tree fold: same report, same cost, same cache identity as today. The
  always-on plugin producer never sets any cap (it stays on the syntax-only path), so integrated builds
  are unaffected — the boundary `ruff-11` established holds.

## 8. Adversarial obligations ROS-FINAL must drive

1. **Rename applies and re-elaborates clean.** A bare-identifier use of a deprecated decl with
   `newName?`, under `--unsafe-fixes`, is rewritten to the new name; the written file re-elaborates
   clean and a re-`check` is clean.
2. **Unsafe gating.** Without `--unsafe-fixes` the rename is reported (with its `unsafe` applicability)
   and **not** written; the file is byte-identical.
3. **Report-only non-qualifiers.** Dot-notation (`x.foo`), an applied receiver, an `open`-shadowed
   spelling, and `newName? = none` each stay report-only — reported, never rewritten.
4. **Idempotence.** A second `fix` is a no-op (the renamed identifier no longer resolves to a
   deprecated constant).
5. **Capability demand-gating, both directions, with a cost measurement.** A `check --select FMT014`
   does **not** run the info-tree fold (occurrence cap unset); a `fix --select FMT014 --unsafe-fixes`
   **does**. Measure the info-tree fold's marginal cost (wall + peak RSS, capture-on vs capture-off)
   on a named module, asserting `< 8 GiB` and a bounded multiple — the measurement that confirms the
   split earns its keep (and would, if the fold proved free, be the record that justifies revisiting
   Design A′; the split still buys the cache-identity and memory-declinability properties in §4).
6. **A monolithic-era entry misses a fixable demand.** A `v6` (pre-split) or a `v7`-without-occurrence
   cache entry does not serve a fixable-FMT014 demand: it misses and recomputes, never serving a
   false-clean.
7. **Pass-order independence.** With another selected fix in the same run, `--select` order writes
   byte-identical bytes (the re-projection makes edits canonical, `ruff-10b`'s property).

## 9. What ROS-IMPL owes

1. Add `DeprecatedOccurrence` and `SemanticProjection.occurrences?`; capture it in `analyzeExact` under
   the occurrence cap via the snapshot-tree info-tree fold (§2-3), converting ranges through the live
   `FileMap` at capture (§5 of the model), deduplicated and binder-excluded.
2. Split the demand into `SemanticCaps`, make the three `SemanticProjection` sub-fields `Option`,
   record caps in `SemanticResult` (`v6 → v7`), and extend `cacheHitServes` to `demandedCaps ⊆ caps`
   (§4). Keep `Tier.satisfies` total.
3. Add the owned fixable-FMT014 rule: read `SemanticFacts.occurrences`, emit for each `fixable`
   occurrence a `Finding` whose surfaced report is unchanged but which carries the `unsafe` rename fix
   (§5-6). Non-fixable occurrences keep the surfaced report-only finding.
4. Route the fix through `ruff-06`'s admission/conflict/transaction/validator path unchanged (§6);
   add no parallel apply or capture path.
5. Wire `RulePlan.demandedCaps` and thread it to `analyzeExact` in place of the `captureSemantic`
   boolean (§7), leaving the surfaced-only and integrated-build paths untouched.
