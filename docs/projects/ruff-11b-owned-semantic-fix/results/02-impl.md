# ROS-IMPL — result

**Claim:** the owned deprecation-occurrence fact is captured from the whole-file info trees **under
demand only**, FMT014 ships an `unsafe` rename through `ruff-06`'s applicability/conflict/transaction/
re-elaboration path, and the Design-B capability split makes the info-tree walk pay only when the fix is
demanded — implementing the interface ROS-SPEC froze without changing the surfaced FMT014 report or the
source/syntax/semantic fast paths.

This note is the evidence ledger: the seams changed, the exact commands and raw outputs, the decisions
changed during execution, and remaining uncertainty. The frozen interface is `notes/01-model.md`.

## 1. What shipped, by seam

| Seam | File | Change |
| --- | --- | --- |
| Owned fact | `LeanFmt/ArtifactModel.lean` | `DeprecatedOccurrence {range, declName, newName?, since?, text?, fixable}`; `SemanticProjection.occurrences? : Option (Array …) := none`; `SemanticProjection.caps`; `ModuleArtifact.caps`; `artifactSchema v5 → v6` |
| Capability model | `LeanFmt/ArtifactModel.lean` | `SemanticCaps {notations, diagnostics, occurrences}` + total `SemanticCaps.subset` |
| Capture | `LeanFmt/Analysis.lean` | `occurrenceOfInfo` / `captureDeprecatedOccurrences` (consumer-side `tree.getAll.filterMap (·.infoTree?)` fold, dedup by range, binder-excluded); `analyzeExact (captureOccurrences := false)`, walk gated on it |
| Facts → rule | `LeanFmt/Rules.lean` | `SemanticFacts.occurrences`; `RuleInfo.needsOccurrences`; `deprecatedUse` attaches the `unsafe` rename by range-identity match; registry FMT014 `fixable := true, needsOccurrences := true` |
| Result cache | `LeanFmt/Semantic.lean` | `SemanticResult.caps`; `semanticResultSchema v6 → v7`; `ofEnvelope?` tags `.semantic` caps from the projection |
| Demand + serve | `LeanFmt/Config.lean`, `LeanFmt/Application.lean` | `RulePlan.demandedCaps` (occurrences iff a rendering run selects a `needsOccurrences` rule); `cacheHitServes` requires `demandedCaps.subset result.caps`; `reprojectCanonical` extended to the occurrence capability so the FMT014 fix lands at **canonical** coordinates |
| Child protocol | `LeanFmt/Application.lean` | `__analyze-exact` token `"2"` = semantic + occurrence fold (`"1"` = semantic only, `"0"` = none) |

The deferral is removed, not shadowed: FMT014 is now the fixable rule, and there is no parallel
report-only architecture left behind. `LeanFmt.Rules` stays out of the plugin closure
(`tests/boundary/run.sh` green below).

## 2. Decision changed during execution — the semantic fix needs canonical re-projection

The frozen model (`notes/01-model.md` §6) said the rename rides `ruff-06`'s path "exactly as `ruff-10b`
routes a syntax fix". Implementing it surfaced that this is **more literal** than it reads:
`prepareFile` builds the `fix`/`format` patch from `canonical.findings` (the rendered-text projection),
never `result.findings` (original coordinates) — the "re-project, don't translate onto moved bytes"
discipline `ruff-06` RFX-SPEC froze. The occurrence captured on the **original** source therefore cannot
be the patch's coordinate source: canonicalizing moves bytes, so an original-coordinate rename `Edit`
would corrupt the file exactly as a syntax fix would.

`ExactRun.reprojectCanonical` (`ruff-10b` RYC-IMPL) already solves this for the syntax tier — re-run the
frontend on the *rendered* text, take the whole registry over that projection. The change was to
generalize its gate from `needsSyntax` to `needsSyntax || captureOccurrences` and thread
`captureSemantic`/`captureOccurrences` into its re-analysis, so a fixable-FMT014 render re-projects the
occurrence fold onto canonical text and FMT014's rename is natively canonical-coordinate. The
original-source occurrence stays captured (it drives `check`/report coordinates) but is deliberately
unused for the patch — the same relationship a syntax rule's original offset has to its re-projected
fix. This is a faithful application of the frozen model, not a deviation from it; it is recorded here
because the model did not spell out that the semantic tier reaches the *same* re-projection seam.

Cost stays gated: `check --select FMT014` does not render canonical, so it never re-projects; an
ordinary `format`/`fix` with no `needsOccurrences` rule selected has `demandedCaps.occurrences = false`,
so it never re-projects. Only a canonical render that selects FMT014 pays the second frontend run — the
exact demand that asked for the fix.

## 3. Fresh-frontend occurrence differential (capture half)

`tests/semantic/run.sh` runs the production capture path `__analyze-exact` over
`tests/semantic/Diagnostics.lean` at tokens `1` and `2` and differentials the projected occurrence
against Lean's own `--json` deprecation resolution:

```
occurrence differential: use of oldName -> newName at byte 674 (matches Lean); token-1 occurrences null, token-2 present
```

- **Demand-gating, both directions:** token `1` (semantic, no fold) leaves `occurrences` null; token
  `2` (occurrence capability) captures the list. The info-tree walk is absent unless the fixable
  capability is demanded.
