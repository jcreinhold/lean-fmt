# LSP capability and state model — the RLP-PROTOCOL freeze

Owner: `ruff-17-lsp` prompt `01-protocol` (claim `RLP-PROTOCOL`).
Baseline and measurements: `evidence/01-lsp-baseline.md`, `evidence/01-position-probe.{lean,txt}`.
Live code re-read for this freeze: `LeanFmt/Service.lean`, `LeanFmt/Application.lean`,
`LeanFmt/Project.lean`, `LeanFmt/Discovery.lean`, `LeanFmt/Cli.lean`, `LeanFmt/LosslessSource.lean`,
and the toolchain's `Lean/Data/Lsp/`, `Lean/Server/Utils.lean`, `Lean/Server/Watchdog.lean`,
`Init/System/Uri.lean` at `v4.33.0-rc1`.

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC,
`ruff-14` RSF-SPEC), this prompt ships **no production Lean interface, config key, or CLI surface.**
It ships this freeze, the characterization test that pins its central claim (`LeanFmtTest.lean`,
`testLspPositions`), and the probe behind it.

---

## 1. The one-sentence shape

`lean-fmt lsp` is a long-lived, capacity-one server that holds one Lake workspace and one discovery
for its lifetime, keeps every open document as normalized text with a version, converts LSP UTF-16
positions through exactly one layer, and answers every request by the operations `ruff-14` already
built — `Application.stream`, `sliceRange`, `Printer.formatWithMap`, `Project.unsavedTarget` — running
in a fresh bounded child. It publishes diagnostics under its own source name, offers the formatting
capabilities Lean's own server does not, and never writes a file.

## 2. Reuse: what comes from the toolchain and what is ours

The toolchain ships the protocol plumbing (`evidence/01-lsp-baseline.md` §3). The freeze takes it:

- **Framing** is `Lean.IO.FS.Stream.readLspMessage` / `writeLspMessage`. We do not write a second
  `Content-Length` parser. Its atomic-`putStr` property (`Communication.lean:110-121`) is the reason a
  notification emitted from a background context cannot interleave with a response.
- **Message algebra** is `Lean.JsonRpc`.
- **Position conversion** is `Lean.Data.Lsp.Utf16` over `Lean.FileMap`. §4.
- **DTOs** are `Lean.Lsp`'s wherever `Lean.Lsp` has them.
- **URI conversion** is `System.Uri.fileUriToPath?` / `pathToUri`.

Three deliberate exceptions:

1. **`Lean.Server.*` is not imported into production.** `Lean.Server.Utils` — where
   `applyDocumentChange` lives — transitively imports `Lean.Server.InfoUtils`, which is the elaborator's
   info-tree machinery. `replaceLspRange` is fifteen lines (`Server/Utils.lean:111-126`) and
   RLP-DOCUMENTS reimplements it over our own document record rather than dragging the language
   server's internals into a formatter. `Lean.Data.Lsp.Ipc` is different: it is data-side, and it is the
   acceptance harness RLP-FINAL drives the server with.
2. **Formatting capabilities are ours to define.** `Lean.Lsp.ServerCapabilities` has eighteen fields and
   no formatting provider, no `executeCommandProvider`, and there is no `DocumentFormattingParams` or
   `FormattingOptions` in the toolchain at all (`evidence/01-lsp-baseline.md` §3). So `LeanFmt.Lsp`
   declares its own `ServerCapabilities`-shaped response DTO and its own formatting-params DTOs. This is
   the boundary the prompt's stop rule names: those DTOs live in `LeanFmt.Lsp` and nothing below it
   mentions them.
3. **`Lsp.Diagnostic`'s Lean extensions are suppressed, not emitted.** `DiagnosticWith` carries
   `fullRange?`, defaulted to `some range` (`Diagnostics.lean:126`), plus `isSilent?` and `leanTags?`.
   We reuse the type and set all three to `none`. They are Lean-server extensions; a formatter emitting
   them would be claiming to be something it is not, on every diagnostic of every document.

## 3. Process and state model

**One process, one workspace, many requests.** At `initialize` the server resolves the root, runs
`Discovery.run` once, and calls `Project.loadWorkspaceOnly` — *not* `Project.load`.

