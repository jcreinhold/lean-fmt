---
kind: roadmap
topic: "format writes canonical layout in place by default, like ruff format"
main_results: [FIP-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-06-fix-safety, ruff-11c-decouple-fix-format]
blueprint_tracked: false
---

# format writes in place by default

## Goal

Make `lean-fmt format` behave like `ruff format`: **write the canonical layout back to disk in place**,
by default, for the resolved file set — so a user who runs `lean-fmt format` in a project reformats every
included `.lean` file, exactly as `ruff format` reformats every included `.py` file. Preserve a
non-writing preview under `format --check` (ruff's CI mode: no write, exit non-zero if any file would
change), and keep the existing `diff` subcommand as the diff preview (`ruff format --diff`). `check` and
`diff` continue to never write.

This closes the last operational gap a Ruff user hits after `ruff-11c` decoupled lint-fix from
formatting: the verbs and their separation already match Ruff (`check`/`fix` lint, `format`/`diff` reflow,
composed as `ruff check --fix && ruff format`), but `format` today only *previews* — it prints canonical
output to stdout with `=== file (N bytes) ===` framing and never writes. `fix` is the sole writer. This
stack flips `format`'s default disposition from **print** to **publish-in-place**.

## Origin

`ruff-11c` (RDF-FINAL, verified) established that `format` renders canonical layout and applies no rule
fix, and that its output is byte-stable and composes with `fix` to a single fixed point in both orders.
It deliberately left `format` as a stdout preview: the CLAUDE.md invariant reads *"check, format, and diff
never write source; fix publishes."* A first-hand review after RDF-FINAL (with the owner) found this is
the one place a Ruff user does not "understand immediately" — `ruff format file` rewrites the file, but
`lean-fmt format file` dumps to stdout with framing that cannot even be cleanly redirected back. The
publish machinery to fix this already exists and is proven: `fix` writes through `publishAtomic` +
a stale-source check + re-elaboration validation under the exact module setup + lossless
denormalization (`Application.lean`, `ruff-06-fix-safety`). Format-in-place is that same guarded publish
applied to the **layout** patch instead of the fix patch.

## The change, made precise

- **`format` publishes in place by default.** For each resolved file it renders `canonical.text` (the
  layout patch `ruff-11c` already produces — no rule fix) and writes it back through the *same* guarded
  publish path `fix` uses: stale-source check, validation under the exact module setup, atomic replace,
  and lossless denormalization to the file's original line endings. Write-safety is therefore preserved,
  not weakened: a file that does not elaborate is reported `broken` and never written; a partial write is
  impossible.
- **`format --check` is the non-writing preview.** No file is written; the run reports which files *would*
  change and exits non-zero when any would (ruff's CI/`--check` semantics). This replaces today's
  stdout-preview-as-default.
- **`diff` is unchanged** — the unified-diff preview, `ruff format --diff`. `check` and `diff` still never
  write.
- **No-arg selection is the existing project discovery.** `Project.load` already walks the root for
  `.lean` files (excluding `.lake`) filtered through `config.includesPath` when no explicit files are
  given (`Project.lean`), so `lean-fmt format` with no arguments already resolves the right set; this
  stack changes only what happens to each resolved file (publish vs. print), not which files are chosen.

## What is preserved unchanged

- The `ruff-11c` layout/fix split: `format` still applies **no** rule fix; `fix`/`check --fix` still apply
  fixes at original coordinates with no reflow; the two still compose to one fixed point in both orders.
- Every `ruff-06` write guarantee, reused verbatim by `format`: applicability/conflict handling,
  atomic publish, exact-setup validation, and the stale-source check.
- Lossless identity: the write denormalizes normalized (LF) canonical text back to the file's raw line
  endings through `LosslessSource.denormalize`, exactly as `fix` does; digests and coordinates keep the
  one normalized coordinate system.
- `check` and `diff` never write. The editor service (`LeanFmt.Service`) is unaffected — it drives
  `ExactRun` directly, not the CLI `format` verb.

## Explicit exclusions (owned by later stacks)

- **Config-scoped file selection** — formatter/linter config sections, include/exclude globs beyond
  today's `includesPath` — is `ruff-13-config-discovery`. This stack uses the selection that exists.
- **stdin → stdout single-stream and range formatting** (`format -`, `--stdin-filename`, `--range`) is
  `ruff-14-stream-range`. Today's stdout behavior is not preserved as a flag here; it becomes ruff-14's
  stream mode. If a temporary stdout escape hatch proves necessary during migration, FIP-SPEC records it
  as a named, minimal, ruff-14-superseded stopgap, not a designed surface.
- Formatter style policy (`ruff-04`, done) and reporting formats (`ruff-15`) are unchanged.

## Work order

| Prompt | Claim | Deliverable | Depends on |
| --- | --- | --- | --- |
| 01-spec | FIP-SPEC | Freeze the interface: `format` publishes in place via the `ruff-06` guarded path; `--check` preview; exit-code and report-status semantics; the CLAUDE.md invariant change; reuse-vs-new inventory | — |
| 02-impl | FIP-IMPL | Route `format` through the guarded publish; add `--check`; migrate `tests/modes` and any format assertions from stdout-preview to in-place write + `--check` preview; keep `diff`/`check` non-writing | FIP-SPEC |
| 03-final | FIP-FINAL | Adversarial acceptance: exact bytes, idempotence, `--check` never writes, broken-file never written, CRLF/lossless round-trip on write, stale-source guard, format+fix confluence with format now writing, no-arg project-wide write | FIP-IMPL |

## Evidence and verification

Focused fixtures, the frozen representative mathlib sample, and named stress files are the development
evidence; full mathlib is forbidden here (only `ruff-20-acceptance` runs it). Each prompt writes
`results/<stem>.md`; state is updated after the checks are read; `state/next.md` is regenerated. The
owning-layer suites are `tests/modes/run.sh` (the format verb), `tests/check/run.sh`, and
`tests/lossless/run.sh` (write round-trip), plus `lake exe lean-fmt-tests`. Structural and architecture
gates: `check_stack.py --structural`, `check_prompt_architecture.py`, `write_next.py --check`, and
`git diff --check`.

## Blueprint

This is a product/tooling stack with no mathematical theorem claims; `blueprint_tracked: false`.

## Stop rules

- No write that skips the `ruff-06` guards: format must not write a file that fails the stale-source check
  or validation, and must never leave a partial file. `check` and `diff` must still never write.
- The `ruff-11c` split must hold: `format` applies no rule fix, `fix` does no reflow, and their
  composition still reaches one fixed point. Do not reintroduce fix application into `format`.
- Lossless identity must hold on write: original line endings are restored; no in-string byte is altered.
- No full mathlib run. Stop rather than weakening a preserved invariant.
