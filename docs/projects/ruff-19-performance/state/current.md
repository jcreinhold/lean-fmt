---
kind: state
first_unresolved: 01-baseline
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-04-formatter-product`, `ruff-12-rule-lifecycle`, `ruff-17-lsp`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-baseline | RPR-SPEC | planned | — |
| 02-optimize | RPR-IMPL | planned | RPR-SPEC |
| 03-regressions | RPR-FINAL | planned | RPR-IMPL |

## Inherited from `ruff-15-reporting` (verified)

The completion contract names **rendering** as a profiled phase. `ruff-15` produced its baseline, and
one result changes what to profile:

- **Rendering is linear in report size across three decades and is not a scale risk.** 100 / 1,000 /
  10,000 / 100,000 findings through all six formats; 10× the report costs ~10× the milliseconds in
  every one, `Lean.Json.pretty` over a 50 MB SARIF log included
  (`ruff-15/evidence/03-report-scale.md`, driver `lake exe lean-fmt-tests report-bench`).
- **The cost is the position index, not the serializers.** At 100,000 findings, position-free `text`
  renders 33× faster than `concise` *while emitting more bytes* (7.82 MB against 6.95 MB), and `json`
  serializes 14 MB with no lookups faster than `concise` serializes 7 MB with 200,000 of them. If this
  stack profiles rendering, the two `PositionIndex` lookups per finding are the line item — the
  serializer is not where the time is, which is the opposite of what `RRF-IMPL` assumed.
- **What the benchmark does not cover, and this stack could.** The fixture's lines are uniform, so it
  exercises index *lookup* but not index *build* on a pathological source (one enormous line, findings
  clustered at the end of a very large file). The build is one forward pass, O(source bytes) by
  construction, and is unmeasured.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