- **Resolution differential:** the one captured occurrence is the *use* `def useOld : Nat := oldName`
  (declaration-site binder excluded), `declName ~ oldName`, `newName ~ newName`, `fixable = true`, and
  its `range.start` (byte 674) equals the byte Lean's own `Lean.Linter.deprecatedAttr` diagnostic points
  to. `(range, declName, newName?)` matches Lean's resolution.

Lean's derived `ToJson` **strips the trailing `?`** from an `Option` field's name (decision recorded:
the wire keys are `occurrences`/`newName`/`since`/`text`, not `occurrences?`/…); the tests assert the
stripped keys.

## 4. Rule half + capability logic (unit, `lake exe lean-fmt-tests`)

`LeanFmtTest.lean` adds `testOwnedDeprecationFix` and `testSemanticCaps`:

- **Fix attachment predicate** (report never perturbed across cases; only `fix?` varies):
  - fixable occurrence at the finding's range with `newName?` → `unsafe` rename, one edit replacing that
    range with `newName`;
  - `fixable := false` (non-bare) → report-only;
  - `newName? = none` (no replacement) → report-only;
  - occurrence at a different range → no match, report-only (attaches by range identity, not position);
  - **empty occurrences** (the `check` path) → report-only, byte-identical to the surfaced-only finding
    minus its fix (`e == { a with fix? := none }`).
- **`SemanticCaps.subset`** truth table, including the load-bearing miss: an occurrences demand against a
  monolithic-era entry (cheap sub-facts only, no occurrence cap) is **not** a subset, so `cacheHitServes`
  recomputes rather than serving a false clean.
- **`needsOccurrences` ↔ tier invariant:** every `needsOccurrences` rule is `.semantic`, and exactly
  `FMT014` declares it — the capability is tied to the constructor-derived tier so it cannot rot into an
  unenforced field (`AGENTS.md`: "a declared tier field goes unenforced and rots").

## 5. End-to-end fix composition (`tests/semantic/run.sh` acceptance)

Over a throwaway project with `acc/Mixed.lean` (`def useOld : Nat := oldName   ` + trailing whitespace):

- **Withheld (unadmitted):** `fix --select FMT014` (no `--unsafe-fixes`) publishes nothing — the file is
  byte-identical, `written == 0`, `changed == 0`, and `withheldUnsafe >= 1` records that the fix exists
  and was withheld (never reads as "clean, nothing to fix").
- **Admitted rename applies:** `fix --unsafe-fixes --select FMT014` re-projects onto canonical text and
  publishes `oldName -> newName` (`written == 1`, `changed == 1`, `rejected == 0` — a written fix passed
  the output re-elaboration validator). The written use reads `def useOld : Nat := newName`, and a fresh
  `check --select FMT014` is **clean**: the only deprecated use is gone.
- **Mixed-tier report** (`--select FMT001 --select FMT014`) reports both the source and semantic findings
  in one run; the semantic finding preserves the compiler's own message.
- **Cost (peak RSS, `/usr/bin/time -l`):** diag-capture 636 MiB, occ-capture 637 MiB vs capture-off
  637 MiB — the info-tree fold is a read over already-resident trees (the same snapshot tree the message
  log walks), not a second elaboration; well inside the 8 GiB envelope.

## 6. Commands and gate outputs

```
LEAN_NUM_THREADS=1 lake build                    → Build completed successfully (42 jobs)
lake exe lean-fmt-tests                          → lean-fmt module-artifact tests passed
tests/semantic/run.sh                            → semantic differential + demand-gating + RMR-FINAL acceptance tests passed
tests/modes/run.sh                               → lean-fmt product mode integration tests passed
tests/check/run.sh                               → lean-fmt check integration tests passed
tests/syntax/run.sh                              → lean-fmt syntax-tier rule integration tests passed
tests/service/run.sh                             → lean-fmt editor service integration tests passed
tests/compiler/run.sh                            → lean-fmt compiler facet tests passed
tests/boundary/run.sh                            → lean-fmt native module and dependency boundary passed
check_stack.py --structural                      → OK: 3 prompt(s), 0 warning(s), no errors
write_next.py --check                            → OK: state/next.md matches first_unresolved
git diff --check                                 → (clean)
```

Scale used the frozen `Diagnostics.lean`/`Mixed.lean` fixtures and named stress cases only; full mathlib
was not run (forbidden in this stack).

## 7. Remaining uncertainty

- **Schema/cache identity carries the runtime version and capabilities** as the stop rule requires
  (`artifactSchema v6`, `semanticResultSchema v7`, `caps` recorded per entry, `demandedCaps ⊆ caps` at
  serve). A monolithic-era entry misses a fixable demand rather than serving a false clean — proven at
  the predicate layer (`testSemanticCaps`) rather than by materializing a v6 entry on disk; the disk
  round-trip is covered indirectly by the schema-bump miss the other suites exercise.
- The `unsafe` rename is a textual name swap backstopped by the re-elaboration validator; it does not
  attempt qualified-name or shadowing-aware rewriting — every non-bare occurrence stays report-only by
  the frozen predicate, which is the conservative direction. Widening the fixable predicate is out of
  scope (owned by later rule-authoring work).
