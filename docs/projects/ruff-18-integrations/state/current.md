---
kind: state
first_unresolved: 01-contract
---

# Current state

This stack is planned and has not begun. Its external prerequisite stacks are
`ruff-15-reporting`, `ruff-16-watch-incremental`, `ruff-17-lsp`. Before starting, confirm those roadmaps are verified and their live
implementation still matches recorded state.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-contract | RDI-SPEC | planned | — |
| 02-assets | RDI-IMPL | planned | RDI-SPEC |
| 03-acceptance | RDI-FINAL | planned | RDI-IMPL |

## Inherited from `ruff-15-reporting` (verified)

The roadmap's "document GitHub Actions and generic CI using machine formats" now has a frozen surface
to document rather than invent. `ruff-15/notes/01-report-formats.md` is the source; the four facts a CI
recipe gets wrong if it guesses:

- **The exit code is independent of the output format.** 0 clean, 1 findings, 2 infrastructure. A
  recipe never needs to parse a report to learn whether the run succeeded, and `--output-format` never
  changes what the job's status will be.
- **A broken pipe keeps the run's own exit code.** `lean-fmt check … | head` does not become a success.
  This was corrected during `RRF-IMPL` precisely because the alternative would have made a pipe a way to
  silence CI — so a documented recipe may use pipelines freely.
- **`--output-file` is pre-checked and atomic.** A missing directory fails before the run rather than
  after it, and a polling consumer never sees a truncated SARIF log. This is what makes an
  `upload-sarif` step safe to run unconditionally.
- **The four finding-shaped formats are rejected for `diff`**, at parse time. A recipe that offers
  `--output-format` as a free-form knob alongside `diff` will fail; the CI documentation should pair
  formats with modes.

SARIF is emitted for GitHub code scanning specifically: `columnKind: unicodeCodePoints`,
`originalUriBaseIds` with `%SRCROOT%`, percent-encoded `uri`s, and `helpUri` per rule. It validates
against the vendored 2.1.0 schema in `tests/reporting/`, so a CI example can be checked offline.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
