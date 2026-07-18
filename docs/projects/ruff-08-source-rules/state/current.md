---
kind: state
first_unresolved: none
---

# Current state

**The stack is complete: `RSR-SPEC`, `RSR-IMPL`, and `RSR-FINAL` are all verified.** The frozen
catalog is `notes/01-catalog.md`; what was run is `results/01-catalog.md`,
`results/02-implementation.md`, and `results/03-acceptance.md`. The two approved rules are live in
`LeanFmt/Rules.lean`'s `ruleRegistry`: `FMT003` (forbidden control byte) and `FMT004` (suspicious
bidirectional control), both report-only, category `security`, default-enabled. Category selection is
now registry-derived (`LeanFmt/Config.lean`), so `--select security` works with no hardcoded list. The
external prerequisite stacks `ruff-05-rule-engine` and `ruff-06-fix-safety` remain verified and their
live code was re-read against this work.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RSR-SPEC | verified | — |
| 02-implementation | RSR-IMPL | verified | RSR-SPEC |
| 03-acceptance | RSR-FINAL | verified | RSR-IMPL |

## Known evidence

- **Two report-only source rules ship; BOM and mixed endings stay rejected.** `FMT003` scans the
  shared `SourceFacts.bytes` (no decode); `FMT004` is one `String.foldl` decoding each scalar once and
  carrying the byte offset, so a multibyte mark's range is its exact UTF-8 span. Both satisfy the
  "no parser/project capability" and "avoid repeated UTF-8 decoding" stop rules. Measured byte-exact:
  `FMT003 [11,12) U+0000`, `FMT004 [19,22) U+202E`, both `fix=false`.
- **No hidden hardcoded lists.** The registry is the single source: suppression (projection over
  codes), the `rules` command, config selection, and reporting all pick up FMT003/FMT004 with no
  further code. Category selection was generalized (`isCategory` reads the registry) rather than given
  a second `"text"`-style literal. Confirmed by `testConfig`/`testSuppression`/`tests/modes`, not
  assumption.
- **TAB exclusion is load-bearing.** `testRules`' fixture ends a line with `\t`; the catalog's TAB
  exclusion keeps that unrelated test finding-clean. Confirmed against live tests.
- **The scans are linear and worker-free, measured, not argued.** `tests/security/bench.sh` over
  `LeanFmtTest.security-bench`: 7.8× across an 8× size step (2.5→20 MB), flat ~5 ns/byte at every
  doubling, in one process with ~152 MiB peak RSS (`results/03-acceptance.md`,
  `evidence/03-security-bench.txt`). The clean regime isolates the scan from the engine's shared
  O(m log m) finding-sort; the dense regime confirms 32,768 findings fire at scale, worker-free.
- **The whole pipeline surfaces the findings, not just the scan.** `tests/check/Security.lean` is a
  committed byte corpus (U+202E in a comment, NUL in a string); `check --no-cache` reports
  `FMT004 [17,20)` then `FMT003 [45,46)`, report-only, no write. `testSourceSecurityProperties` pins
  the scans differentially against an independent oracle over 120 LCG inputs plus four edges.

## Blockers and prerequisites

- **`ruff-01` precision gap (non-blocking, handed off).** LF/CRLF-intermixed files are accepted yet
  classified `.crlf`; write safety holds via `ruff-01` round-trip invariant 4. See
  `notes/01-catalog.md` §4. Not this stack's to fix.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
