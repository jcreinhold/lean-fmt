# ROS-FINAL — result

**Claim:** the owned, fixable FMT014 and the info-tree capability split are accepted adversarially — on
semantics (the rename applies and re-elaborates clean; non-qualifying occurrences stay report-only), on
fix safety (unsafe gating, validator, pass-order independence, idempotence), on cache separation
(capability demand-gating both directions, monolithic-era miss), and on cost (the info-tree walk is the
demanded delta, measured in wall time and RSS, inside the envelope).

This note is the evidence ledger. The interface is `notes/01-model.md`; the implementation ledger is
`results/02-impl.md`.

## 1. Decision changed during execution — the fixable predicate was unsound and was tightened

**The adversarial probe found a real soundness defect and this prompt fixed it.** ROS-IMPL shipped the
fixable predicate as `bare := spelled has no whitespace` (`Analysis.occurrenceOfInfo`). Building the
adversarial fixture `tests/semantic/Occurrences.lean` and capturing it at token `2` showed that this
loose predicate marked **two non-renamable spellings fixable**:

```
spelled='oldBare'         declName=oldBare      newName=newBare    fixable=True     (correct)
spelled='N.oldNs'         declName=N.oldNs      newName=N.newNs    fixable=True     (sound — see below)
spelled='oldNs'           declName=N.oldNs      newName=N.newNs    fixable=True  ✗  (open-shadowed: WRONG)
spelled='oldGet'          declName=Wrap.oldGet  newName=Wrap.newGet fixable=…            (dot-notation)
spelled='oldNoRepl'       declName=oldNoRepl    newName=None       fixable=False    (correct)
```

`oldNs` (a bare short name resolving to `N.oldNs` under `open N in …`) and `oldGet` (a dot-notation
projection head `w.oldGet` resolving to `Wrap.oldGet`) are exactly the `open`-shadowed and dot-notation
cases `notes/01-model.md` §5.3 requires to stay report-only — a whitespace-only check does not exclude
them. A `fix --unsafe-fixes` on `oldNs` would have written `open N in N.newNs` and on `w.oldGet` would
have written `w.Wrap.newGet` (broken syntax).

**Fix (`Analysis.occurrenceOfInfo`):** `fixable := newName?.isSome && spelled == occurrenceDisplay
declName`. The occurrence is fixable only when its **source spelling is exactly the resolved constant's
own full display name**; then replacing that whole span with the replacement's full display re-resolves
unambiguously, independent of `open`/dot context. After the fix:

```
oldBare  True   N.oldNs True   oldNs False   oldGet False   oldNoRepl False   (open-in expr) False
```

This **resolves** §5.3's concern rather than narrowing it: §5.3 warns against "a qualified path whose
prefix must move with the rename" — a partial replacement leaving a stale prefix. Because the fix
replaces the *whole* spelled span with the full new name, no stale prefix survives; a same-namespace
qualified use (`N.oldNs → N.newNs`) and a moving-prefix one (`N.oldNs → M.newThing`) are both sound, and
both satisfy §5.4's "unambiguous re-resolving spelling exists". Every spelling that differs from the
constant's full name — `open`-shadowed short names, dot-notation heads, applied receivers, operators —
falls to report-only, and the compiler's own FMT014 diagnostic still reports it. The re-elaboration
validator (§6) backstops any accepted spelling that nonetheless fails to resolve, so nothing unsound
reaches disk. This is a predicate *tightening* within the frozen model, not a model change.

## 2. The fixable predicate, adversarially (`tests/semantic/run.sh`, persistent)

`tests/semantic/Occurrences.lean` is the committed adversarial fixture; the suite captures it at token
`2` and asserts the fixable flag per spelling:

```
fixable predicate: {'oldBare': True, 'N.oldNs': True, 'oldNs': False, 'oldGet': False, 'oldNoRepl': False}
```

- **Fixable:** a bare top-level use (`oldBare`) and a fully-qualified whole-span use (`N.oldNs`).
- **Report-only:** the `open`-shadowed short name (`oldNs`→`N.oldNs`), the dot-notation projection head
  (`w.oldGet`→`Wrap.oldGet`), and the no-replacement deprecation (`oldNoRepl`, `newName? = none`).
- No occurrence is fixable without a replacement name.

## 3. End-to-end acceptance through the product CLI (`tests/semantic/run.sh`, persistent)

Over a throwaway project with `acc/Mixed.lean` (`def useOld : Nat := oldName   ` + trailing whitespace):

- **Applied rename** — `fix --unsafe-fixes --select FMT014` re-projects onto canonical text, publishes
  `oldName → newName` (`written == 1`, `changed == 1`, `rejected == 0` — a written fix passed the output
  re-elaboration validator), the written use reads `def useOld : Nat := newName`, and a fresh
  `check --select FMT014` is **clean**.
