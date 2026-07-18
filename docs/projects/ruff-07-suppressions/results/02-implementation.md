# RSP-IMPL — Implement suppression projection and unused-directive rule

**Verified.** The layer designed in `notes/01-spec.md` is now live: directives are parsed from the
lossless comment trivia, projected over the config-selected findings after the cache, and the unused
(`FMT900`) and malformed (`FMT901`) self-diagnostics are reported with fixes. Evidence spanning every
scope, placement, and recovery case is `evidence/02-suppression.txt`.

## What landed

- **`LeanFmt/Suppression.lean`** (new module). `DirectiveScope` (`line`/`nextItem`/`file`),
  `Directive`, `SuppressionFacts`, the grammar parser `parseBody`, scope resolution `directiveScope`
  / `inScope`, the projection `apply` → `Outcome{kept, suppressed, unused}`, and the `FMT900`/`FMT901`
  finding builders with their removal/display-only fixes. `collect` reads directives from
  `Comments.allTrivia` **plus** a dedicated `headerComments` scanner for the module header (see below).
- **`LeanFmt/Semantic.lean`**. `SemanticResult` gained `suppression : SuppressionFacts`; the schema
  bumped `v3 → v4` so every stale entry misses rather than reading as "no directives". Facts are parsed
  in `ofEnvelope?` (syntax-tier, where the projection is in hand) via `Suppression.collect`.
- **`LeanFmt/Application.lean`**. `projectSuppression` runs `apply` after `plan.findings` (config
  selection) and appends the `FMT900`/`FMT901` self-diagnostics to the report. `suppressed` counts
  thread through `PreparedFile`/`FileReport`/`RunReport`. The source-only shortcut in
  `availableAnalysis` is gated by `Suppression.mayContainDirective` so a directive-bearing file takes
  the projection path. **Patches are built from the suppression-free config-selected findings** in
  every mode (see decision 2).
- **`LeanFmt/Cli.lean`**. `suppressed=<n>` added to the text summary and the statistics line.
- **`LeanFmtTest.lean`**. `testSuppression`: five `apply` unit cases (blanket, code selector, unused
  `FMT900`, mixed live/dead list, EOF `FMT002` boundary) plus two `collect` cases proving the header
  scanner parses a valid header directive and reports a malformed one.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                          # exit 0 (40 jobs)
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests             # module-artifact tests passed (incl. testSuppression)
tests/boundary/run.sh                                  # native boundary passed
tests/check/run.sh tests/modes/run.sh tests/printer/run.sh \
  tests/layout/run.sh tests/semantic/run.sh tests/lossless/run.sh \
  tests/printer/run.sh tests/service/run.sh            # all exit 0
git diff --check                                       # clean
check_stack.py    docs/projects/ruff-07-suppressions --structural
write_next.py --check docs/projects/ruff-07-suppressions
```

Environment: `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No performance claim is made; the
measurements are `check` invocations on small single-file fixtures.

## What was measured (`evidence/02-suppression.txt`)

Nine fixtures, one `check` each. Every scope suppresses where it should (`suppressed=1`, `findings=0`):
`ignore-file` and `ignore-next` at the **top of the file** (header region), after an `import`, in the
command body, and as a trailing comment. Recovery is loud, never silent: a wrong-code directive leaves
the finding reported **and** raises `FMT900`; a malformed verb raises `FMT901 [display-only]`; a
genuinely unused blanket raises `FMT900 [safe]`. A directive **inside a string literal**
(`InString.lean`) suppresses nothing — the finding on the next line still reports — because directives
are read from comment trivia and a string is a token, satisfying the `RSP-SPEC` stop rule by
construction.

## Decisions changed during execution

1. **The module header is not in the trivia projection, so `collect` scans it directly.**
   `Comments.allTrivia` begins at `headerStop` ("a module linter never receives the header"), so a
   directive placed at the top of a file — the natural home for `ignore-file` — was invisible: no
   suppression *and no diagnostic*. The first end-to-end run reproduced exactly this (a header
   `ignore-file` left `FMT001` reported, `suppressed=0`, and a header `bogus` verb produced no
   `FMT901`). Fixed with `Suppression.headerComments`, a small scanner over `[0, headerStop)`. It is
   safe because the header grammar is tiny: only `module`, `import`, and interspersed whitespace and
   comments live there — module/doc docstrings parse as commands and sit past `headerStop`, so there
   is no string literal and no docstring in the region to misread. A directive after the first command
   was always handled and remains so; the fix closes the top-of-file gap.

2. **Suppression shapes the report, never the patch; `format`/`fix` reformat unconditionally.** The
   first wiring fed the suppression-projected findings (including the `FMT900`/`FMT901` removal edits)
   into the non-canonical `check` patch, while the canonical `fix` patch — drawn from
   `canonical.findings` — omitted them. `check` then reported a byte change `fix` would never make.
   Corrected so **every** patch is built from the suppression-free config-selected findings: a
   directive silences a diagnostic in the report without changing published bytes, and `check`, `diff`,
   `format`, and `fix` agree. A consequence, handed to `RSP-FINAL`: batch `fix` does **not**
   auto-remove an unused directive (it reformats and preserves comments); the `FMT900 [safe]` removal
   is an editor code-action. `check` still exits non-zero on the `FMT900` diagnostic — the correct
   lint-vs-format split (ruff flags an unused directive; the formatter is unconditional).

3. **The result-cache schema, not the config, carries suppression.** Directives are pure functions of
   source, so they are cached *content* (`SemanticResult.suppression`, schema `v4`), not a cache key.
   Config selection still projects afterward, so `--select` remains a post-cache projection and cache
   identity is unchanged — the `RSP-IMPL` stop rule.

## Remaining uncertainty (handed to RSP-FINAL)

- **Formatting movement.** Scopes are recomputed from comment position each run and index normalized
  source, so a directive should track its target across reformatting. `RSP-FINAL` must confirm this on
  a directive whose target moves under `fix` (e.g. a reflowed multi-line item) — the acceptance case
  "formatting movement".
- **`fix` and unused directives.** Decision 2 leaves batch `fix` unable to remove an unused directive.
  `RSP-FINAL` owns "unused fixes" and should decide whether that is the final boundary or whether a
  targeted suppression-layer pass belongs in `fix`.
- **Custom commands / nested syntax / per-file config / file ignores.** Exercised only lightly here;
  `RSP-FINAL`'s acceptance matrix covers them.
