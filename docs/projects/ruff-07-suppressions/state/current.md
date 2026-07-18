---
kind: state
first_unresolved: none
---

# Current state

**The stack is complete: `RSP-SPEC`, `RSP-IMPL`, and `RSP-FINAL` are all verified.** The
source-suppression layer is live: `LeanFmt/Suppression.lean` parses directives from the lossless
comment trivia (plus the module header), projects them over the config-selected findings after the
result cache, and reports the unused (`FMT900`) and malformed (`FMT901`) self-diagnostics. What was
run is `results/02-implementation.md` and `results/03-acceptance.md`; the scope/placement/recovery
matrix is `evidence/02-suppression.txt` and the acceptance matrix is `evidence/03-acceptance.txt`,
frozen as the regression suite `tests/suppression/run.sh`. The prerequisite stacks
`ruff-05-rule-engine`, `ruff-05b-semantic-facts`, and `ruff-06-fix-safety` remain verified and were
re-read against live code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSP-SPEC | verified | — |
| 02-implementation | RSP-IMPL | verified | RSP-SPEC |
| 03-acceptance | RSP-FINAL | verified | RSP-IMPL |

## Known evidence

- **Every scope suppresses where designed.** `ignore-file`/`ignore-next` at the top of the file, after
  an `import`, in the body, and as a trailing comment all suppress (`evidence/02-suppression.txt`).
- **The module header is scanned directly.** `Comments.allTrivia` omits `[0, headerStop)`, so a
  top-of-file directive was silently inert until `Suppression.headerComments` was added; the header
  grammar (only `module`/`import`/whitespace/comments) makes a small scanner safe (`results/02` §1).
- **Suppression shapes the report, not the patch.** `format`/`fix` reformat unconditionally; a directive
  silences a diagnostic without changing published bytes, so `check`/`diff`/`format`/`fix` agree
  (`results/02` §2). Batch `fix` therefore does not auto-remove an unused directive; `RSP-FINAL`
  ratified this as the final boundary — auto-removing during a format pass would silently delete a
  comment the author wrote, which the round-trip stop rule forbids. The `FMT900 [safe]` removal (a
  clean-line edit, newline included) is an editor code-action surfaced via `--json`/LSP.
- **The full acceptance matrix holds (`RSP-FINAL`).** Doc comments / module docstrings are tokens, so
  directive text in them is inert; nested syntax, same-line comments, custom commands, file ignores,
  and per-file config all resolve as designed; and a directive tracks its target across `fix`
  reformatting, becoming an honest `FMT900` only once the finding it silenced is itself fixed away.
  Config-ignore and source-suppression stay distinct layers: config selects first, suppression
  projects over the remainder, so a directive redundant with config is `FMT900` (the RUF100 analog).
  Transcript `evidence/03-acceptance.txt`; regression suite `tests/suppression/run.sh`.
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
