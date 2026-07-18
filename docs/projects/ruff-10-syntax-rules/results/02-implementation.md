# 02-implementation — RYR-IMPL result

**Claim:** RYR-IMPL — add the approved syntax rules, metadata, fixes, suppressions, docs inputs, and
exact category dispatch without giving rules parser or application-lifecycle authority.

**Status:** delivered. Six `.syntax`-tier rules **FMT008–FMT013** ship, fully implemented and
selectable, all as **preview** (default-off). The first-syntax-tier cache wiring is in place; syntax
findings are reported by `check`, and their `.safe` fixes are reported on original coordinates.
Canonical-coordinate syntax *fix application* is a documented deferral; RFX-SPEC (`ruff-06`) froze its
model and the wiring is owned by the successor stack `ruff-10b-syntax-fix-composition`.

## What was produced

- **Rules (`LeanFmt/Rules.lean`, +307).** FMT008 (module docstring required), FMT009 (unclosed
  `section`/`namespace`), FMT010 (duplicate attribute), FMT011 (duplicate `deriving` class), FMT012
  (development-only `set_option`), FMT013 (redundant nested parens). Each is `RuleImpl.syntax` — the
  tier is the constructor, never a field. FMT010/011/013 carry `.safe` byte-range delete fixes;
  FMT008/009/012 are report-only.
- **Projection query surface (`LeanFmt/LosslessSource.lean`, +76).** Total, bounds-guarded helpers the
  rules read the tree through — `kindOf`, child adjacency, `tokensByNode`, `topLevelNodes` — plus
  `inQuotation`, a `parent`-chain walk that flags any node under a `*quot*` kind so a defect *inside* a
  `` `(…) `` quotation (generated-syntax data, not code) never fires.
- **Cache tier tag (`LeanFmt/Semantic.lean`, `LeanFmt/Application.lean`).** `SemanticResult.tier :
  Tier` (schema `v4 → v5`); the source-only shortcut tags `.source`, the artifact/exact path
  (`ofEnvelope?`, full registry) tags `.syntax`. `cacheHitServes` gains `result.tier.satisfies
  requiredTier`, so a source-only shortcut entry can never serve a `.syntax` `--select` a false
  negative, while the universal `.syntax` entry still serves any selection.
- **Selection (`LeanFmt/Config.lean`).** A `default` selector expanding to the `defaultEnabled` rules;
  `defaultConfig`/`parseConfig` seed `#["default"]` instead of `#["all"]`. `all` remains every
  registered rule.
- **Tests.** `tests/syntax/run.sh` (new) + fixtures; updated `LeanFmtTest.lean`, `tests/check/run.sh`,
  `tests/modes/run.sh`.
- **Docs.** `notes/02-implementation.md` (design + repair addendum), `notes/01-catalog.md` (§3 preview
  rationale + per-rule markers), `docs/adding-a-rule.md` (live `.syntax` tier), `CLAUDE.md` (build
  list).

## Rules at a glance (as shipped)

| code | family | default | fix | applicability |
| --- | --- | --- | --- | --- |
| FMT008 module docstring required | docs | preview | — | report-only |
| FMT009 unclosed section/namespace | structure | preview | — | report-only |
| FMT010 duplicate attribute in a list | redundancy | preview | delete dup | `.safe` |
| FMT011 duplicate deriving class | redundancy | preview | delete dup | `.safe` |
| FMT012 development-only `set_option` | debug | preview | — | report-only |
| FMT013 redundant nested parentheses | redundancy | preview | drop outer | `.safe` |

