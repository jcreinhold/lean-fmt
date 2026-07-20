# 01-protocol — RLP-PROTOCOL

Claim: **RLP-PROTOCOL** — freeze the LSP capability and state model.
Status: **verified**.
Design: `notes/01-protocol.md`. Evidence: `evidence/01-lsp-baseline.md`,
`evidence/01-position-probe.lean`, `evidence/01-position-probe.txt`.
Machine: Darwin 25.5.0 (arm64). Toolchain `leanprover/lean4:v4.33.0-rc1`. Base commit `7acd42c`.

## What shipped

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC,
`ruff-14` RSF-SPEC), this prompt ships **no production Lean interface, config key, or CLI surface** —
the freeze, its evidence, and one characterization test.

| File | What it is |
| --- | --- |
| `notes/01-protocol.md` | the freeze: 15 sections, §15 hands named obligations to 02/03/04 |
| `evidence/01-lsp-baseline.md` | measured baseline: no LSP surface, the `serve` surface, the toolchain's inventory, Lean's own capabilities, the five position facts |
| `evidence/01-position-probe.lean` | the probe, runnable from the repository root |
| `evidence/01-position-probe.txt` | its raw output |
| `LeanFmtTest.lean` `testLspPositions` | the characterization test pinning the central claim |

## Commands run

```
$ lake build
Build completed successfully (52 jobs).

$ lake env lean --run docs/projects/ruff-17-lsp/evidence/01-position-probe.lean
(recorded verbatim in evidence/01-position-probe.txt)

$ LEAN_NUM_THREADS=1 lake build lean-fmt-tests
Build completed successfully (50 jobs).

$ lake exe lean-fmt-tests
lean-fmt module-artifact tests passed

$ tests/boundary/run.sh
(see "Checks read" below)

$ git diff --check
(no output)
```

## Measurements

All from `evidence/01-position-probe.txt` unless noted.

| Measurement | Value |
| --- | --- |
| `theorem t : 𝔘 = 𝔘 := rfl\nsecond line\n` | 43 bytes / 39 UTF-16 units / 37 codepoints |
| byte 24 → codepoint column (`PositionIndex`) | 19 |
| byte 24 → UTF-16 column (`FileMap`) | 20 |
| byte 24 → byte column | 25 |
| LSP `(0,9999)` in a 43-byte document | byte **10003** — not clamped |
| LSP `(99,0)` | byte 43 — saturates |
| byte 20, interior to a codepoint | LSP `(0,39)` — silently wrong |
| LSP `(0,10)`, interior to a surrogate pair | byte 13 — snaps forward past the character |
| LSP `(1,0)`, CRLF vs normalized twin | byte 12 vs byte 11 |
| `fileUriToPath? "untitled:Untitled-1"` | `none` |
| formatting providers in `Lean.Lsp.ServerCapabilities` | 0 of 18 fields |
| formatting methods implemented in `Lean/Server/` | 0 |
| `monitorChild` poll interval (`Application.lean:288`) | 50 ms |

The three-number separation at byte 24 is the one that mattered. At byte 16 — one astral character
into the line — both spellings answer 14, because 1-based codepoints and 0-based UTF-16 units differ
by one in the *other* direction and the single astral character's extra unit cancels it exactly. A
fixture with one astral character would have passed while pinning nothing. This was found by writing
the assertion and watching it not distinguish anything, not by reasoning.

## Decisions changed during execution

1. **Incremental text sync, not full.** Initially leaning to full sync on the strength of `ruff-14`'s
   "a range is not cheaper than the whole buffer". That argument does not transfer: analysis is per
   *request* and debounce collapses keystrokes into one; sync payload is per *change notification* and
   collapses not at all. `notes` §6, with the differential test that makes the risk testable.
2. **`force-exclude` is evaluated on document admission** — new behavior relative to `Application.stream`,
   which does not evaluate it (`Project.unsavedTarget`, `Project.lean:169-188`, has no such clause;
   `Project.load` does, at `Project.lean:221-226`, for explicitly named paths). The stdin surface is
   right to treat a typed path as an explicit selection. An editor opening whatever the user clicks is
   not that act, and if `lean-fmt format vendored.lean` reports nothing then the editor must too, or
   the editor has become the second configuration path the roadmap forbids. `Discovery.explain` already
   answers this question for arbitrary paths (`Discovery.lean:437-448`), so it costs no new matcher.
   `notes` §5, obligation 4.
