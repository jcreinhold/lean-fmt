# Results 02 — FIP-IMPL (format publishes in place)

**Claim:** FIP-IMPL. `format` now publishes the canonical layout in place by default through the
`ruff-06` guarded path; `format --check` is the non-writing CI preview. Implemented exactly the
interface FIP-SPEC froze (`notes/01-model.md`) — no surface beyond the reuse-vs-new inventory.

## What changed (code)

- **`Application.lean`**
  - `RunRequest.formatCheck : Bool := false` and `RunRequest.writesFormat` (`mode == .format &&
    !formatCheck`) — the write disposition.
  - `formatFile` — the writer, structurally `fixFile` with `renderCanonical := true` and status
    `formatted`: renders the layout patch, short-circuits `clean` when unchanged, validates the
    reflowed bytes under the exact setup (`analyzeSnapshot … validator := true`), `publishAtomic`s
    the losslessly-denormalized output. No rule fix. `broken`/`rejected` handled exactly as `fix`.
  - `summarize` `changed` predicate gains `"formatted"`.
  - Driver: both cache-only preview fast paths now guarded by `!request.writesFormat` (a writer needs
    the validator child, so it must fall through to `withExactRun`); the `withExactRun` `.format`
    dispatch routes to `formatFile` by default, `previewFile .format` under `--check`.
  - Comment rewrites: the `unsafeFixes` docstring, the `prepareFile` layout-patch docstring
    ("publishes `output` in place"), per the grep list.
- **`Cli.lean`**
  - `parseFileArgs`: `--check` parsed, gated on `mode == .format` (error otherwise), sets
    `formatCheck`.
  - `renderText` `"format"` arm: concise per-file status summary (`path: formatted` /
    `path: would-format`; clean is silent), never the file body. `--json` unchanged.
  - `reportExitCode (writer : Bool)`: a writer (`fix`, or `format` without `--check`) exits 0 on a
    published change; previews (`check`/`diff`/`format --check`) exit 1 on a would-change. Call site
    passes `mode == .fix || command.run.writesFormat`.
  - `usage`: `--check` documented for `format`.
- **`Semantic.lean`**: `CanonicalText.text` docstring — "what `format` publishes in place".
- **`CLAUDE.md`**: invariant rewritten to "`check` and `diff` never write source. `format` and `fix`
  publish only a complete, conflict-free result validated under the exact module setup, after a
  stale-source check…".

## Commands & outputs

- `LEAN_NUM_THREADS=1 lake build lean-fmt` → `Build completed successfully (42 jobs).`
- Manual CLI smoke (fixture `tests/check/Layout.lean`, restored after):
  - `format --check` → `would-format`, exit 1, md5 unchanged (no write).
  - `format` → `formatted`, `written=1`, exit 0, file rewritten to canonical.
  - `format` again → `clean`, `written=0`, exit 0 (idempotent).
  - `format --json` (written) → `{"status":"formatted","written":true,"formatted":"…"}`.
- Suites — all pass:
  - `tests/modes/run.sh` (biggest migration; confluence rewritten to write in both orders)
  - `tests/check/run.sh`, `tests/lossless/run.sh`, `tests/imports/run.sh`,
    `tests/suppression/run.sh`, `tests/syntax/run.sh`, `tests/semantic/run.sh`,
    `tests/service/run.sh`, `tests/compiler/run.sh`, `tests/scale/run.sh`, `tests/boundary/run.sh`
  - `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed`

## Test migration (what each kept proving)

- **Preview-intent `format` calls → `format --check`** (identical `would-format`/`formatted`
  assertions, no write): the modes preview trio, the "format formats" `Layout.lean` render, the
  artifact/fallback/cache-hit path-coverage trio (the cache-hit case *requires* `--check` — a writer
  would need the validator child and could not be served from cache with `LEAN_FMT_TEST_ANALYZER=
  /usr/bin/false`), the check-populated-miss probe, the RDF-IMPL mixed previews, the three RDF-LAYOUT
  regressions; and across suites: `imports` format-conflict, `suppression` move-format, `syntax`
  FMT013-absent, `semantic` FMT014-absent, `check` agreement.
- **Confluence rewritten to WRITE** (`tests/modes`): order A (`fix` then `format`) and order B
  (`format` then `fix`) now both materialize on disk via the tools themselves — no captured-preview
  step. Both written files are byte-compared to the canonical bytes and to each other; each is a
  fixed point (a fresh `format` is `clean`/`written:false`, a fresh `check` clean).
- **Left as plain writing `format`** (intent is the real verb, not the preview):
  - `check` case-9(b): `format`/`format --select FMT013` with the analyzer disabled each surface
    exactly one infrastructure failure (exit 2) — the write default still owes exactly one frontend
    run; analysis fails before any write, so nothing is written.
  - `semantic` demand-gating: `format` on `Clean.lean` with the analyzer disabled rejects the
    `semantic=none` artifact and exits 2 — unchanged by the write default.

## Checks read

`check_stack.py --structural`, `check_prompt_architecture.py`, `write_next.py --check`,
`git diff --check` (recorded in the commit). No trailing-whitespace fixture committed (all
runtime-built under the lake root, trap-removed).

## Decisions changed from spec

None. `formatFile` was kept a distinct wrapper (not collapsed with `fixFile`) — the publish path is
reused, not duplicated; the two wrappers differ only in `renderCanonical` and the status string, and
keeping them separate reads more clearly than a boolean-parameterized merge.

## Remaining uncertainty

- FIP-FINAL owns the adversarial write acceptance (exact bytes on a written file, `--check` never
  writes, broken never written, CRLF/in-string round-trip on write, stale-source guard, no-arg
  project-wide write). This prompt proved the mechanism and migrated the suite; FIP-FINAL pins the
  edges.
</content>
