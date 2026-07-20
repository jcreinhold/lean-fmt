# LSP baseline — what exists before `ruff-17`

Owner: `ruff-17-lsp` prompt `01-protocol` (claim `RLP-PROTOCOL`).
Machine: Darwin 25.5.0 (arm64). Toolchain: `leanprover/lean4:v4.33.0-rc1` (`lean-toolchain`).
Commit: `7acd42c`. Build: `lake build` → "Build completed successfully (52 jobs)" (fully warm).

Everything below is a command and its output, not a recollection.

---

## 1. There is no LSP surface today

```
$ ./.lake/build/bin/lean-fmt lsp
usage: lean-fmt {check|format|diff|fix} [OPTIONS] [FILE...]
lean-fmt {check|format|diff|fix} - --stdin-filename PATH [--range S:E]
lean-fmt serve [--root PATH] [--config PATH] [--select SELECTOR]
...
exit=2
```

`lsp` is not in the dispatch list (`Cli.lean:1355`), which admits exactly
`check format diff fix organize serve rules explain docs clean compiler config`. No `Content-Length`
framing, no `initialize`, no `textDocument/*` handler, and no LSP DTO exists in `LeanFmt/`:

```
$ grep -rn "Lsp\|LSP\|Content-Length" LeanFmt/*.lean
LeanFmt/Application.lean:1611:/-- The opt-in "organize imports" capability the roadmap owes CLI and LSP, ...
LeanFmt/Imports.lean:293:LSP "organize imports" capability calls; it exposes no graph internals, ...
```

Two hits, both docstrings, no declarations. They are also a standing promise this stack collects:
`Application.organize` was built as the operation an LSP `source.organizeImports` action would call.

## 2. What the editor-facing surface is today

`LeanFmt/Service.lean` (189 lines) — `lean-fmt serve`, schema `lean-fmt.service.v1`:

| Fact | Where |
| --- | --- |
| Framing is one JSON object per `\n`-terminated line | `Service.lean:143, 92` |
| Three methods: `health`, `analyze`, `shutdown` | `Service.lean:27-31, 39-48` |
| Capacity one, strictly sequential | `loop`, `Service.lean:141-163` |
| Retains project + plan + per-path latest version only | `Service.lean:95-98, 165-167` |
| Versions must strictly increase; equal is rejected | `versionAccepted`, `Service.lean:50-51` |
| One `Project.load` per session, `ExactRun` per request | `Service.lean:183, 186` |
| Analysis only — no formatting, no fixes, no edits | `handleRequest`, `Service.lean:100-139` |
| Bounds: 32 MiB request line, 16 MiB source | `Service.lean:13-15` |
| Error codes are strings, not integers | `failure`, `Service.lean:61-68` |

So the product already has a long-lived, capacity-one, project-holding editor server that answers from
`Application.ExactRun`. What it does not have is the protocol every editor actually speaks, and any
operation that produces text.

## 3. What the toolchain already ships

`~/.elan/toolchains/leanprover--lean4---v4.33.0-rc1/src/lean/Lean/Data/Lsp/`:

```
Basic BasicAux CancelParams Capabilities Client Communication Diagnostics Extra
InitShutdown Internal Ipc LanguageFeatures TextSync Utf16 Window Workspace
```

Present and directly reusable:

- **Framing.** `Lean.IO.FS.Stream.readLspMessage` / `writeLspMessage` — `Content-Length` header parse
  and emit, including the atomic-`putStr` note (`Communication.lean:110-121`).
- **Message algebra.** `Lean.JsonRpc.Message`, `Request`, `Notification`, `Response`, `ResponseError`.
- **UTF-16 conversion.** `Lean.Data.Lsp.Utf16`: `FileMap.lspPosToUtf8Pos`, `utf8PosToLspPos`,
  `lspRangeToUtf8Range`, `String.utf16Length`.
- **DTOs.** `TextDocumentSyncOptions`, `TextDocumentContentChangeEvent`, `Did{Open,Change,Close}…`,
  `Diagnostic`, `PublishDiagnosticsParams`, `TextEdit`, `WorkspaceEdit`, `CodeAction`,
  `CodeActionParams`, `InitializeParams`, `CancelParams`.
- **URI conversion.** `System.Uri.fileUriToPath?` / `pathToUri` (`Init/System/Uri.lean:104, 124`).
- **A driving client.** `Lean.Data.Lsp.Ipc` — spawn a server, write requests, read responses.

Absent, and therefore lean-fmt's to define:

```
$ grep -c "ormattingProvider" .../Lean/Data/Lsp/Capabilities.lean
0
$ grep -c "executeCommandProvider" .../Lean/Data/Lsp/Capabilities.lean
0
$ grep -rln "documentFormattingProvider\|textDocument/formatting" .../Lean/
(no matches)
$ grep -rn "FormattingParams\|FormattingOptions" .../Lean/Data/Lsp/
(no matches)
```

`Lean.Lsp.ServerCapabilities` (`Capabilities.lean:120-141`) has 18 fields and none of them is a
formatting provider; there is no `DocumentFormattingParams`, no `FormattingOptions`, and no
`executeCommandProvider` anywhere in the toolchain.

## 4. Lean's own language server advertises no formatting

`Lean/Server/Watchdog.lean:1567-1607` sets `completionProvider?`, `hoverProvider`, `declarationProvider`,
`definitionProvider`, `typeDefinitionProvider`, `referencesProvider`, `callHierarchyProvider`,
`renameProvider?`, `workspaceSymbolProvider`, `documentHighlightProvider`, `documentSymbolProvider`,
`foldingRangeProvider`, `semanticTokensProvider?`, `codeActionProvider?`, `inlayHintProvider?`,
`signatureHelpProvider?`, `colorProvider?`, and the Lean-specific `moduleHierarchyProvider?` /
`rpcProvider?`. The grep in §3 shows the formatting methods are not implemented anywhere in
`Lean/Server/`, so there is no capability to contend for.

## 5. Position conversion, measured

`evidence/01-position-probe.lean` → `evidence/01-position-probe.txt`, run as

```
lake env lean --run docs/projects/ruff-17-lsp/evidence/01-position-probe.lean
```

The five results the freeze depends on:

| # | Input | Output | Reading |
| --- | --- | --- | --- |
| 1 | `𝔘` in `theorem t : 𝔘 = 𝔘 := rfl` | bytes 43, UTF-16 39, codepoints 37 | all three encodings differ on one ordinary line |
| 2 | byte 20 (interior to a codepoint) | LSP `(0,39)` | a non-boundary offset yields a silently wrong column |
| 3 | LSP `(0,9999)` in a 43-byte document | byte offset `10003` | out-of-range positions are **not** clamped; they overrun |
| 4 | LSP `(0,10)`, interior to a surrogate pair | byte 13 | a split pair snaps *forward* past the whole codepoint |
| 5 | LSP `(1,0)` on CRLF vs its LF twin | byte 12 vs byte 11 | line starts diverge by one per preceding CRLF |

None of 2–4 raises an error. `FileMap` is a conversion, not a validator.
