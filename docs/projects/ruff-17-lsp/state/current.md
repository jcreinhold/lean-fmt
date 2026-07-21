---
kind: state
first_unresolved: 03-features
---

# Current state

**`RLP-PROTOCOL` is verified** (`results/01-protocol.md`; freeze `notes/01-protocol.md`; baseline
`evidence/01-lsp-baseline.md`; probe `evidence/01-position-probe.{lean,txt}`). Following the `*-SPEC`
convention it shipped no production interface — the capability and state model, its measurements, and
one characterization test (`LeanFmtTest.lean`, `testLspPositions`).

Its external prerequisite stacks are `ruff-06-fix-safety`, `ruff-07-suppressions`,
`ruff-13-config-discovery`, `ruff-14-stream-range`; all four record `first_unresolved: none`, and the
live code the freeze depends on was re-read rather than trusted (`Service.lean`, `Application.lean`,
`Project.lean`, `Discovery.lean`, `Cli.lean`, plus the toolchain's `Lean/Data/Lsp/`,
`Lean/Server/Utils.lean`, `Lean/Server/Watchdog.lean`, `Init/System/Uri.lean` at `v4.33.0-rc1`). If
live code contradicts a prerequisite result, reopen the owning prerequisite rather than patching
around it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-protocol | RLP-PROTOCOL | verified | — |
| 02-documents | RLP-DOCUMENTS | verified | RLP-PROTOCOL |
| 03-features | RLP-FEATURES | planned | RLP-DOCUMENTS |
| 04-acceptance | RLP-FINAL | planned | RLP-FEATURES |

**`RLP-DOCUMENTS` is verified** (`results/02-documents.md`). `LeanFmt/LanguageServer.lean` (694 lines)
is live behind `lean-fmt lsp`: our own Content-Length reader over Lean's writer, initialize/shutdown/exit,
a bounded document store (32 MiB message, 16 MiB document, 256 documents, 64 queued messages),
incremental sync with version ordering, three-clause admission, `$/cancelRequest` applied by the reader
thread while the worker is busy, configuration reload, health, and malformed-message recovery.
`tests/lsp/run.sh` drives a live server through 39 checks.

- **All four of `01-protocol`'s obligations are discharged** — clamping, the differential splice test
  (6 documents × 9 change sequences against an independent implementation), a cancellation token in
  `ExactRun`'s existing 50 ms child poll, and the `force-exclude` admission clause.
