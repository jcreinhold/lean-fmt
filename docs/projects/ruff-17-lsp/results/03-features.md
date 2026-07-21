# 03-features — RLP-FEATURES

Claim: **RLP-FEATURES** — diagnostics, formatting, and code actions over the document store.
Status: **verified**.
Design: `notes/01-protocol.md` §7–§10. Evidence: `tests/lsp/run.sh` (the feature half).
Machine: Darwin 25.5.0 (arm64). Toolchain `leanprover/lean4:v4.33.0-rc1`. Base commit `6514bc2`.

## What shipped

| File | What it is |
| --- | --- |
| `LeanFmt/Application.lean` | `ExactRun.streamSnapshot` (the exact half of `stream`, against a held run), `ExactRun.organizeSnapshot` (organize, validated, not written), `admittedFix?` (the one fix-admission rule) |
| `LeanFmt/LanguageServer.lean` | diagnostics with debounce, `textDocument/formatting`, `textDocument/rangeFormatting`, `textDocument/codeAction`, `initializationOptions`, reconfiguration re-analysis |
| `LeanFmt/Cli.lean` | `--debounce-ms` |
| `tests/lsp/run.sh` | a live `Client` (writes, reads, waits) and 36 feature checks |

## Commands run

```
$ LEAN_NUM_THREADS=1 lake build
Build completed successfully (54 jobs).

$ lake exe lean-fmt-tests
lean-fmt module-artifact tests passed

$ bash tests/lsp/run.sh
lean-fmt language server transport, documents, and features passed

$ for s in tests/*/run.sh; do bash "$s"; done
(all 21 suites pass)

$ bash experiments/run-projection-shape.sh          # the corpus moved again; see "Collateral"
$ python3 experiments/check-quoted-figures.py
quoted figures agree with .../evidence/01-projection-shape.txt (43 checked)

$ git diff --check
(no output)
```

## Measurements

| Measurement | Value |
| --- | --- |
| `tests/lsp/run.sh` | 75 checks (39 lifecycle + 36 feature) |
| Feature checks over a live client | diagnostics, formatting, range formatting, code actions, `only` filtering, applicability, `initializationOptions`, superseded analyses |
| Default quiet interval | 150 ms (`--debounce-ms`, `initializationOptions.debounceMs`) |
| Corpus effect on `ruff-03` | printer 918 → 935, probe 917 → 934 |

## Decisions changed during execution

1. **`stream` split rather than called.** `Application.stream` resolves a root, a discovery, a Lake
   workspace, and an `ExactRun` on every invocation. That is right for a pipe and wrong for a session:
   an editor would pay `Project.loadWorkspaceOnly` per keystroke. `ExactRun.streamSnapshot` is
   everything below the resolution and `stream` is now the resolving wrapper, so the LSP surface enters
   the *same* operation `--stdin` enters rather than a parallel one. `serveLanguageServer` brackets the
   whole session in one `withExactRun`, as `Service.serve` does — each analysis still gets a fresh
   bounded child.

2. **`admittedFix?` extracted, because two callers had to agree.** Fix admission is two conditions —
   the rule is *fix*-selected, and the applicability is admitted under `--unsafe-fixes` — and it was
   inline in `prepareFile`. The code-action path needs the identical predicate, and an editor offering
   a quickfix `lean-fmt fix` would refuse is the same defect as an editor reporting a finding the
   command line does not. `prepareFile` now calls it too, so there is one rule rather than two that
   currently agree.

3. **`organizeSnapshot` validates even though it does not write.** The batch `organize` validates by
   re-elaboration before publishing. The LSP action hands bytes to the client instead, which is not a
   reason to skip validation: the reorder is observable to elaboration, which is why it is opt-in at
   all. Same candidate (`Imports.parseHeaderModel` + `Imports.organize`), same verdict
   (`analyzeSnapshot (validator := true)`), different last step.

4. **A ranged format could not serve `output` as its replacement — the test caught it.** `stream`'s
   ranged output is the **whole** document with the selected units reformatted in place, because a
   shell redirect must write a complete file. Serving that as the replacement for the *actual* range
   duplicates the file. The range was right and the text was right; only the pair was wrong, and only
   an assertion that applied the edit could see it. The fix consumes the `sourceMap` the answer already
   carries — `sliceRange` re-bases each mark onto the spliced text, so the marks' hull is exactly the
   body that replaced the actual range. `tests/lsp/run.sh` now asserts the narrow edit and the
   whole-document edit produce the same bytes.

