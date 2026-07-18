---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RSR-SPEC` and `RSR-IMPL` are **verified**. The frozen catalog is `notes/01-catalog.md`; what was run
is `results/01-catalog.md` and `results/02-implementation.md`. The two approved rules are live in
`LeanFmt/Rules.lean`'s `ruleRegistry`: `FMT003` (forbidden control byte) and `FMT004` (suspicious
bidirectional control), both report-only, category `security`, default-enabled. Category selection is
now registry-derived (`LeanFmt/Config.lean`), so `--select security` works with no hardcoded list. The
external prerequisite stacks `ruff-05-rule-engine` and `ruff-06-fix-safety` remain verified and their
live code was re-read against this work.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RSR-SPEC | verified | — |
| 02-implementation | RSR-IMPL | verified | RSR-SPEC |
| 03-acceptance | RSR-FINAL | planned | RSR-IMPL |

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

## Remaining work

- **`RSR-FINAL` (03-acceptance)**: property/fuzz-style boundary tests and large-file microbenchmarks
  (the linear-time and worker-free claims), and the final catalog record. A committed-byte corpus for
  end-to-end control/bidi coverage belongs there.

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