3. **`Lean.Server.*` is excluded from production imports**, `Lean.Data.Lsp` is not. `applyDocumentChange`
   lives in `Lean.Server.Utils`, which transitively imports `Lean.Server.InfoUtils` — the elaborator's
   info-tree machinery. `replaceLspRange` is fifteen lines and is reimplemented over our own document
   record instead. `Lean.Data.Lsp.Ipc` remains available to the RLP-FINAL harness. `notes` §2.
4. **`Lsp.Diagnostic`'s Lean extension fields are suppressed.** `DiagnosticWith.fullRange?` defaults to
   `some range` (`Diagnostics.lean:126`), so reusing the type naively emits a Lean-server extension on
   every diagnostic of every document. Reuse the type, set `fullRange?`/`isSilent?`/`leanTags?` to
   `none`. `notes` §2.
5. **No `diagnosticProvider`, no `willSaveWaitUntil`, no `executeCommandProvider`, no
   `workspace/didChangeWatchedFiles`.** Each is a capability the product would have to advertise
   semantics for that it does not have: pull diagnostics with result IDs are incremental semantics
   (the prompt's stop rule); `willSaveWaitUntil` puts a formatter on the critical path of every save
   with no way to decline; commands are unnecessary when every action carries its own `WorkspaceEdit`;
   and a client-side config watcher is a second discovery path `ruff-16` already owns. `notes` §8, §10.

## What was confirmed rather than assumed

- **The LSP path never calls `execute`** — but not for the reason `state/current.md` inherited from
  `ruff-16`. That attribution was refuted by `ruff-16b` `RCI-SPEC` and the real defect fixed by
  `RCI-IMPL`. The live reason is that `execute` selects, caches, and publishes, and a buffer that is
  not on disk has no disk state for a cache entry to bind to (`Application.lean:1508-1509`). `notes` §3.
- **`ExactRun` has no cancellation input today.** `monitorChild` polls `child.tryWait` every 50 ms and
  checks only the memory envelope (`Application.lean:266-289`). The freeze names the addition — a
  cancel token consulted in that same poll, killing the child by the path the envelope-exhaustion
  branch already uses — and it is an addition to an existing loop, not a missing lower layer.
  `notes` §9, obligation 3.
- **`Application.organize` was built for this.** Its docstring (`Application.lean:1611`) has named the
  LSP "organize imports" capability since `ruff-09`. Obligation 6 collects the promise.

## Checks read

- `lake build` — clean, 52 jobs.
- `LEAN_NUM_THREADS=1 lake build lean-fmt-tests`, `lake exe lean-fmt-tests` — clean; `testLspPositions`
  is wired into the default suite (`LeanFmtTest.lean`, after `testServiceProtocol`).
- `tests/boundary/run.sh` — clean. No module boundary changed: the only production-adjacent edit is a
  test module gaining `import Lean.Data.Lsp`.
- `git diff --check` — no output.
- Stack structural checker and `write_next.py --check` — see the transcript below.

## Remaining uncertainty

- **Whether one exact frontend child per debounced keystroke is fast enough to feel like an editor.**
  Nothing here measures it, and this stack's evidence policy forbids full mathlib. `ruff-19-performance`
  owns the number. The freeze is careful not to claim a latency it has not measured.
- **The debounce interval, document-count bound, and queue depth** are named but not valued. RLP-DOCUMENTS
  measures and sets them (`notes` §14).
- **Multi-root workspaces are served as one root with a `showMessage`.** That is a deliberate limitation,
  not a measured one; if a real client makes it painful the decision reopens here rather than being
  patched around downstream.
- **Incremental sync correctness** is argued and made testable, not yet tested. Obligation 2 is the
  discharge, and it is the one obligation whose failure would corrupt a user's file rather than merely
  annoy them.