`serve` takes the other trade (`Project.load root discovery #[]`, `Service.lean:183`) because it wants
`findTarget?` over a pre-selected set. An LSP server does not: the client tells it which documents
exist, one at a time, and a document may be a file that has never been saved. So identity comes from
`Project.unsavedTarget`, which resolves a path with no filesystem read for content
(`Project.lean:169-188`), and startup does not pay for a walk of every source in the tree.

**Per request: one `ExactRun`, one bounded child.** The session holds a single `withExactRun` for its
lifetime (as `serve` does, `Service.lean:186`) and each analysis spawns a fresh child under the
`--max-memory` aggregate envelope. Nothing is retained between requests but the document store and the
resolved configuration.

**`execute` is never called.** Not because of the in-process cache penalty `ruff-16` reported — that
attribution was refuted, and `ruff-16b` `RCI-IMPL` fixed the real (process-independent) defect — but
because `execute` selects, caches, and publishes, and none of the three is meaningful for a buffer that
is not on disk. A persistent cache entry is keyed on a digest bound to a file's disk state, and unsaved
bytes have no disk state to bind (`Application.lean:1508-1509`). This is the clause the roadmap's "no
persistent cache for unsaved buffers" names, and `stream` already enforces it.

One thing carried from `RCI-FINAL`: `ResultCache.open?` returning `none` reports nothing, so a project
running with the cache disabled is indistinguishable from a cold one. This server holds no result
cache at all, so the question does not arise for its request path — but nothing here may be written as
though a warm cache is what makes it fast. What makes a request fast is that the frontend runs once
over one buffer.

## 4. Position conversion — one layer, and it is not a validator

**The layer is `Lean.FileMap` built over the *normalized* document text**, `raw.crlfToLf`, per
`CLAUDE.md`: every compiler-produced offset and digest indexes normalized source, so the LSP
coordinate system must land in that same space or two different strings get compared. Lean's own
server reaches the same conclusion independently — `replaceLspRange` normalizes inserted text
(`Server/Utils.lean:121`) precisely so its `FileMap` stays normalized.

**`Application.PositionIndex` is not this layer.** Its columns are 1-based *codepoints*, the encoding
`ruff-14` froze for `--range-lines`; LSP wants 0-based UTF-16 code units. `ruff-15`'s astral fixture
separates them: `𝔘` reports column 34 where a byte column is 37 and a UTF-16 column 35
(`tests/reporting/run.sh:383-394`). Reaching for `PositionIndex` here would be wrong on exactly the
inputs nobody tests by hand. It is reusable as a *pattern* — resolve only the offsets the answer names,
in one forward pass — not as an implementation.

**Four measured facts that make validation the server's job, not the converter's**
(`evidence/01-position-probe.txt`):

| Fact | Measurement | Consequence |
| --- | --- | --- |
| Out-of-range positions overrun | LSP `(0,9999)` in a 43-byte document → byte **10003** | every incoming position is clamped against the document *before* conversion; an unclamped offset would slice out of bounds |
| Non-boundary offsets produce garbage columns | byte 20, interior to `𝔘` → LSP `(0,39)` | only offsets on codepoint boundaries are ever converted outward; layout marks and rule findings satisfy this, arithmetic on them may not |
| Split surrogate pairs snap forward | LSP `(0,10)`, interior to `𝔘` → byte 13, past the whole character | accepted and documented; a client cannot address half a character and the forward snap is the safe direction for a range start |
| CRLF and LF line starts diverge | LSP `(1,0)` → byte 12 (CRLF) vs 11 (LF) | the document is normalized on arrival, so this divergence never appears; it is why converting against raw bytes would be off by one per preceding line |

None of the first three raises an error. `FileMap` converts; it does not check. RLP-DOCUMENTS owns a
`clampPosition` that saturates line to the last line and column to that line's UTF-16 length, and every
inbound position goes through it.

**Outbound coordinates.** Diagnostics and `TextEdit` ranges are produced from byte offsets that are
already on codepoint boundaries — rule findings come from the compiler, layout marks from
`Printer.formatWithMap` — so `utf8PosToLspPos` is applied directly. Line counts are invariant under
`crlfToLf`, so a range computed in normalized coordinates names the same lines in the client's buffer.

