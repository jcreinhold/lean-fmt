# 02-documents — RLP-DOCUMENTS

Claim: **RLP-DOCUMENTS** — transport, lifecycle, and the bounded document store.
Status: **verified**.
Design: `notes/01-protocol.md` (amended twice by this prompt; see "Decisions changed").
Machine: Darwin 25.5.0 (arm64). Toolchain `leanprover/lean4:v4.33.0-rc1`. Base commit `7acd42c`.

## What shipped

| File | What it is |
| --- | --- |
| `LeanFmt/LanguageServer.lean` | the server: 694 lines, namespace `LeanFmt.Internal.LanguageServer`, one public-facing entry `serveLanguageServer` |
| `LeanFmt/Cli.lean` | `lsp` subcommand: `parseLspArgs`, the dispatch branch, usage text, known-command list |
| `LeanFmt/Application.lean` | `ExactRun` gained an optional cancellation token, threaded into the existing 50 ms child poll |
| `LeanFmt/Project.lean` | `unsavedTarget` gained `spelling?`, so a gate error names the caller's own argument |
| `lakefile.lean` | `LeanFmt.LanguageServer` globbed into `lean_lib LeanFmtApplication` |
| `LeanFmtTest.lean` | `testLanguageServerDocuments` (the differential splice test) and `testLanguageServerFrames` |
| `tests/lsp/run.sh` | 39 checks over a live server driven by a Python3 LSP client |
| `tests/boundary/run.sh` | two new rules: the server's import floor, and the `Lean.Server` ban scoped to this module |

## Commands run

```
$ LEAN_NUM_THREADS=1 lake build
Build completed successfully (54 jobs).

$ lake exe lean-fmt-tests
lean-fmt module-artifact tests passed

$ bash tests/lsp/run.sh
Build completed successfully (52 jobs).
ok   a clean session exits zero
... (39 `ok` lines)
lean-fmt language server transport and document lifecycle passed

$ for s in tests/*/run.sh; do bash "$s"; done
(all 21 suites pass; see "Checks read")

$ python3 experiments/check-quoted-figures.py
quoted figures agree with .../evidence/01-projection-shape.txt (43 checked)

$ git diff --check
(no output)
```

## Measurements

| Measurement | Value |
| --- | --- |
| `LeanFmt/LanguageServer.lean` | 694 lines |
| `tests/lsp/run.sh` | 283 lines, **39** checks |
| Bounds enforced | message 32 MiB, document 16 MiB, open documents 256, queued messages 64 |
| Differential splice test | 6 documents × 9 change sequences, incremental vs. independent naive splice |
| Its corpus effect on `ruff-03` | +50 declarations, all structurally claimable; printer `canonical=55` = probe `55` |

## Decisions changed during execution

1. **`notes/01-protocol.md` §2, framing — amended.** The freeze said the toolchain's framing was
   reusable whole. It is not: `readLspMessage` collapses EOF, a bad header, and a bad body into one
   `String`, and `readJson`/`readUTF8` do a single `h.read n` — which under-reads a body split across
   reads. The **write** half is Lean's and is used as-is; the read half is ours (`readExactly`,
   `readFrame`, `Frame`). The note now says which half and why.

2. **`notes/01-protocol.md` §2, decision 1 — corrected as source-false.** The freeze justified keeping
   `Lean.Server.*` out of production by claiming it drags in `Lean.Server.InfoUtils`. `LeanFmt/Analysis.lean:6`
   already imports `Lean.Server.InfoUtils`, legitimately — the info-tree walk is what the semantic
   occurrence fold needs — so the stated reason was false about this repository. The real, measured
   reason replaced it: `Lean.Server.Utils`'s `applyDocumentChange`/`replaceLspRange` convert client
   positions **without clamping**, and an unclamped LSP position resolves past the end of the buffer
   (`evidence/01-position-probe.txt`: `(0,9999)` in a 43-byte document → byte 10003). The boundary rule
   in `tests/boundary/run.sh` was narrowed from a blanket ban to `LeanFmt/LanguageServer.lean` and
   carries that rationale.

