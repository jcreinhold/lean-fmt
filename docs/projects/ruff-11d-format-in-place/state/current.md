---
kind: state
first_unresolved: 03-final
---

# Current state

FIP-SPEC and FIP-IMPL are verified. `lean-fmt format` now publishes the canonical layout in place by
default — like `ruff format`. The writer is `formatFile` (`Application.lean`, structurally `fixFile`
with `renderCanonical := true`, status `formatted`), routed through the `ruff-06` guarded path
(stale-source check, exact-setup validation on the reflowed bytes, atomic lossless publish). `format
--check` (a `RunRequest.formatCheck` flag, gated in `Cli.lean`) is the non-writing CI preview
(`would-format`, exit 1 on a would-change); the writer exits 0 on a published change like `fix`. The
`Cli.lean` output arm is a concise per-file summary, not the file body; `--json` is unchanged. The
CLAUDE.md invariant now reads "`check` and `diff` never write source. `format` and `fix` publish …". All
product/unit/boundary suites pass; the `tests/modes` confluence test was rewritten so both composition
orders materialize on disk. `diff` stays `ruff format --diff`; `check` and `diff` still never write.

Scope was fixed with the owner to the **minimal default-flip**: config-scoped file selection stays
`ruff-13-config-discovery`, and stdin/stdout + range stays `ruff-14-stream-range`. No-arg selection uses
the existing `Project.load` discovery (`discoverPaths` + `config.includesPath`), so this stack changes
only what happens to each resolved file, not which files are chosen.

First unresolved is 03-final (FIP-FINAL): accept the in-place default adversarially through the product
CLI and persistent tests — exact written bytes (and no rule fix on the written file), idempotence,
`--check` never writes, a broken file never written (no orphan temp), CRLF and in-string round-trip on
write, the stale-source guard on format's write, `check`/`diff` still never write, format+fix confluence
with format writing, and no-arg project-wide write of exactly the included set. No full mathlib run.

Prerequisite stacks `ruff-04-formatter-product`, `ruff-06-fix-safety`, and `ruff-11c-decouple-fix-format`
are all verified. If live code contradicts a prerequisite result, reopen the owning prerequisite rather
than patching around it. Full mathlib is not development evidence.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | FIP-SPEC | verified | — |
| 02-impl | FIP-IMPL | verified | FIP-SPEC |
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