**Line endings.** The document is stored normalized. Text the server *emits* is denormalized back to
the buffer's own form through `LosslessSource.denormalize`, exactly as `stream` does
(`Application.lean:1592`). A CRLF file gets CRLF edits.

## 5. Document identity and admission

Every served document has a project location. This is the roadmap's completion contract and `ruff-14`'s
frozen verdict: a buffer's *identity*, not its content, resolves its configuration, module name, and
exact Lake setup, and a buffer with no location must be **rejected** rather than served against
built-in defaults, because that would make the editor a second configuration path answering differently
than the same bytes on disk (`ruff-14` `notes/01-stream-range.md` §2).

Admission runs in this order on `didOpen`, and the answer is cached with the document:

1. **Not a `file:` URI → rejected.** `System.Uri.fileUriToPath?` returns `none` for
   `untitled:Untitled-1` (measured, `evidence/01-position-probe.txt`). This is the `untitled:` case
   decided explicitly, as the roadmap requires: an unsaved-and-unnamed buffer has no location, therefore
   no configuration, therefore no answer.
2. **Every gate `Project.unsavedTarget` applies** — inside the root, `.lean` extension, and the `.lake`
   floor, in that order and with those messages (`Project.lean:173-179`). The floor is gate 1 and is not
   liftable by arriving through a protocol any more than through a pipe.
3. **`force-exclude`.** If the document's own effective configuration sets `force-exclude`, the document
   is admitted only when `Discovery.explain relativePath == .selected` (`Discovery.lean:437-448`).

Clause 3 is the one place this freeze goes beyond what `stream` does, and it is deliberate.
`unsavedTarget` does not evaluate `force-exclude`; `Project.load` does, for explicitly named paths
(`Project.lean:221-226`). The stdin surface treats naming a path as an explicit selection, which is
right — a person typed it. An editor opening a file is not that act; editors open whatever the user
clicks, including vendored trees a `force-exclude` project has deliberately removed from the
formatter's reach. If `lean-fmt format path/to/vendored.lean` reports nothing, the editor must report
nothing for the same bytes, or the editor has become the second configuration path the roadmap forbids.
`Discovery.explain` is the existing query for exactly this question — it was built for `config show` on
an arbitrary path — so this costs no new matcher.

**A rejected document is rejected loudly and once.** The server answers `didOpen` with a
`window/showMessage` naming the reason in the caller's own terms (the URI as the client sent it, as
`selected file does not exist: <arg>` names the caller's argument), records the document as
unserviceable, and thereafter answers its requests with `InvalidParams` rather than re-deriving the
rejection. It publishes no diagnostics for it — an empty diagnostic set would read as "clean".

## 6. Text synchronization

**`textDocumentSync`: `openClose = true`, `change = incremental` (kind 2), `save` absent.**

Incremental, not full, and the reason is that the two costs have different shapes. Analysis cost is
per *request* and is collapsed by debounce — many keystrokes produce one analysis. Sync payload is per
*change notification* and collapses not at all. The largest real module in the frozen mathlib sample is
660 KB of artifact over a source that full sync would retransmit on every keystroke. The primitive is
fifteen lines and the toolchain's own server uses it.

The risk this accepts is real: a wrong incremental apply corrupts the buffer silently, and this server's
output is text the client writes back into the user's file. RLP-DOCUMENTS discharges it with a
differential test — apply a change sequence incrementally and by full replacement and assert the two
documents are byte-identical — over sequences that include multi-byte and astral characters, CRLF
documents, and changes at line boundaries.

`willSave`/`willSaveWaitUntil` are not offered. Format-on-save is the client applying
`textDocument/formatting`, not a server hook, and `willSaveWaitUntil` would put a formatter on the
critical path of every save with no way to decline.

**Versions.** Each document carries the client's version. `serve`'s rule — strictly increasing, equal
rejected (`Service.lean:50-51`) — is the *session* rule and stays. A response computed against version
*n* is discarded rather than sent if the document has moved to *n+1* by the time it completes; a
`WorkspaceEdit` carries the version it was computed against so the client can refuse a stale edit.
This is the roadmap's "document versions prevent stale publication".

