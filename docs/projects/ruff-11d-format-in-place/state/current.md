---
kind: state
first_unresolved: 02-impl
---

# Current state

FIP-SPEC is verified (spec-only, no code changed). The frozen interface is in `notes/01-model.md`; the
first-hand characterization of today's non-writing `format` is in `evidence/01-current-format.md`. This
stack makes `lean-fmt format` write the canonical layout in place by default — like `ruff format` —
closing the last operational gap a Ruff user hits after `ruff-11c` decoupled lint-fix from formatting.
Today `format` only previews: it prints canonical output to stdout with `=== file (N bytes) ===` framing
and never writes; `fix` is the sole writer. This stack flips `format`'s default disposition from
**print** to **publish-in-place**, reusing the proven `ruff-06` guarded publish path (stale-source check,
exact-setup validation, atomic replace, lossless denormalization) applied to the `ruff-11c` layout patch.
`format --check` becomes the non-writing preview (ruff's CI mode); `diff` stays as `ruff format --diff`;
`check` and `diff` still never write.

Scope was fixed with the owner to the **minimal default-flip**: config-scoped file selection stays
`ruff-13-config-discovery`, and stdin/stdout + range stays `ruff-14-stream-range`. No-arg selection uses
the existing `Project.load` discovery (`discoverPaths` + `config.includesPath`), so this stack changes
only what happens to each resolved file, not which files are chosen.

First unresolved is 02-impl (FIP-IMPL): route `format` through the guarded publish (a `formatFile`
wrapper analogous to `fixFile`, `renderCanonical := true`), add the `--check` flag, replace the
`Cli.lean` stdout-dump output arm and the `reportExitCode` branch, apply the CLAUDE.md invariant change
and the model §4 grep-list rewrites, and migrate the `tests/modes` format assertions from
stdout/`would-format`-by-default to in-place write + `--check`. Implement exactly the frozen interface —
no surface beyond the model §6 reuse-vs-new inventory.

Prerequisite stacks `ruff-04-formatter-product`, `ruff-06-fix-safety`, and `ruff-11c-decouple-fix-format`
are all verified. If live code contradicts a prerequisite result, reopen the owning prerequisite rather
than patching around it. Full mathlib is not development evidence.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | FIP-SPEC | verified | — |
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
