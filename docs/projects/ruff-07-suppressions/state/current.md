---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RSP-SPEC` and `RSP-IMPL` are **verified**. The source-suppression layer is live: `LeanFmt/Suppression.lean`
parses directives from the lossless comment trivia (plus the module header), projects them over the
config-selected findings after the result cache, and reports the unused (`FMT900`) and malformed
(`FMT901`) self-diagnostics. What was run is `results/02-implementation.md`; the scope/placement/recovery
matrix is `evidence/02-suppression.txt`. The prerequisite stacks `ruff-05-rule-engine`,
`ruff-05b-semantic-facts`, and `ruff-06-fix-safety` remain verified and were re-read against live code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSP-SPEC | verified | — |
| 02-implementation | RSP-IMPL | verified | RSP-SPEC |
| 03-acceptance | RSP-FINAL | planned | RSP-IMPL |

## Known evidence

- **Every scope suppresses where designed.** `ignore-file`/`ignore-next` at the top of the file, after
  an `import`, in the body, and as a trailing comment all suppress (`evidence/02-suppression.txt`).
- **The module header is scanned directly.** `Comments.allTrivia` omits `[0, headerStop)`, so a
  top-of-file directive was silently inert until `Suppression.headerComments` was added; the header
  grammar (only `module`/`import`/whitespace/comments) makes a small scanner safe (`results/02` §1).
- **Suppression shapes the report, not the patch.** `format`/`fix` reformat unconditionally; a directive
  silences a diagnostic without changing published bytes, so `check`/`diff`/`format`/`fix` agree
  (`results/02` §2). Batch `fix` therefore does not auto-remove an unused directive — an open item for
  `RSP-FINAL` ("unused fixes").
- **A directive inside a string is inert.** Directives are comment trivia only; a string is a token, so
  `InString.lean` reports its finding unsuppressed — the `RSP-SPEC` stop rule holds by construction.
- **Cache identity unchanged.** Directives are cached content (`SemanticResult.suppression`, schema
  `v4`), not a key; config selection still projects afterward. Infrastructure failures are never
  findings and remain unsuppressible.
- **Corpus figures re-synced.** Adding `Suppression.lean` grew this repo's own printer corpus; the
  `ruff-03` shape evidence and every figure quoting it were regenerated (541 commands, 53,760 nodes).

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