**Bounds.** Reusing `serve`'s envelope: 32 MiB per message, 16 MiB per document source
(`Service.lean:13-15`), and a bounded open-document count. Exceeding any of them is an error response,
never a truncation.

## 7. Diagnostics ownership

**Push, not pull.** `textDocument/publishDiagnostics` after each analysis. No `diagnosticProvider` is
advertised: pull diagnostics with result IDs would be advertising incremental semantics this server
does not have, which the prompt's stop rule forbids. The server re-analyzes the whole buffer or it
answers nothing.

**Ownership is by `source`.** Every diagnostic sets `source = "lean-fmt"` and `code` to the rule code
(`FMT013`, and the self-diagnostics `FMT900`/`FMT901` from `ruff-07`), with `codeDescription` pointing
at `docs/rules/<code>.md` — the same URL `Cli.lean`'s SARIF `helpUri` already emits. LSP scopes
published diagnostics per server per URI, so nothing here contends with the Lean server's own set; the
client merges them and the `source` field is what tells a user which tool to argue with.

**Severity.** Findings are `Warning`. A formatter finding is not an error: the file compiles, and a
client that treats our diagnostics as errors would gate the user's workflow on layout. Analysis failure
is not a diagnostic at all — it is a `window/logMessage` plus an empty publish, because a broken buffer
mid-keystroke is the normal state of editing and must not paint the file red.

**Clearing.** `didClose` publishes an empty set for the URI, then drops the document.

## 8. Capabilities offered

| Capability | Advertised | Backed by |
| --- | --- | --- |
| `textDocumentSync` | `{openClose, change: 2}` | §6 |
| `documentFormattingProvider` | `true` | `Application.stream` in `.format` mode |
| `documentRangeFormattingProvider` | `true` | `stream` + `Application.sliceRange` |
| `codeActionProvider` | kinds `quickfix`, `source.fixAll`, `source.organizeImports` | `stream` in `.fix` mode; `Application.organize` |
| `executeCommandProvider` | absent | nothing needs a command; every action carries its own `WorkspaceEdit` |
| everything else | absent | not this product |

**Range formatting reports the reflow-expanded actual range**, and the answer carries the `sourceMap`
that `StreamReport` already returns (`Application.lean:1464-1469`). Two inherited facts govern its
documented behavior and neither may be "simplified" away:

- **A range is not cheaper than the whole buffer** (`ruff-14` `evidence/03-stream-cost.txt`). One exact
  frontend run over the whole document is the cost either way. Debounce, cancellation, and capacity
  decisions must not assume a small selection is a small request.
- **Repeated range formatting is a fixed point only in output coordinates.** Formatting changes a
  unit's length, so re-sending the originally *requested* range over the result names a different region
  and can reach into the next command. The server serves the `sourceMap`; clients that re-format send
  back the range the unit now occupies. `ruff-14`'s own suite asserted the convenient version first and
  failed.
