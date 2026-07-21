# 04-acceptance — RLP-FINAL

Claim: **RLP-FINAL** — protocol, editor, and resource acceptance.
Status: **verified**.
Design: `notes/01-protocol.md` §15, obligations 8–10. Evidence: `tests/lsp/Acceptance.lean`.
Machine: Darwin 25.5.0 (arm64), 10 cores. Toolchain `leanprover/lean4:v4.33.0-rc1`. Base commit
`eef1c39`.

## What shipped

| File | What it is |
| --- | --- |
| `tests/lsp/Acceptance.lean` | 41 acceptance checks driven by `Lean.Data.Lsp.Ipc` — a client we did not write |
| `tests/lsp/acceptance.sh` | builds the binary and runs the harness |
| `LeanFmt/LanguageServer.lean` | in-flight cancellation: `Session.inFlight`, `cancelInFlight`, `serveCancellable` |
| `docs/editor-setup.md` | VS Code, Neovim, Emacs inputs, and the two behaviors users report as bugs |
| `README.md` | an `lsp` section, and `serve`'s removal plan |

## Commands run

```
$ LEAN_NUM_THREADS=1 lake build
Build completed successfully (54 jobs).

$ lake exe lean-fmt-tests
lean-fmt module-artifact tests passed

$ bash tests/lsp/run.sh
lean-fmt language server transport, documents, and features passed          # 75 checks

$ bash tests/lsp/acceptance.sh
lean-fmt language server acceptance passed                                  # 41 checks, 90 s

$ for s in tests/*/run.sh; do bash "$s"; done
(20 pass; tests/printer/run.sh fails the corpus staleness gate — see "Collateral")

$ bash experiments/run-projection-shape.sh \
    docs/projects/ruff-03-language-formatting/evidence/01-projection-shape.txt
$ bash tests/printer/run.sh
failures=0

$ python3 experiments/check-quoted-figures.py
quoted figures agree with .../evidence/01-projection-shape.txt (43 checked)
$ git diff --check
```

## Measurements

| Measurement | Value |
| --- | --- |
| Acceptance checks | 41, across 8 server sessions |
| Wall time | 90 s |
| Formatting `LeanFmt/Application.lean` (1,700 lines) uncancelled | 3,637 ms |
| The same request, cancelled at 400 ms | 470 ms |
| Session subtree RSS after request 1 of 100 | 682,880 KiB |
| Peak across the hundred | 690,640 KiB |
| After request 100 | 685,840 KiB (+0.4% over the first) |

The RSS figures are the sum over the server process and every descendant, sampled from `ps` after each
response. The exact frontend child is the server's child, not the harness's, so a single-process
reading would have missed the thing §13 actually bounds.

Workload: formatter-cache cold, ordinary-project-built, unsaved-buffer requests. No persistent cache
is reachable from this surface, so there is no warm variant of it. No swap growth and no memory
pressure were observed; the run never approached the 8 GiB envelope.

## Decisions changed during execution

1. **In-flight cancellation had to be built, not merely tested.** The prompt asks for a concurrent
   cancellation *case*, and the case could not be written because the behavior was not there.
   `RLP-DOCUMENTS` did its half — `ExactRun`'s child poll takes a `CancellationToken` and kills the
   child on it — but nothing in the server ever created one. `$/cancelRequest` only removed *queued*
   requests. So `Session` gained an `inFlight` slot holding the running request's id and token, the
   reader reaches into it, and `serveCancellable` brackets every request that can start a child.

   The ordering is the part worth writing down. The reader records the id in `cancelled` and *then*
   reads the in-flight slot; `serveCancellable` installs the slot and *then* re-reads `cancelled`.
   Whichever runs first, the other observes its write, so a cancellation arriving in the window
   between the worker's admission check and the child spawning is not lost. Install-then-check, not
   check-then-install: the reverse loses exactly that message.

2. **The toolchain's own JSON-RPC decoder rejects the response the specification requires.**
   JSON-RPC 2.0 §5 says a parse-error response must carry `"id": null`, and `notes` §11 adopted that.
   `Lean.JsonRpc.RequestID`'s decoder accepts only a number or a string, so `Ipc.readMessage` *throws*
   on our spec-conforming parse-error response: "a request id needs to be a number or a string". The
   server was not changed. The specification is explicit, `vscode-languageclient` and `lsp-mode` both
   accept it, and a null id is the only honest answer when no id could be recovered. The harness reads
   that one frame at the JSON level instead, and says why in a comment at the reader. This is the
   clearest thing the independent client bought: our own Python harness models our own choices, and
   would never have noticed.

3. **The first cancellation measurement was very nearly a false one.** It reported "uncancelled
   3,714 ms, cancelled 3,501 ms" — a cancellation that did nothing — and the response code was still
   `RequestCancelled`, so a check that only asserted the code would have passed. The cause: `didOpen`
   schedules a debounced analysis of the same slow module, that analysis rides the same FIFO, and the
   request being "cancelled" was still queued behind it. It was answered by the *dispatch-time*
   cancellation check, having never run. The harness now waits for the published diagnostics before
   timing anything, and the pair became 3,637 ms / 470 ms. The check compares the two numbers and
   prints them, because the code alone cannot tell a cancelled child from a cancelled queue entry.