- **The freeze was amended twice**, once for the framing split (the read half is ours; the write half is
  Lean's) and once to replace a source-false justification: `Lean.Server.*` stays out of *this* module
  because `replaceLspRange` does not clamp, not because of `Lean.Server.InfoUtils`, which
  `LeanFmt/Analysis.lean:6` already imports legitimately.
- **No feature answers a formatting request yet.** The capability set is advertised and
  `RLP-FEATURES` implements it; a client calling `textDocument/formatting` today gets MethodNotFound.
- **Two suite couplings a later prompt will meet.** `tests/watch/run.sh` asserts `check --staged`
  against the *real* repository, so it fails whenever anything is staged; and this repository is the
  printer's own corpus, so adding a production module moves every figure
  `experiments/check-quoted-figures.py` gates — the module must be `git add`ed before
  `experiments/run-projection-shape.sh` (which selects with `git ls-files`) can see it.

## What `01-protocol` froze, for the prompts that consume it

The freeze is `notes/01-protocol.md`; these are the clauses a later prompt is most likely to
rediscover the hard way.

- **The position layer is `Lean.FileMap` over the *normalized* document**, and it is a conversion, not
  a validator. Measured: LSP `(0,9999)` in a 43-byte document answers byte **10003**; a byte offset
  interior to a codepoint answers a silently wrong column; a column splitting a surrogate pair snaps
  *forward* past the whole character. Nothing raises. The server clamps every inbound position itself
  (§4, obligation 1).
- **`Application.PositionIndex` is not that layer.** At byte 24 of the astral fixture the three
  spellings are codepoint column **19**, UTF-16 column **20**, byte column **25**. One astral character
  is not enough to tell the first two apart — at byte 16 both answer 14 — so the test uses two.
- **Text sync is incremental (kind 2)**, because sync payload is per keystroke and analysis is per
  debounced request. The differential test against full replacement is obligation 2 and is the one
  obligation whose failure corrupts a user's file.
- **Document admission adds a `force-exclude` clause** that `Application.stream` does not have (§5,
  obligation 4). `Discovery.explain` already answers it.
- **`ExactRun` has no cancellation input today** — `monitorChild` polls `child.tryWait` every 50 ms and
  checks only memory (`Application.lean:266-289`). Obligation 3 adds a token to that same poll.
- **There is no capability contention with Lean's own server**: `Lean.Lsp.ServerCapabilities` has no
  formatting provider among its 18 fields, and no formatting method is implemented anywhere in
  `Lean/Server/`. lean-fmt therefore declares its own formatting capability and params DTOs (§2, §12).
- **`Lean.Server.*` stays out of production imports** (it drags `Lean.Server.InfoUtils`);
  `Lean.Data.Lsp` is taken wholesale, and `Lean.Data.Lsp.Ipc` is RLP-FINAL's client harness.

## Inherited from `ruff-14-stream-range` (verified)

Measured there, and design input here rather than trivia to rediscover:

- **A range is not cheaper than the whole buffer** (`ruff-14/evidence/03-stream-cost.txt`). The cost of
  a request is one exact frontend run over the whole document, which a range cannot skip without
  giving up exactness. `textDocument/rangeFormatting` is not the fast path it is usually assumed to
  be, so debounce, cancellation, and capacity decisions must not be built on the assumption that a
  small selection is a small request.
- **Comment ownership at a unit boundary is trailing-greedy.** A comment written *above* a declaration
  belongs to the **earlier** unit, so range-formatting a declaration does not include the comment a
  user would say belongs to it. This is user-visible in an editor in a way it is not in a pipeline;
  decide deliberately whether the LSP surface explains it, and do not "fix" it here — it is
  `RLC-SPEC`'s frozen verdict and `ruff-14` re-confirmed it on real source.
- **The forward-extension clause is real but never fires on idiomatic Lean**: 0 of 2,854 layout units
  on the frozen mathlib sample (`ruff-14/evidence/03-range-unit-census.txt`). Practical consequence for
  this stack is small — the actual range must be reported either way — but do not "simplify" the
  expansion rule on the strength of a client never having observed it widening.

## Inherited from `ruff-15-reporting` (verified)

- **`Application.PositionIndex` is not this stack's conversion layer, and reaching for it would be
  silently wrong.** `ruff-15` added a byte-offset → (line, column) index, but its columns are 1-based
  **codepoints**, the encoding `ruff-14` froze for `--range-lines`. LSP positions are UTF-16 code
  units. The two agree on everything in the BMP and disagree outside it, which is why the difference
  survives casual testing: `ruff-15`'s astral fixture (`𝔘`, 4 bytes / 2 UTF-16 units / 1 codepoint)
  reports column **34**, where a byte column is 37 and a UTF-16 column is 35
  (`tests/reporting/run.sh`, "codepoint columns are neither bytes nor UTF-16"). The roadmap already
  requires "one tested conversion layer"; this is the concrete trap it has to avoid, and the astral
  fixture is the shape of test that catches it. `PositionIndex` is reusable as a *pattern* — resolve
  only the offsets the answer names, in one forward pass — not as an implementation.

## Inherited from `ruff-16-watch-incremental` (verified)

> **[REFUTED by `ruff-16b-cache-identity` `RCI-SPEC`, 2026-07-20. The in-process framing below is
> wrong; do not act on it.]** There is no in-process cache-reuse defect. `execute` opens a fresh
> `ResultCache` per call (`Application.lean:1298`) and `loadedEntries` is created inside `open?`
> (`Cache.lean:267`), so nothing is retained between calls to go stale. The compared numbers were
> different workloads: cold-after-edit against an unchanged tree.
>
> The confirmed defect is whole-project cache-key invalidation, and it is **process-independent**.
> `Cache.environmentDigest?` folds every project source's bytes into `environment`, which feeds
> `baseDigest`, which names the index file — so one edit renames the index and orphans every entry,
> in a fresh process just as much as a reused one. Reproduced at entry granularity: after appending
> one comment to one file, **0 of 112 entries hit**, not 111
> (`ruff-16b-cache-identity/results/01-contract.md`). The 135× figure below is real; its
> attribution is not.

- **`execute` does not reuse the result cache when called twice in one process.** Measured
  (`ruff-16/results/02-implementation.md`, decision 3): a second in-process `execute` after a
  one-file edit took **~70 s** — the full cold-cache price — where a *separate* process handling the
  identical edit took **0.52 s**. A 135× penalty. `ruff-16` routed around it by making every watch
  generation a fresh child process; nothing fixes it, and the root cause was not investigated because
  it lives in `Cache`/`Application`.

  **This stack is the one that cannot route around it.** An LSP server is by definition a long-running
  process answering many requests, so if its request path reaches `execute` it will pay the cold price
  on every request after the first. `LeanFmt.Service` already avoids this by holding one
  `Project.load` per session and answering through `Application.ExactRun` rather than `execute`
  (`ruff-14`) — `01-protocol` should confirm that the LSP path inherits that route and never calls
  `execute` per request, and should treat any design that does as blocked on the defect above.

> **Unblocked by `ruff-16b-cache-identity` `RCI-IMPL` (2026-07-20).** The underlying defect is fixed,
> not merely re-attributed. Entries are keyed per file on their import closure's build artifacts, so an
> edit invalidates that file and its dependents instead of the whole project, in any process. On this
> repository a warm re-run serves 119/119 in 0.52 s, and editing one file leaves every unrelated entry
> hitting.
>
> There was never an in-process penalty to inherit — `execute` opens a fresh `ResultCache` per call —
> so an LSP path that reaches `execute` is no longer choosing between correctness and the cold price.
> `LeanFmt.Service`'s route stays the right one for *unsaved* buffers, which is a different problem:
> disk-state evidence cannot answer for bytes that are not on disk. Confirm that, not the cache.

> **One thing to carry from `RCI-FINAL` (2026-07-20).** `ResultCache.open?` returning `none` is a
> supported outcome that reports nothing, so a project running with the cache entirely disabled looks
> from the outside exactly like one running cold. On mathlib that was the real state of the world —
> zero entries ever written, because of one absent search-path directory — and nothing said so. A
> long-running server multiplies the cost of that silence across every request of a session, and
> `ruff-19-performance` owns the diagnostic. This stack should at least not *assume* the cache is
> live when reasoning about request cost.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