- **Unsafe gating** — `fix --select FMT014` without `--unsafe-fixes` withholds the fix: byte-identical
  source, `written == 0`, `changed == 0`, `withheldUnsafe >= 1` (reported, not silently clean).
- **Idempotence** — a second `fix --unsafe-fixes --select FMT014` over the renamed file is a no-op
  (`written == 0`, bytes unchanged).
- **Pass-order independence** — `--select FMT014 --select FMT001` and `--select FMT001 --select FMT014`
  `fix --unsafe-fixes` write **byte-identical** output (`cmp -s`), and the rename is applied in both.
- **Mixed-tier report** — `--select FMT001 --select FMT014` reports both tiers' findings in one run.
- **Silent-omission stop-rule** — a semantic selection over a file that fails to elaborate reports it
  `broken` (exit 1), never dropping it.

## 4. Capability demand-gating, both directions (`tests/semantic/run.sh`)

- The whole-file info-tree walk is **absent** from a surfaced-only capture (token `1`: `occurrences`
  null) and **present** only under the fixable capability (token `2`: the list is captured). A plain
  `format` and a `check --select FMT014` demand no occurrences (`RulePlan.demandedCaps`), so neither
  pays the walk.
- The monolithic-era miss is pinned at the predicate layer (`LeanFmtTest.testSemanticCaps`): an
  occurrences demand against an entry with only the cheap sub-facts is **not** a `SemanticCaps.subset`,
  so `cacheHitServes` recomputes rather than serving a false clean.

## 5. Cost — the info-tree walk is the demanded delta (`tests/semantic/run.sh`, `/usr/bin/time -l`)

Named-stress fixture (`Diagnostics.lean`), three capture levels — none (0), surfaced-only (1),
walk-demanded (2):

```
cost: RSS diag-capture 636 MiB, occ-capture 636 MiB vs off 636 MiB; wall surfaced 0.39s vs walk 0.39s (fold is a read)
```

Peak RSS is flat across all three and the wall time is unchanged: the info trees are already resident
(the message-log walk holds the same snapshot tree), so the occurrence fold is a **read**, not a second
elaboration. Every level stays far inside the 8 GiB / pressure / swap envelope. The capability split's
purpose — keeping this walk off every `format` — is upheld by the gating in §4; its cost when demanded
is bounded here. Full mathlib was not run (forbidden in this stack); the frozen sample and named stress
cases were used.

## 6. Rule boundary and mechanism review

- **No `Environment`/`InfoTree`/`Position`/`FileMap` crosses into a rule.** `DeprecatedOccurrence`
  carries only `String`s and a `SourceRange` (byte offsets); `occurrenceDisplay` converts every `Name`
  to its user-facing spelling at capture, where the `Environment` is live. `deprecatedUse` reads only
  `facts.occurrences` as pure data.
- **`LeanFmt.Rules` stays out of the plugin closure** (`tests/boundary/run.sh` green); the info-tree
  capture lives in `LeanFmt.Analysis`, the reporting process.
- **Every applied rename reviewed for exactness:** the occurrence text (`oldName`), its resolved
  constant (`oldName`'s display), and the replacement (`newName`) match; the written line is
  `def useOld : Nat := newName` and re-`check` is clean.

## 7. Commands and gate outputs

```
LEAN_NUM_THREADS=1 lake build             → Build completed successfully (42 jobs)
lake exe lean-fmt-tests                   → lean-fmt module-artifact tests passed
tests/semantic/run.sh                     → semantic differential + demand-gating + RMR-FINAL acceptance tests passed
tests/modes/run.sh                        → lean-fmt product mode integration tests passed
tests/check/run.sh                        → lean-fmt check integration tests passed
tests/boundary/run.sh                     → lean-fmt native module and dependency boundary passed
check_stack.py --structural               → OK, no errors
write_next.py --check                     → OK
git diff --check                          → (clean)
```

## 8. Remaining uncertainty

- The fixable set is deliberately conservative: only `spelled == full display name` is fixable, so a
  bare use of a namespaced deprecated declaration inside its own namespace (spelled by short name) stays
  report-only even when a bare rename would resolve. This is the sound direction — report-only is always
  safe, and widening the predicate (scope-aware bare re-resolution) would need the resolution check the
  capture does not perform. Widening is out of scope (owned by later rule-authoring work).
- The monolithic-era cache miss is proven at the `SemanticCaps.subset` predicate layer rather than by
  materializing a v6 entry on disk; the schema-bump miss the other suites exercise covers the disk
  round-trip indirectly.
