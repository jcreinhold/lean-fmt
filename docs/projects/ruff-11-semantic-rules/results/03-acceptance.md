---
kind: result
claim_id: RMR-FINAL
status: verified
---

# RMR-FINAL — semantics, cache separation, and cost accepted

The four surfaced semantic rules are accepted end to end through the product `check`/`fix` CLI: an
elaboration error under a semantic selection is reported broken (never omitted), a mixed source+semantic
selection reports both tiers in one run, a `fix` over a report-only semantic rule writes nothing, the
captured diagnostics reproduce an independent `lean --json` oracle byte for byte, and the diagnostics
capture is additive in memory (peak RSS parity with capture-off, inside the 8 GiB envelope). No
production code changed in this prompt — RMR-IMPL shipped it; RMR-FINAL adds the persistent acceptance
harness (`tests/semantic/run.sh` §RMR-FINAL) and the measurements below. Toolchain
`leanprover/lean4:v4.32.0`; base `60f80c9`; `Darwin arm64`.

## Headline stop-rule: no silent file omission on elaboration failure

Mechanism read first-hand: `Application.prepareFile` (`Application.lean:823-825`) is
`Except FileReport PreparedFile` and, when `analysis.result?` is `none` (a `broken` analysis, which is
what `analyzeExact` returns on `messages.hasErrors`), yields `baseReport snapshot "broken"` — a file
report with status `broken`, counted in `report.broken` (`Application.lean:972-973`), exit code 1
(`Cli.lean:213`). This is tier-independent: a semantic `--select` only sets `captureSemantic`; a broken
analysis flows to the same `broken` report regardless of the tier demanded. So a file that fails to
elaborate is always emitted, never dropped.

Pinned end to end (`tests/semantic/run.sh`, temp project, fixture `acc/Broken.lean` = `def bad : Nat :=
true`):

```
check --root <proj> --json --no-cache --select FMT014 acc/Broken.lean
→ exit 1; files == {"acc/Broken.lean": "broken"}; broken == 1; infrastructureFailures == []
```

The file is present with status `broken` under a `.semantic`-demanding selection — reported, not omitted.

## Acceptance matrix (all through the product CLI, `tests/semantic/run.sh` §RMR-FINAL)

| Property | Command | Observed |
| --- | --- | --- |
| Omission-on-error | `check --select FMT014 acc/Broken.lean` | exit 1, one file, status `broken`, `broken==1` |
| Mixed-tier selection | `check --select FMT001 --select FMT014 acc/Mixed.lean` | one file reports both `FMT014` (byte 120–127) and `FMT001` (127–130); FMT014 preserves the compiler's `deprecated` message |
| Fix validation (report-only) | `fix --select FMT014 acc/Mixed.lean` | `written==0`, `changed==0`, source byte-identical (`cmp`) |
| Fresh-worker differential | `__analyze-exact … 1` vs `lean --json` on `Diagnostics.lean` | 4 kinds matched, captured `(kind, range)` == oracle (RMR-IMPL differential, re-run green) |
| Demand-gating | `__analyze-exact … 0` | `semantic == null`; source projection byte-identical to `… 1` |
| Stale/schema miss | `v4`/`v5` schema guard | on-disk stale artifact rejected, forcing re-analysis (unit `testSemanticArtifact`; harness `Clean:leanFmtArtifact` rebuild) |

The mixed-tier finding order (`FMT014` before `FMT001`) is byte-sorted by `runRulesOf`, independent of
registry position — the same engine seam `testEngineTiers` pins on probes, here exercised on shipped
rules across two tiers in one report.

## Toolchain mismatch / cache identity

Not re-run by swapping toolchains (expensive, and the roadmap forbids heavy runs); argued from identity
and cited: the result cache keys on `lean-version\0{Lean.versionString}` and
`lean-githash\0{githash}` (`Cache.lean:167-168`), and the artifact rides the module `.olean`'s Lake
trace, which the compiler-plugin schema bump (`v4 → v5`) already invalidates. The `tests/check`
one-entry-two-selections check and the `tests/scale` source-identity/stale-epoch checks exercise this
machinery directly; the diagnostics fact rides the same identity, adding no new cache key. A cross-
toolchain artifact therefore misses on the version fields exactly as any cache entry does.

## Cost — named stress case (full mathlib forbidden here)

`/usr/bin/time -l` peak RSS of `__analyze-exact` on `tests/semantic/Diagnostics.lean` (all four kinds
firing), capture-on vs capture-off:

| Run | Peak RSS | Wall (real) | Semantic fact |
| --- | --- | --- | --- |
| capture=0 | 636 MiB | ~0.36 s | `null` |
| capture=1 | 637 MiB | ~0.33 s | `notations=2 diagnostics=4` |

The capture is genuinely **additive**: it normalizes the `MessageLog` the frontend already assembled —
no extra elaboration, no second pass — so capture-on peak RSS is at parity with capture-off (+~1 MiB,
+0.2%) and well inside the 8 GiB envelope. The harness asserts `capture-on < 8 GiB` and
`capture-on ≤ 1.5 × capture-off`. The editor-service suite independently reports ~1.0 GiB peak for the
semantic-capable service (`peak_rss_kib: 1044400`), also inside envelope.

## Checks

- `LEAN_NUM_THREADS=1 lake build` — clean (42 jobs).
- `lake exe lean-fmt-tests` — passes (RMR-IMPL unit coverage unchanged this prompt).
- `tests/semantic/run.sh` — passes: `… differential + demand-gating + RMR-FINAL acceptance tests
  passed`, `mixed-tier: one run reported ['FMT001', 'FMT014']`, `cost: capture-on peak RSS 637 MiB vs
  capture-off 636 MiB (additive)`.
- `tests/boundary/run.sh` — passes; `LeanFmt.Rules` stays out of the plugin closure and globs (no import
  or glob changed since RMR-IMPL). Only `tests/semantic/run.sh` changed in this prompt; no production
  module boundary moved.
- KanProofs structural checker and `write_next.py --check` — run below; recorded in `state/current.md`.
- `git diff --check` — clean.

## Remaining uncertainty

- **(a) `endPos = none`** — the zero-width point-range fallback is defined but untriggered by the
  shipping catalog (all four kinds carry `endPos` on v4.32.0); it would need a whole-line kind to
  exercise. Not a blocker for the shipped rules.
- **(b) Macro-reattributed ranges** — the clamp/drop guard is defensive; not observed to trigger on the
  fixtures. A surfaced range always lands inside the module's own bytes by construction.
- **(c) Owned/fixable FMT014 + Design B** — deferred by design (`notes/01-authority.md` §8); the surfaced
  cut is proven, and the info-tree producer change + capability split are the next stack's work, not a
  gap in this one.

## Status

RMR-FINAL: **verified.** The four surfaced semantic rules are accepted on semantics (broken files
reported, mixed tiers coexisting, report-only fixes writing nothing), on cache separation (schema/
toolchain identity, demand-gating both directions), and on cost (additive capture inside the envelope).
The stack `ruff-11-semantic-rules` is complete for its shipped scope; the owned-autofix enhancement is
explicitly deferred, not owed here.
