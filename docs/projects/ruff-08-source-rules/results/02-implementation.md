# RSR-IMPL — Implement and document source rules

**Verified.** The two rules the catalog approved (`notes/01-catalog.md` §3) are live, report-only, and
covered at every owning layer. This records what was built, what it measured, and what changed while
building it.

## What shipped

- **`FMT003` forbidden control byte** and **`FMT004` suspicious bidirectional control**, in
  `LeanFmt/Rules.lean`'s `ruleRegistry`. Category `security`, default-enabled, `fixable := false`,
  severity `warning`, `fix? := none`.
  - `FMT003` is a single scan over the shared `SourceFacts.bytes` — no UTF-8 decoding, because every
    forbidden byte (C0 minus TAB/LF, plus DEL) is one ASCII byte and never a continuation byte.
  - `FMT004` is one `String.foldl` over the normalized source, decoding each scalar once and carrying
    the running byte offset in the accumulator, so a multibyte mark's range is its exact UTF-8 span
    without a second pass. Both satisfy the stop rules "no parser or project capability" and "avoid
    repeated UTF-8 decoding."
- **Configuration selectors**: `LeanFmt/Config.lean`'s `expandSelector`/`selectorsValid` now derive
  categories from the registry (`isCategory`) instead of special-casing the string `"text"`. Adding
  the `security` category made `--select security` work with no per-category code; the two selectors
  and the validator can no longer drift apart. Net −1 hardcoded literal.
- **Suppression, JSON, `rules`**: no code needed — the registry is the single source, so FMT003/FMT004
  flow through suppression (projection over codes), the `rules` command (text and JSON), config
  selection, and reporting automatically. Confirmed by test, not by assumption.
- **Docs**: `docs/adding-a-rule.md` gains a "Report-only rules" section (FMT003/FMT004 as the shipped
  examples, and why acceptance supplies their token context); its placeholder example code moved off
  the now-real `FMT003` to `FMTxxx`; the category note now says categories are registry-derived; the
  testing section points at the new tests.

## Commands run

- `LEAN_NUM_THREADS=1 lake build` — clean (40 jobs).
- `lean-fmt rules` / `rules --json` — shows all four; FMT003/FMT004 as `security` / `report-only` /
  `default`. Raw output pinned by `tests/modes/run.sh` (updated golden).
- Rule behavior, measured on crafted accepted source (`def s := "a<NUL>b"` + `-- x<RLO>y`):
  `FMT003 range=[11,12) U+0000 fix=false`, `FMT004 range=[19,22) U+202E fix=false`; a clean file
  yields only FMT002. Byte-exact and report-only.
- `lean-fmt-tests` — passes, including the new `testSourceSecurityRules` (positive control-in-string
  and bidi-in-comment, negative TAB/LF, Unicode two-byte ALM range, DEL, applicability), `testConfig`
  (the `security` category selector and its disjointness from `text`), and `testSuppression` (an
  FMT004 finding suppressed by a directive naming it).
- `tests/modes/run.sh`, `tests/check/run.sh`, `tests/suppression/run.sh`, `tests/boundary/run.sh` —
  pass. (`tests/modes` hit one transient plugin-dylib relink race — a concurrent `clang -shared` on
  `LeanFmtCompilerPlugin`, before any assertion — and passed on immediate re-run; unrelated to this
  change, which does not touch the plugin.)
- `check_stack.py --structural` and `write_next.py --check` — pass. `git diff --check` — clean.

## Decisions changed while building

- **Category selection was generalized, not duplicated.** The catalog froze category `security`; the
  live selector hardcoded `"text"`. Rather than add a second literal, `isCategory` reads the registry,
  which is the "smallest deep capability" the plan asks for and removes a drift seam.
- **TAB is load-bearing in the exclusion.** `testRules`' existing fixture ends a line with `\t`; had
  `FMT003` flagged TAB, that unrelated test would have gained a finding. The catalog's TAB exclusion
  (`notes/01-catalog.md` §3) is confirmed correct against live tests, not just argued.

## Remaining uncertainty

- No end-to-end fixture commits an actual control/bidi byte into the CLI corpora; coverage is at the
  unit/owning layer (the byte scans, the selector, the suppression projection). `RSR-FINAL` owns
  property/fuzz boundary tests and large-file microbenchmarks, where a committed-byte corpus and the
  linear-time claim belong.
- The `FMT003` set is frozen conservatively (C0-minus-TAB/LF plus DEL); widening it would reopen
  `notes/01-catalog.md` rather than drift.
