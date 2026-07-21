---
kind: state
first_unresolved: 01-audit
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-18-integrations`, `ruff-19-performance`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-audit | RCP-SPEC | planned | — |
| 02-acceptance | RCP-ACCEPT | planned | RCP-SPEC |

## Inherited from `ruff-16-watch-incremental` (verified)

- **New surface to cover:** `--watch`, `--poll-interval`, `--changed`, `--changed-since REV`,
  `--staged`, and their rejections (writing modes under watch; document formats on stdout under watch;
  `--changed` beside explicit file targets; `--poll-interval` without `--watch`).
- **A partial run must never read as a complete clean one.** `ruff-16` treats this as the stack's
  central honesty rule: a `--changed` run announces its comparison, resolved base, every withheld path
  and that it covered a subset, and a zero-selection run says so explicitly instead of reporting a
  clean project. Audit that this survives.
- **`ruff-16` shipped a bug that its own repository could not reveal** — an untracked non-Lean file
  aborted every `--changed` run, invisible because this repository ignores `.lake` and carries no
  stray untracked files. It surfaced only against a purpose-built fixture repository. Prefer fixture
  repositories over the project's own tree when auditing selection.
- **The same lesson, unfixed, is still in `tests/watch/run.sh`, and repairing it is this stack's.**
  §9.6's "an empty staged selection succeeds" runs `check --staged --root .` after `cd "$repo_root"`
  (`tests/watch/run.sh:200,272`) — against the real repository — and requires the output to say "no
  changed Lean sources". Stage any `.lean` file and the selection is no longer empty and the suite
  fails. The assertion it wants is about *zero selected files*, which a fixture repository can
  guarantee and the project's own index cannot; the bullet above already says so, and this is the case
  that did not get moved. It is the one suite in the sweep whose result depends on ambient state, so it
  is also the one whose failure is most likely to be *waived* rather than read — which RCP-SPEC's
  "repair root causes rather than waive failures" is exactly about. Reported by `ruff-17-lsp`, which
  hit it while committing (`ruff-17-lsp/state/current.md`).

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