4. **`serve` gets a removal plan, not a removal.** The Stop rule permits it as a private compatibility
   adapter with a plan. The plan is in `README.md` and is gated on two things that have not happened:
   a real editor session against `lsp`, and one release shipped carrying the notice. It is frozen
   rather than starved — no new capability is being back-ported to it — and it keeps its suite.

## Freeze clauses discharged

- **§15.8 — drive the server with `Lean.Data.Lsp.Ipc`.** Done. `tests/lsp/Acceptance.lean` writes with
  `Ipc.writeRequest`/`writeNotification`, reads with `Ipc.readMessage`, shuts down with `Ipc.shutdown`,
  and decodes our code actions with `Lean.Lsp.CodeAction`'s own `FromJson`. Nothing in it is shared
  with `LeanFmt.LanguageServer`. One deliberate exception, documented above and at its definition.
- **§15.9 — the five acceptance cases.** Malformed-message recovery (§11): unparseable body, a message
  with no method, an unknown method, an unknown notification, each followed by a real request the
  session must still answer. Concurrent cancellation (§9): measured above. Unicode positions (§4): an
  end position that is 12 UTF-16 units where it would be 10 codepoints and 16 bytes, a position
  splitting a surrogate pair, a position past the end of its line, and the same assertions after a
  `didChange`. Dynamic reconfiguration (§10): a config file rewritten under a live session, with
  `didChangeConfiguration` turning a reported `FMT005` into a silent one without reopening the
  document. Memory stability (§13): measured above.
- **§15.10 — editor setup inputs.** `docs/editor-setup.md`, with the widened-range and
  trailing-comment behaviors named as the two things a user will otherwise file as bugs, the
  multi-server formatting choice of §12, and the "no file watcher, use your client's configuration
  change" clause of §10.

## Collateral: the corpus moved, and this time a suite said so first

Extending `LeanFmt/LanguageServer.lean` moved every figure `experiments/check-quoted-figures.py`
gates. `results/03-features.md` predicted this and predicted the danger — a blanket substitution
reaches further than the gate can see, and last time corrupted a source citation in `Printer.lean`.

Two things went better this round. First, `tests/printer/run.sh` **failed before the figure gate
passed**: it compares the evidence file's command count against the live corpus and reported "the
shape evidence is stale: it reports 1042 commands, the live corpus has 1044". The figure gate, which
only compares prose against evidence, was still green — both were internally consistent and both were
describing a corpus that no longer existed. The staleness gate is the one that noticed.

Second, the prose was updated **through the gate's own regexes** rather than by search-and-replace:
the checker's failure output names the file, the pattern, and the expected value, so each figure was
replaced inside the sentence that quotes it, and any pattern matching more or fewer than once was
skipped rather than guessed at. 27 figures across four files, no collateral in the diff.

Numbers after: probe 936, printer 937, still differing by one, and the per-module comparison confirms
the same three modules and the same two opposite causes. `LeanFmt/LanguageServer.lean` was re-checked
at its new size and still agrees exactly (71 = 71).

## Remaining uncertainty

- **The editor configurations are unrun.** They are derived from each client's documented schema —
  `vim.lsp.config`, `lsp-register-client`, a generic VS Code LSP client — not from a session anyone
  opened. Everything the protocol side of them depends on is asserted by the harness; the mapping from
  those inputs to a working editor is not. `serve`'s removal is gated on closing exactly this gap, so
  it is tracked rather than merely admitted.
- **RSS is sampled, not integrated.** `ps` after each response sees the aggregate at that instant. A
  transient peak between two samples is invisible. `monitorChild`'s own 50 ms poll is the enforcement
  mechanism and it is not sampling-based, so the envelope is not what this measurement protects — this
  measures the *session's* growth, which is what §13 promises.
- **The hundred requests alternate two shapes.** Formatting and code actions, on one small document.
  A session that leaked per *document* rather than per request would not show up; the document store's
  bound is asserted in `tests/lsp/run.sh` instead, and separately.
- **`ContentModified` (-32801) is still unreachable**, for the reason `results/03-features.md` gives:
  no request this server implements carries a client-stated version. Unchanged here.
- **A cancellation for an id that is never served is never forgotten.** *(Owned by
  `ruff-19-performance`, recorded in its `state/current.md`.)* `serveCancellable` erases the
  id after every request it brackets, which covers every id the server actually sees. A client that
  cancels ids it never sent — or that cancels a notification — leaves an entry in the `cancelled` set
  for the life of the session. It is a few dozen bytes per stray message and no client does it, but it
  is the one thing in §13's "bounded" list that this stack did not put a bound on.
- **The debounce default is still untuned.** 150 ms remains a number nobody measured against real
  editing.
