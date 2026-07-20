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
- Every served document has a project location. `ruff-14` froze that a buffer's identity — not its content — resolves its effective configuration, module name, and exact Lake setup, and that a buffer with no location must be **rejected** rather than served against built-in defaults, because that would make the editor a second configuration path answering differently than the same bytes on disk. `untitled:` documents and URIs outside the workspace root are that case and this stack must decide it explicitly; every gate `Project.unsavedTarget` applies, including the `.lake` floor, still applies through the protocol.
- Range formatting reports the reflow-expanded actual range (inherited from `ruff-14`, since reflow can rebreak the enclosing unit past the client selection), and dynamic `line-width` reconfiguration re-formats affected open documents rather than serving output rendered at the old margin. **Repeated range formatting is a fixed point only in output coordinates**: formatting changes a unit's length, so re-sending the originally *requested* range over the result names a different region and can reach into the next command. Serve the `sourceMap` the range answer already carries and expect clients to send back the range the unit now occupies; `ruff-14`'s own suite asserted the convenient version first and failed.
- Document versions prevent stale publication; capacity, request bytes, pending work, and child processes are bounded.
- No second parser, formatter, rule engine, project resolver, or persistent cache for unsaved buffers. Concretely, `ruff-14` already built the operations this stack needs and they are what "no second formatter" names: `Application.stream` (one unsaved buffer, one bounded exact child, no cache, no write), `Application.sliceRange` (unit selection, forward extension, actual range, splice), `Printer.formatWithMap` (one render, text and source map), and `Project.unsavedTarget`/`loadWorkspaceOnly` (identity from a path with no filesystem read for content). Consume them; do not re-derive range expansion above them.

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
