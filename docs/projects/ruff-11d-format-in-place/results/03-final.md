# Results 03 — FIP-FINAL (in-place format accepted adversarially)

**Claim:** FIP-FINAL. The in-place default is accepted through the product CLI and pinned as
persistent regressions in `tests/modes/run.sh` (the verb-behavior suite). No production code changed
in this prompt — FIP-IMPL delivered the mechanism; this prompt proves its edges and freezes them.

## Where the acceptance lives

A single `FIP-FINAL` block appended to `tests/modes/run.sh` (before the final success line), driven
through the product binary, with seven scratch fixtures registered in the suite's trap (all under the
lake root, untracked, trap-removed — the CRLF and trailing-whitespace ones cannot be committed;
`git diff --check` and the leak check below confirm none escaped). The `tests/lossless` suite drives
the low-level `__analyze-exact` projection, not the `format` verb, so the write round-trips are pinned
here where the CLI is driven, not there.

## Cases (each driven through the CLI, each a persistent regression)

1. **Exact bytes.** A layout-dirty, lint-clean fixture (`namespace␣␣␣␣␣Gamma`): `format` writes
   EXACTLY `canonical.text` (byte-compared to `module\n\nnamespace Gamma\n…`), status `formatted`,
   `written == 1`, and `findings == []` — no rule fix appears on the written file (the `ruff-11c`
   fix-free guarantee, now on a written file).
2. **Idempotence.** A second `format` on the written file → `clean`, `written == false`,
   byte-identical.
3. **`--check` never writes.** On the dirty fixture, `format --check` → `would-format`, exit 1, file
   byte-identical (`metadata` before/after `cmp`); plain `format` then writes it; `format --check` on
   the now-clean file → `clean`, exit 0.
4. **Broken file never written.** `def bad : Nat := true` → `broken`, exit 1, `written == 0`, file
   byte-identical, and no `.lean-fmt-tmp-*` orphaned beside it (the validation/atomic guard holds for
   `format` as for `fix`).
5a. **CRLF write round-trip.** A CRLF fixture formatted in place keeps CRLF (`\r\n` present, no bare
   `\n`), layout canonicalized (`namespace Delta\r\n`, not the five-space form) — `denormalize` on
   write.
5b. **In-string write round-trip.** `def stringVal : String := "alpha   \n  beta"` (no final
   newline): `format` adds the final newline (layout) but the file is byte-exactly
   `…"alpha   \n  beta"\n` — the string value survives, the trivia-only trim cannot reach token
   content on a write any more than in preview (`ruff-11c` RDF-LAYOUT).
6. **Stale-source guard.** A `LEAN_FMT_TEST_BEFORE_WRITE` hook mutates the source between analysis and
   rename; `publishAtomic` refuses the write → `rejected`, exit 1, `written == 0`,
   `"source changed after analysis"` in the report — identical to `fix`'s stale behavior.
7. **No-arg project-wide write.** With `include = ["tests/modes/.fip-final-incl.lean"]`, `format` with
   NO file args writes exactly that file (`paths == [incl]`, `formatted`/`written`), leaving the
   excluded sibling byte-identical (`metadata` before/after `cmp`) — no-arg `Project.load` discovery
   filtered by `config.includesPath` chooses the set; the write default acts on exactly it.
8. **`check`/`diff` still never write.** On a fresh dirty fixture, `check` (exit 0) and `diff`
   (exit 1) both leave it byte-identical.

**Confluence with format writing** is pinned in the FIP-IMPL-rewritten confluence block earlier in the
same suite: order A (`fix; format`) and order B (`format; fix`) both now materialize on disk via the
tools themselves; both written files are byte-compared to the canonical bytes and to each other, and
each is a fixed point (a fresh `format` is `clean`/`written:false`). Re-verified passing here.

## Commands & outputs (all pass)

- `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests …` (via the suite) → `Build completed
  successfully`.
- `tests/modes/run.sh` → `lean-fmt product mode integration tests passed` (includes the FIP-FINAL
  block).
- `tests/check/run.sh`, `tests/lossless/run.sh`, `tests/boundary/run.sh` → all pass; manual boundary
  review: no production code changed this prompt, `LeanFmt.Rules` stays absent from the plugin
  library/imports; the boundary suite is green.
- `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed`.
- Scratch-leak check: `git status --porcelain | grep -E '\.fip-final|\.rdf-|\.lean-fmt-tmp'` →
  nothing (trap removed every fixture and any temp).

## Frozen-sample review (read-only, no full mathlib)

Per the roadmap evidence policy and CLAUDE.md ("do not repeatedly run full mathlib"), the write
acceptance is proven on miniatures exercised by the real Lean 4.32 parser and frontend (the
CRLF/exact/in-string fixtures each take a live `analyzeExact` run), and by inspection of the write
path (`formatFile` → `publishAtomic` → `denormalize`) for the large-module case. A `format` of a real
dirty mathlib sample module would write only canonical layout — the same layout `format --check` and
`diff` already preview on the frozen sample (`ruff-11c` RDF-FINAL) — because the write path renders the
identical layout patch and applies no rule fix. No 8,795-file run; that is `ruff-20-acceptance`'s to
schedule.

## Files changed

- `tests/modes/run.sh` (FIP-FINAL acceptance block + seven trap-registered scratch fixtures).
- `docs/projects/ruff-11d-format-in-place/prompts/03-final.md` (status → verified),
  `results/03-final.md` (new), `state/current.md`, `state/next.md`.

## Remaining uncertainty

- None blocking. Config-scoped globs/`exclude` and a `[format]` section (`ruff-13`) and stdin/stdout +
  range (`ruff-14`) remain the named next surfaces; the no-arg write here uses the existing
  `include`-filtered discovery, which `ruff-13` will generalize.
</content>