3. **`Project.unsavedTarget` widened with `spelling?`.** Refusals named the decoded filesystem path,
   not the URI the client sent, which violates the standing rule that a path error names the caller's
   own argument. `unsavedTarget` now takes an optional spelling used in all three gate messages; every
   existing caller is unchanged, and `tests/lsp/run.sh` pins it ("every refusal names the URI the
   client sent").

4. **Cancellation reuses the existing child poll rather than adding a supervision path.** `monitorChild`
   already polls `child.tryWait` every 50 ms for the memory bound; it now also takes
   `(cancel? : Option Std.CancellationToken)` and checks it there, through a factored-out `abandon`.
   `runBounded`, `ExactRun.envelope`, and `ExactRun.analyzeSnapshot` thread the token with a `none`
   default, so no existing caller changed.

5. **`lastLine = positions.size - 2`, not `- 1`.** `FileMap.positions` is line starts *plus* a final
   end-of-string entry, repeated when the document ends in `\n`, so `size - 1` addresses a line that
   does not exist. Found by the frame/clamp tests, and now the single definition `lineBytes` and
   `clampPosition` both use.

6. **The frame reader drains a bad header block.** First implementation returned at the malformed
   field; the following blank line then read as EOF, silently ending the session and losing the
   client's next request. `readFrame`'s header loop now carries `(length?, error?, seen)` and consumes
   the whole block, and a header with no `Content-Length` is reported as *malformed*, not *closed*.
   Found by the smoke test, not by review.

## Freeze obligations discharged

- **Obligation 1 (clamp every inbound position).** `clampPosition` clamps line and character against
  `lastLine`/`lineBytes`; `applyChange` clamps both endpoints and takes `max start stop`.
- **Obligation 2 (incremental sync is not corruption).** `testLanguageServerDocuments` applies each
  change sequence twice — once through `applyChanges`, once through an independently written naive
  splice over a plain `String` — and requires byte identity. 6 documents × 9 sequences.
- **Obligation 3 (cancellation reaches the child).** Decision 4 above; the token is checked in the
  same 50 ms poll as the memory bound.
- **Obligation 4 (`force-exclude` admission).** `admit`'s third clause runs `Discovery.explain` and
  refuses anything whose gate is not `Discovery.Gate.selected`.

## Checks read

- `lake build` (54 jobs), `lake exe lean-fmt-tests`: pass.
- All 21 suites pass: boundary, cache, catalog, check, compiler, discovery, downstream, imports,
  layout, lossless, **lsp**, modes, printer, reporting, scale, semantic, service, stream, suppression,
  syntax, watch.
- `tests/watch/run.sh` failed once mid-run on "an empty staged selection succeeds". Not a defect in
  this change: that assertion runs `check --staged` against the *real* repository at `$repo_root`, so
  it fails whenever anything is staged — and `LeanFmt/LanguageServer.lean` had to be staged before
  `experiments/run-projection-shape.sh` (which selects its corpus with `git ls-files`) could see it.
  It passes with a clean index. The coupling is the suite's, and predates this prompt.
- `git diff --check`: no output.

## Collateral: the `ruff-03` corpus gate

This repository is the printer's own corpus, so adding a production module moved every figure
`experiments/check-quoted-figures.py` gates. Re-running `run-projection-shape.sh` and updating the
prose surfaced a second, older problem, recorded in `ruff-03`'s
`evidence/01-coverage-agreement.txt` and `state/current.md`: the claim that the Python probe and the
Lean printer "agree exactly" on coverage was true of the totals and false of the parts. The probe's
formula omits `section` (2 in this corpus, both laid out) and the printer refuses one shell in
`Imports.lean` at a runtime guard; at the old corpus size those were +2 −2 and cancelled. They are now
+2 −1, so probe 917 against printer 918. The per-module comparison is the check that can see this, and
the gate now reads the printer's own figure from the new evidence file and fails if the two evidence
files are regenerated apart.

## Remaining uncertainty

- **No feature answers a formatting request yet.** `serverCapabilities` advertises
  `documentFormattingProvider`, `documentRangeFormattingProvider`, and three code-action kinds;
  `RLP-FEATURES` implements them. A client that calls them today gets MethodNotFound. This is the
  intended split, but it means the advertised capability set is ahead of the implementation for one
  prompt.
- **The bounds are asserted, not tuned.** 32 MiB / 16 MiB / 256 / 64 are enforced and tested at the
  refusal boundary. Nothing measures what a real editor session needs; `RLP-FINAL` should either
  measure or say it did not.
- **Cancellation is tested at the protocol level, not at the child.** `tests/lsp/run.sh` proves a
  cancelled request is answered `RequestCancelled` exactly once. That the token actually shortens a
  running exact child is unexercised, because no request currently starts one — `RLP-FEATURES` is the
  first prompt that can test it.
- **Coexistence with Lean's own server is reasoned, not run.** `evidence/01-lsp-baseline.md` shows no
  capability contention in the toolchain source. No editor has been configured with both servers.