5. **Settings split from startup options.** `root` and `maxMemoryGiB` are fixed when the session opens
   — one Lake workspace, one aggregate envelope — and a client that asks to move either is told to
   restart rather than quietly half-served. Everything else (`select`, `ignore`, `preview`,
   `unsafeFixes`, `debounceMs`, `configPath`) lives in a ref that `initializationOptions` may write and
   every request re-reads, so a setting is never captured into a closure that outlives it.

6. **Analyses are memoized per document *version*, not cached.** An editor asks for code actions on
   cursor movement, and each ask would otherwise be one exact frontend run over unchanged bytes. The
   memo is read only for the version it names; a `didChange` gives a new version, which never matches a
   stored one; `didChangeConfiguration` drops the map wholesale, because a memo whose key does not
   mention the configuration cannot be checked against a new one.

7. **The debounced analysis rides the message queue.** `didOpen`/`didChange` schedule a `Work.analyze`
   after the quiet interval; the worker drops it if the document has moved past that version. Analysis
   and message handling are therefore the one FIFO the freeze specifies — never two things touching a
   document at once — and a superseded analysis is dropped by the component whose ordering is
   authoritative about what "current" means.

## Freeze clauses discharged

- **§7 diagnostics.** Push, `source = "lean-fmt"`, `code` the rule code, `codeDescription` at
  `docs/rules/<code>.md`, severity Warning, analysis failure logged rather than published, `didClose`
  clears. All asserted.
- **§8 capabilities.** Formatting, range formatting (reporting the reflow-expanded actual range and
  serving the source map), and the three code-action kinds, each backed by the operation the freeze
  named. No `executeCommandProvider`: every action carries its own `WorkspaceEdit` in `documentChanges`
  form, naming the version it was computed against.
- **§9 debounce.** Implemented as above; superseded analyses dropped.
- **§10 dynamic configuration.** `initializationOptions` read; `workspace/didChangeConfiguration`
  re-runs discovery, drops the memos, and re-analyzes every surviving document — which is the
  roadmap's requirement that a `line-width` change re-formats affected open documents rather than
  serving output rendered at the old margin.

## Collateral: the corpus moved again

Editing three production modules moved every figure `check-quoted-figures.py` gates (probe 934,
printer 935). Regenerating both evidence files and updating the prose was mechanical — but doing it
with a blanket substitution corrupted a *source citation* in `Printer.lean`
(`Lean/Parser/Command.lean:852-853` became `869-853`) and one historical percentage in `ruff-03`'s
`state/current.md`, neither of which the gate looks at. Both were caught by reading the diff and
reverted. The lesson is worth writing down because it will recur every time this stack adds a module:
the gate covers the figures it names, and a global search-and-replace reaches further than the gate
can see. Replace by sentence, then read the diff.

## Remaining uncertainty

- **`ContentModified` (-32801) is unreachable on the current request set.** The freeze assigns it to
  "stale version". No request this server implements carries a client-stated version:
  `DocumentFormattingParams` and `CodeActionParams` both take a bare `TextDocumentIdentifier`, and the
  worker is capacity-one FIFO, so a document cannot move under a request in flight. Staleness is
  handled where the protocol actually puts it — the `WorkspaceEdit`'s stated version, which the client
  enforces. The code is not emitted, and manufacturing a use for it would be worse than saying so.
- **Debounce is asserted, not tuned.** 150 ms is a default nobody measured. The suite runs at 1 ms and
  80 ms to make the timing deterministic; neither is evidence about editing.
- **Cancellation still is not observed at the child.** `RLP-DOCUMENTS` left this open because no
  request started an exact child. Requests do now, but the suite proves only that a cancelled request
  is answered `RequestCancelled` exactly once — not that the token shortened a running frontend. That
  needs a request slow enough to cancel mid-flight, which is `RLP-FINAL`'s concurrent-cancellation
  case.
- **No editor has run this.** Every check drives the protocol directly. VS Code, Neovim, and Emacs
  setup inputs are `RLP-FINAL`'s.
- **Code actions cost one exact run per requested source kind.** `quickfix` reuses the memo;
  `source.fixAll` and `source.organizeImports` each run. A client that sends no `only` and asks on
  every cursor movement pays for both. `only` filtering is implemented and honored, and the mainstream
  clients send it, but nothing here bounds a client that does not.