- **Comment ownership at a unit boundary is trailing-greedy**: a comment written *above* a declaration
  belongs to the earlier unit, so range-formatting a declaration does not include the comment a user
  would say belongs to it. This is `RLC-SPEC`'s frozen verdict, re-confirmed by `ruff-14` on real
  source. It is user-visible in an editor in a way it is not in a pipeline, so the *documentation*
  explains it (RLP-FINAL's editor-setup material). The behavior does not change here.
- **The forward-extension clause never fires on idiomatic Lean** — 0 of 2,854 layout units on the frozen
  mathlib sample (`ruff-14` `evidence/03-range-unit-census.txt`). The actual range is reported either
  way; do not simplify the expansion rule on the strength of a client never having seen it widen.

**Code actions.** A `quickfix` per admitted safe fix at the cursor's range, one `source.fixAll`, one
`source.organizeImports`. Applicability is exposed, not hidden: an unsafe fix is offered only when the
session was started with unsafe fixes enabled, and a withheld fix produces no action rather than a
disabled one — `CodeActionDisabled` would advertise a fix the product has decided not to apply.
Every action carries a `WorkspaceEdit` computed against a stated document version.

## 9. Cancellation and sequencing

**Capacity one, FIFO, with a bounded queue.** The `Service` model (`Service.lean:141-163`) stays: one
request in flight, the rest queued, the queue bounded and a full queue answered with an error rather
than grown.

`$/cancelRequest` has two effects:

- A **queued** request is removed and answered `RequestCancelled` (-32800) without ever running.
- The **in-flight** request's bounded child is killed and the request answered `RequestCancelled`.

The second needs a handle `ExactRun` does not have today. `monitorChild` polls `child.tryWait` every
50 ms and checks the memory envelope on each poll (`Application.lean:266-289`); it takes no
cancellation input. RLP-DOCUMENTS adds one — a cancel token consulted in that same poll, killing the
child by the path the envelope-exhaustion branch already uses. This bounds cancellation latency at
~50 ms and adds no new process-management code. It is a small owned addition to an existing loop, not a
missing lower layer.

**Debounce.** `didChange` does not schedule an analysis immediately; it marks the document dirty and
schedules one after a quiet interval. A superseded pending analysis is dropped, not queued — publishing
diagnostics for version *n* after version *n+2* has arrived is the stale publication §6 forbids.

## 10. Dynamic configuration

**Initialization options** (`InitializeParams.initializationOptions`), all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `configPath` | none | explicit `lean-fmt.toml`, as `--config` |
| `select` / `ignore` | `[]` | rule selection, as the CLI selectors |
| `preview` | `false` | unlock preview rules, as `--preview` |
| `unsafeFixes` | `false` | offer unsafe fixes as code actions |
| `maxMemoryGiB` | `8` | the aggregate envelope |
| `debounceMs` | (RLP-DOCUMENTS names it) | quiet interval before analysis |

`rootUri`/`rootPath` and `workspaceFolders` resolve the root. **Exactly one root is served.** A
multi-root client gets the first folder and a `window/showMessage` naming the ones it is not serving:
one Lake workspace and one discovery are session state (§3), and pretending otherwise would mean
resolving a second toolchain in one process.

**Reconfiguration.** `workspace/didChangeConfiguration` re-runs `Discovery.run` and re-resolves every
open document's effective configuration and rule plan. Documents whose resolved configuration changed
are re-analyzed and their diagnostics republished. This is the roadmap's requirement that a `line-width`
change re-formats affected open documents rather than serving output rendered at the old margin — the
margin is `FormatConfig.lineWidth` and it is folded into cache identity precisely because it is a
runtime value (`Application.lean:357-377`).

`workspace/didChangeWatchedFiles` over `lean-fmt.toml` is *not* registered here. The client-side
watcher is a second discovery path with its own staleness; `ruff-16-watch-incremental` owns file
observation and this stack does not open a second one. A user who edits the configuration re-triggers
through their client's configuration change, and RLP-FINAL's setup documentation says so.

Reconfiguration does **not** re-resolve the Lake workspace. A `lakefile` change invalidates the exact
setup, and the honest answer is a restart; the server says so in a log message rather than serving
answers from a workspace that no longer describes the project.

## 11. Error codes

JSON-RPC integers, not `serve`'s strings (`Service.lean:61-68`). The string codes are
`lean-fmt.service.v1`'s and stay with it.

| Condition | Code |
| --- | --- |
| unparseable message | `ParseError` (-32700) |
| well-formed JSON that is not a valid request | `InvalidRequest` (-32600) |
| unknown method | `MethodNotFound` (-32601) |
| unknown/rejected document, unresolvable URI, out-of-range parameters that cannot be clamped | `InvalidParams` (-32602) |
| request before `initialize`, or after `shutdown` | `ServerNotInitialized` (-32002) |
| cancelled | `RequestCancelled` (-32800) |
| stale version | `ContentModified` (-32801) |
| analysis failure, envelope exhaustion, child failure | `InternalError` (-32603), message naming the cause |

**Malformed input never terminates the server.** A message that cannot be framed or parsed is answered
(with a null id where none can be recovered) and the loop continues — the behavior `serve` already has
(`Service.lean:146-159`) and which RLP-FINAL tests directly. The exception is a truncated stream:
end-of-input ends the session, as it does today.

`exit` without a preceding `shutdown` exits non-zero, per the specification.

## 12. Coexistence with Lean's language server

Measured, not assumed: **there is no contention.** `Lean.Lsp.ServerCapabilities` has no formatting
provider field at all, and no formatting method is implemented anywhere in `Lean/Server/`
(`evidence/01-lsp-baseline.md` §3–§4). The Lean server offers hover, completion, go-to-definition,
code actions, semantic tokens and the rest; it does not offer formatting. `lean-fmt` offers formatting
and formatting-derived code actions and nothing else.

The three places two servers on one document can still collide, and what this freeze does about them:

1. **Diagnostics.** Scoped per server per URI by the protocol; disambiguated for the user by
   `source = "lean-fmt"` (§7).
2. **Code actions.** Both servers answer `textDocument/codeAction` and the client concatenates. Our
   actions are titled with the rule code they come from, so a menu entry is attributable.
3. **The elaboration itself.** Both processes elaborate the same module. This is a real duplicated cost
   and the freeze does not hide it: the server runs one exact frontend child per analysis, debounced,
   under the aggregate envelope. `ruff-19-performance` owns the measurement.

The server does **not** register a `documentSelector` narrower than `lean` files, and does not attempt
to detect whether a Lean server is running. Editors resolve multi-server formatting by asking the user
to pick a default formatter; that is the client's job and doing it for them from inside the server
would require guessing.

## 13. Resource envelope

Unchanged from `serve` and `stream`, and restated because a long-lived process is where these bite:

- One `withExactRun` per session; a **fresh bounded child per request**, never a reused one.
- `--max-memory` (default 8 GiB) is the aggregate limit, enforced by `monitorChild`'s 50 ms poll.
- Document store bounded in count and per-document bytes (§6).
- Request queue bounded (§9).
- No persistent cache, no result cache, no write path. `publishAtomic` is not reachable from any
  operation this server calls.
- Source bodies and reports are released after each response; only documents, versions, and resolved
  configuration are retained.

RLP-FINAL's 100-request memory stability check is the acceptance form of this section.

## 14. What this freeze does not decide

- The debounce interval's value. RLP-DOCUMENTS measures and names it.
- The bounded document-count and queue-depth constants. Same.
- Whether `didSave` triggers a re-analysis. The document store is authoritative for content either way;
  the open question is whether a save should refresh the *build artifacts* the exact setup reads, which
  is `ruff-16`/`ruff-19` territory.
- Progress reporting (`$/progress`, work-done tokens). Deferred; not in the completion contract.
- Anything about the Lean server's behavior beyond what §12 measures.

## 15. Obligations handed forward

**To RLP-DOCUMENTS:**

1. `clampPosition` and the conversion layer of §4, with the astral, out-of-range, surrogate-split, and
   CRLF cases as tests.
2. The incremental/full differential test of §6.
3. A cancel token in `ExactRun`'s child poll (§9) — an addition to `monitorChild`, not a new mechanism.
4. The document admission gate of §5, including the `force-exclude` clause, which is new behavior
   relative to `stream` and needs its own test in both directions.

**To RLP-FEATURES:**

5. Range formatting answers with `sourceMap` and the expanded actual range (§8), and its documented
   non-idempotence in requested coordinates.
6. `source.organizeImports` calls `Application.organize`, the operation whose docstring
   (`Application.lean:1611`) has been promising this capability since `ruff-09`.
7. Code-action applicability exposure per §8: no disabled actions for withheld fixes.

**To RLP-FINAL:**

8. Drive the server with `Lean.Data.Lsp.Ipc` rather than a hand-rolled client (§2).
9. Malformed-message recovery (§11), concurrent cancellation (§9), Unicode positions (§4), dynamic
   reconfiguration (§10), and the 100-request memory stability of §13.
10. Editor setup inputs for VS Code, Neovim, and Emacs, including the multi-server formatting choice of
    §12 and the trailing-greedy comment ownership of §8 — the two behaviors a user will otherwise
    report as bugs.