## Commands run (exact)

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/check/run.sh
tests/compiler/run.sh
tests/suppression/run.sh
tests/lossless/run.sh
tests/modes/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/boundary/run.sh
tests/syntax/run.sh
check_stack.py docs/projects/ruff-10-syntax-rules --structural
write_next.py docs/projects/ruff-10-syntax-rules --check
git diff --check
```

## Checks read

| check | result |
| --- | --- |
| `lake build` | exit 0 — `Build completed successfully (42 jobs).` |
| `lake exe lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/compiler/run.sh` | `lean-fmt compiler facet tests passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/lossless/run.sh` | `lean-fmt lossless projection corpus passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/scale/run.sh` | `lean-fmt complete-selection and module-evidence tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `check_stack.py … --structural` | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py … --check` | fresh for `first_unresolved='03-acceptance'` (regenerated after state update) |
| `git diff --check` | clean |

## Key evidence

- **Each rule fires exactly its own defect and no near-miss.** `tests/syntax/run.sh` asserts the
  ordered finding codes on a positive fixture per rule, `[]` on the clean file, and `[]` on each of the
  six documented exclusions (`@[local simp, simp]` differs by `attrKind`; `deriving Repr, BEq` are
  distinct; `set_option maxHeartbeats` is outside the four debug roots; a tuple / type-ascription /
  cdot are distinct node kinds from `paren`; a section-only module has no `declaration`; an outermost
  `noncomputable section` is the whole-file idiom).
- **Fix bytes are pinned.** FMT010 deletes bytes `42..48`, FMT011 `110..116` (the duplicate instance
  and its `", "`), FMT013 deletes the outer pair (`51..52`, `55..56`) and leaves the inner `(1)` — all
  `.safe`, all on original coordinates.
- **Quotation / custom syntax / malformed input are silent or graceful.** A nested paren or duplicate
  attribute inside a `` `(…) `` quotation fires nothing; a `syntax "wrap(" term ")"` declaration fires
  nothing; an unparseable file is `broken` (reported, no crash, no false finding).
- **The tier gate is load-bearing.** `tests/check/run.sh` now asserts the source-shortcut entry is the
  `.source` subset and the exact-frontend entry is the `.syntax` superset (the latter carries FMT008
  the former lacks) — the two are deliberately not byte-identical, and the `tier` tag is what stops the
  subset from serving a syntax selection.

## Decisions changed during execution

1. **FMT008–FMT013 all ship preview (scaffold correction).** The freeze had FMT009–FMT012 `enabled`.
   Implementing it exposed that (a) `defaultEnabled` was never enforced (default selection was literally
   `"all"`), so FMT008/FMT013 were already running by default, and (b) a default-on syntax rule forces
   the projection on *every* file, retiring the `ruff-05` source-only fast path and pushing non-module
   files onto the exact frontend. Graduating a preview rule into the default set is
   `ruff-12-rule-lifecycle`; the incremental cache is `ruff-16`; the default-run cost budget is
   `ruff-19`. ruff-10's roadmap says "stable **or** preview", so all six ship preview. Rationale:
   `notes/01-catalog.md` §3. The `default` selector that enforces `defaultEnabled` is ruff-10's own
   minimal fix and stays.
2. **Quotation guard added.** Catalog §5.2 requires a defect inside a quotation to stay silent;
   `LosslessSource.inQuotation` + guards in the five node-walking rules deliver it (FMT009 reads only
   top-level nodes and needs none).
3. **Syntax fix *application* deferred, not shimmed.** `check` reports the `.safe` fixes on original
   coordinates, but `format`/`fix` render canonical text and run only `runSourceRules`, so they do not
   apply a syntax fix. This is a documented tier limit (`Application.renderCanonicalText`), pinned by
   `tests/syntax/run.sh`; RFX-SPEC (`ruff-06`) froze the composition model and the successor stack
   `ruff-10b-syntax-fix-composition` owns closure — not a hole.

## Remaining uncertainty (handed to RYR-FINAL)

- **FMT013's true prevalence** is still unmeasured; its preview default is contingent on the tree-walk
  count RYR-FINAL runs on the frozen sample.
- **FMT009 whole-file-section exclusion** and the name-stack matching are exercised by the positive and
  near-miss fixtures here; RYR-FINAL asserts the exclusion against corpus scale.
- **`set_option … in` term/tactic forms** are detectable and in scope for FMT012; v1 targets the
  standalone command (the fixtures cover that). Whether to extend to the `in` forms is open.
- **Canonical-coordinate syntax linting / fix composition** is the one deferred piece: RFX-SPEC froze
  its model; the successor stack `ruff-10b-syntax-fix-composition` owns the wiring.
