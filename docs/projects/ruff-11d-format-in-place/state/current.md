---
kind: state
first_unresolved: 01-spec
---

# Current state

New stack, nothing implemented yet. It makes `lean-fmt format` write the canonical layout in place by
default — like `ruff format` — closing the last operational gap a Ruff user hits after `ruff-11c`
decoupled lint-fix from formatting. Today `format` only previews: it prints canonical output to stdout
with `=== file (N bytes) ===` framing and never writes; `fix` is the sole writer. This stack flips
`format`'s default disposition from **print** to **publish-in-place**, reusing the proven `ruff-06`
guarded publish path (stale-source check, exact-setup validation, atomic replace, lossless
denormalization) applied to the `ruff-11c` layout patch. `format --check` becomes the non-writing preview
(ruff's CI mode); `diff` stays as `ruff format --diff`; `check` and `diff` still never write.

Scope was fixed with the owner to the **minimal default-flip**: config-scoped file selection stays
`ruff-13-config-discovery`, and stdin/stdout + range stays `ruff-14-stream-range`. No-arg selection uses
the existing `Project.load` discovery (`discoverPaths` + `config.includesPath`), so this stack changes
only what happens to each resolved file, not which files are chosen.

First unresolved is 01-spec (FIP-SPEC): freeze the interface — the guarded write, the `--check` preview,
the exit-code and report-status semantics, the CLAUDE.md invariant change (from "check, format, and diff
never write; fix publishes" to "check and diff never write; format and fix publish … validated … after a
stale-source check"), and the reuse-vs-new inventory — before any code change.

Prerequisite stacks `ruff-04-formatter-product`, `ruff-06-fix-safety`, and `ruff-11c-decouple-fix-format`
are all verified. If live code contradicts a prerequisite result, reopen the owning prerequisite rather
than patching around it. Full mathlib is not development evidence.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | FIP-SPEC | planned | — |
| 02-impl | FIP-IMPL | planned | FIP-SPEC |
| 03-final | FIP-FINAL | planned | FIP-IMPL |

## Scope

- **In scope:** `format` publishes the canonical layout in place by default via the `ruff-06` guarded
  path; the `format --check` non-writing preview; exit-code and report-status parity with `fix`/`ruff
  format`; the CLAUDE.md invariant change and doc/comment migration; migrating `format` tests from
  stdout-preview to in-place write + `--check`.
- **Out of scope:** config-scoped selection and formatter/linter config sections (`ruff-13`); stdin/stdout
  single-stream and range formatting (`ruff-14`); formatter style policy (`ruff-04`, done); reporting
  formats (`ruff-15`); the editor service (drives `ExactRun`, not the CLI `format` verb).

## Blockers and prerequisites

- No blocker. The publish path `format` reuses is `ruff-06`, verified. The layout patch it publishes is
  `ruff-11c`, verified.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
