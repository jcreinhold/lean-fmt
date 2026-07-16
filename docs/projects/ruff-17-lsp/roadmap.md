---
kind: roadmap
topic: "Native Language Server Protocol service"
main_results: [RLP-FINAL]
prereq_stacks: [ruff-06-fix-safety, ruff-07-suppressions, ruff-13-config-discovery, ruff-14-stream-range]
blueprint_tracked: false
---

# Native Language Server Protocol service

## Goal

Replace the private editor-facing NDJSON product surface with a native LSP server using the same exact snapshot-analysis, formatting, and fix primitives.

## Completion contract

- Support initialize/shutdown/exit, document open/change/close, diagnostics, document formatting, range formatting, code actions, fix-all, organize imports, cancellation, and dynamic configuration.
- Honor UTF-16 LSP positions through one tested conversion layer while internal source ranges remain UTF-8 bytes.
- Document versions prevent stale publication; capacity, request bytes, pending work, and child processes are bounded.
- No second parser, formatter, rule engine, project resolver, or persistent cache for unsaved buffers.

## Work order

1. **RLP-PROTOCOL — Freeze LSP capability and state model.** Specify capabilities, initialization options, workspace roots, text synchronization, UTF-16 conversion, diagnostic ownership, cancellation, dynamic config, error codes, and coexistence with Lean language servers.
2. **RLP-DOCUMENTS — Implement transport and document lifecycle.** Add Content-Length framing, initialize/shutdown, bounded document store, didOpen/didChange/didClose, versions, cancellation tokens, configuration reload, health/logging, and malformed-message recovery.
3. **RLP-FEATURES — Implement diagnostics, formatting, and code actions.** Connect exact unsaved analysis, whole/range formatting, individual safe fixes, fix-all, organize imports, and workspace edits with version checks and applicability exposure.
4. **RLP-FINAL — Run protocol, editor, and resource acceptance.** Use an independent LSP client harness for lifecycle, concurrent cancellation, Unicode positions, dynamic config, malformed messages, code actions, and 100-request memory stability. Document VS Code/Neovim/Emacs setup inputs.

## Evidence and verification

Every prompt writes `results/01-protocol.md`-style result notes with commands, raw measurements,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack unless this is the
final acceptance stack and its prompt explicitly authorizes it.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker, generated-next
check, and `git diff --check`. Performance records name workload, profile, cache/build state,
machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
