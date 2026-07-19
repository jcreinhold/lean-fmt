# RDF-LAYOUT results — the formatter owns ws/newline; FMT001/FMT002 retired

Status: **verified** (implementation prompt). The canonical reflow is now the sole, sound owner of
trailing-horizontal-whitespace and final-newline normalization; FMT001 and FMT002 are gone from
`ruleRegistry` and their definitions are deleted; every persistent test that used FMT001/FMT002 as its
fixable-source vehicle is migrated onto a surviving rule; and three new persistent regressions pin the
formatter-ownership behavior. This landed **before** the RDF-IMPL patch split, so `format` still composes
fixes today but the printer already owns ws/newline and the retired rules no longer exist. The one
non-green check (`tests/printer/run.sh`) is a pre-existing, out-of-scope stale-evidence census; see below.

## Commands run

- `LEAN_NUM_THREADS=1 lake build` → clean, 42 jobs.
- `lake exe lean-fmt-tests` → `lean-fmt module-artifact tests passed` (includes the retirement assertion
  that FMT001/FMT002 never fire, `LeanFmtTest.lean:55-60`).
- Touched suites, all pass: `tests/check/run.sh`, `tests/modes/run.sh` (carries the three new
  regressions), `tests/suppression/run.sh`, `tests/imports/run.sh`, `tests/semantic/run.sh`
  (`mixed-tier: one run reported ['FMT013', 'FMT014']`), `tests/service/run.sh`, `tests/lossless/run.sh`,
  `tests/boundary/run.sh`, `tests/compiler/run.sh`.
- `tests/printer/run.sh` → **one failure**, the pre-existing stale-evidence census (below). Its
  load-bearing corpus walk is `failures=0` (round-trip losslessness, extent tiling, header split,
  idempotence all `ok`).
- `check_prompt_architecture.py`, `write_next.py --check`, `git diff --check` (below).

## What changed and why

**Printer owns ws/newline as layout, sound by construction.** The trim operates only on slices the
printer has already proven are pure whitespace *trivia* — never token, string, or comment-body bytes — so
a multi-line string literal keeps its interior trailing spaces. Two independent mechanisms, chosen over a
naive whole-output `String` trim (which would re-commit the retired FMT001 in-string corruption, evidence
probe 4/6):

- `trimTriviaWs` (`Printer.lean:219-283`, mutual with `copyLineCommentWs`/`copyBlockCommentWs`): a
  kind-aware pass over a trivia slice. It drops a horizontal run only when a `\n` follows it in whitespace
  context; it commits (keeps) a run before a `--` line comment, trims the comment's *own* trailing
  whitespace before its newline (the sound part of what FMT001 did — `ruff format` trims after a comment),
  and leaves a `/- -/` block comment's interior untouched (its whitespace can be content). Applied at the
  two proven-trivia sites: the inter-token gap doc (`Printer.lean:1194-1195`) and the after-last-token
  trailing run (`Printer.lean:1918`). The inter-*claim* gap is emitted verbatim and *not* trimmed
  (`Printer.lean:1903-1906`), because it can carry a command's own unclaimed tail tokens — trimming there
  would reach token bytes.
- `normalizeEof` (`Printer.lean:289-292`): collapses trailing blank lines and guarantees exactly one
  final `"\n"` (empty output stays empty). Applied once, over the whole rendered string, in `format`
  (`Printer.lean:2151`). The end of any accepted module is trivia (a token's trailing run or the verbatim
  tail after a terminal command), so collapsing the final run is sound.

Both work on the printer's own emission in the normalized (`raw.crlfToLf`) coordinate system;
denormalization at publish restores line endings unchanged.

**FMT001/FMT002 retired.** `trailingWhitespace`, `trailingWhitespaceFinding`, `finalNewline`, and the
now-unused `isHorizontalWhitespace` are deleted from `Rules.lean`, and both codes are removed from
`ruleRegistry`. FMT003/FMT004 stay report-only source-tier, so a default `check`/`format` `requiredTier`
is still `.source` and keeps the source-only fast path. The live `rules --json` catalog order is pinned in
`tests/modes/run.sh:400-445` and no `text`-category rule remains.

**Test-vehicle migration (the retirement's blast radius).** FMT001/FMT002 were the default-enabled,
source-tier, fixable vehicle across the persistent suite. No single surviving rule is all three, so the
migration unifies on **FMT005** (duplicate import — the only default-enabled, source-tier, fixable-`.safe`
survivor) for the shared `check`/`modes`/`service` fixtures, and uses **FMT013** (redundant nested paren,
syntax, `.safe`) and **FMT014** (deprecated use, semantic, `.unsafe`) where a `--select`ed or
self-contained finding is needed. Where a test asserted FMT001's *whitespace* behavior specifically, it
was re-homed as a **formatter** assertion (the reflow now owns it):

| Test | Old vehicle | New vehicle / re-home |
| --- | --- | --- |
| `LeanFmtTest.lean` applicability + conflict + projection | FMT001 `.safe` / FMT002 | FMT013 `.safe` + FMT014 `.unsafe`; retirement assertion added (`:55-60`) |
| `tests/check/Findings.lean` + `run.sh` | trailing-ws FMT001 | layout-clean duplicate-import FMT005; collision probe → FMT004 |
| `tests/modes/run.sh` format/diff/demote goldens | FMT001 ws-trim | FMT005 dedup as the change (fixture is layout-clean, preserving demote-withhold) |
| `tests/modes` missing-newline diff | FMT002 finding | `findings=0`; the newline is layout, diff still shows the single edit |
| `tests/suppression/*` (DocComment/Nested/Custom/Movement/PerFile) | FMT001/FMT002 | FMT005 / FMT013; Movement re-homed onto `namespace␣␣␣␣␣Beta` reflow (a movement the printer owns) |
| `tests/service/run.sh` unsaved-bytes proof | FMT001 | duplicate-import FMT005 in the editor buffer |
| `tests/semantic/run.sh` mixed-tier / pass-order | FMT001 | FMT013 (self-contained, no `lean_fmt` dep in `$proj`) |
| `tests/compiler/run.sh` rule-message invalidation probe | FMT001 message | FMT013's `"redundant nested parentheses"` |
| `tests/imports/run.sh` prose | FMT001 | comment updated (layout, not a rule) |

**Live-code docstring correction.** `Suppression.lean:166-167,187-192` cited FMT001/FMT002 as *live*
suppressible findings ("a directive can suppress FMT002"). The `inScope` empty-finding clause is general
and correct and was left unchanged; only the prose was reframed to describe the range shapes generally and
name FMT001/FMT002 as the *retired* historical examples. This is live code, not a prerequisite record.

**Three new persistent regressions** (`tests/modes/run.sh:542-585`, fixtures built at runtime with
`printf` so no trailing whitespace is committed — `git diff --check` rejects that and editors strip it):

1. `format` with **no rule selected** trims interior *and* final-line trailing whitespace and adds one
   final newline (`findings=0`, `changed=1`); `check` reports the same file **clean** (layout is not a
   rule).
2. An in-string fixture `"alpha   \n  beta"` keeps its string value byte-identical under **both** `format`
   and `fix`; only the missing final newline is added. The retired FMT001 corruption cannot recur.
3. A verbatim tail after `#exit` (`trailing garbage   `) is emitted byte-for-byte except its own trailing
   whitespace, which the reflow trims, and gains a final newline.

## Evidence locators (live seams, this commit)

| Fact | Location |
| --- | --- |
| `trimTriviaWs` kind-aware trivia trim (mutual with comment copiers) | `Printer.lean:219-283` |
| Trim applied to inter-token gap doc | `Printer.lean:1194-1195` |
| Trim applied to after-last-token trailing run | `Printer.lean:1918` |
| Inter-*claim* gap emitted verbatim, deliberately **not** trimmed | `Printer.lean:1903-1906` |
| `normalizeEof` collapse-trailing + one final newline | `Printer.lean:289-292` |
| `normalizeEof` applied once over whole output, in `format` | `Printer.lean:2151` |
| FMT001/FMT002 defs + helpers deleted; absent from `ruleRegistry` | `Rules.lean` (grep: all absent) |
| Retirement assertion: FMT001/FMT002 never fire | `LeanFmtTest.lean:55-60` |
| `inScope` general (docstring reframed, logic unchanged) | `Suppression.lean:187-194` |
| Three formatter-ownership regressions | `tests/modes/run.sh:542-585` |

## Decisions changed during execution

- **Fixtures built at runtime, not committed.** The RDF-LAYOUT regressions need trailing whitespace, and a
  committed file carrying it fails `git diff --check` (confirmed: `tests/check/StringWs.lean:3: trailing
  whitespace`). The earlier plan to commit a `StringWs.lean` fixture (and glob it in `lakefile.lean`) was
  dropped; all three fixtures are `printf`-constructed at runtime under the lake root, untracked, invisible
  to the printer corpus, and removed by the trap. `lakefile.lean` is unchanged.
- **Regressions home = `tests/modes`, not a new suite.** `tests/layout/run.sh` already exists (it is the
  comment-attachment suite) and `tests/printer/run.sh` drives internal test commands, not the product CLI;
  the prompt permits either `tests/printer` or `tests/modes`. The product-CLI level (`format`/`fix`/`check`
  exit codes + JSON) fits `tests/modes`, which already has the `run_expect` harness.
- **Shared-fixture unification on FMT005.** Established empirically (service `analyze` computes FMT005
  identically to batch `check` via `checkSnapshot`), because no surviving rule is default-enabled +
  source-tier + fixable the way FMT001 was.

## Files changed

- Live code: `LeanFmt/Printer.lean`, `LeanFmt/Rules.lean`, `LeanFmt/Suppression.lean`, `LeanFmtTest.lean`.
- Live tests: `tests/check/Findings.lean`, `tests/check/run.sh`, `tests/modes/run.sh`,
  `tests/imports/run.sh`, `tests/semantic/run.sh`, `tests/service/run.sh`, `tests/compiler/run.sh`,
  `tests/suppression/{run.sh,Custom.lean,DocComment.lean,Movement.lean,Nested.lean,PerFile.lean,
  lean-fmt.toml}`.
- Docs/state: this file, `state/current.md`, `state/next.md`.

## Structural checks

- `check_prompt_architecture.py` → `checked 1 stack(s): 0 error(s), 0 warning(s)`.
- `write_next.py --check` (pre-update) → `OK: state/next.md matches first_unresolved='02-layout'`.
- `git diff --check` → clean (exit 0): the runtime-fixture approach keeps trailing whitespace out of every
  tracked file.

## Remaining uncertainty / known non-green

- **`tests/printer/run.sh` census failure is pre-existing and out of scope.** The single failure is
  `FAIL the shape evidence is stale: it reports 541 commands, the live corpus has 660`
  (`tests/printer/run.sh:140-145`). It compares the live corpus command count against a **frozen ruff-03
  evidence record**, `docs/projects/ruff-03-language-formatting/evidence/01-projection-shape.txt`. That
  file records 541 from the ruff-03 era; every stack since (through ruff-11b) grew the corpus past it, so
  the mismatch predates RDF-LAYOUT — my net command-count delta is small (Printer.lean added a few private
  defs, Rules.lean *removed* two rule defs). The test's own remediation (`:137` "Re-run
  experiments/run-projection-shape.sh") regenerates that evidence file, which the 02-layout prompt
  **explicitly forbids** ("Do not rewrite historical prerequisite-stack records under
  docs/projects/*/{...,evidence,...}"). So the suite cannot be made green in this stack without violating
  the prompt; the load-bearing round-trip/tiling/idempotence checks all pass, and the second evidence link
  (`check-quoted-figures.py`, "figures quoted in Printer.lean/notes/state agree with the evidence") passes.
  Disposition: documented, not fixed here; a future stack that owns ruff-03's evidence re-runs the probe.
- The RDF-IMPL patch split (layout patch vs fix patch, `fix.rendersCanonical := false`, `demandedCaps`
  rewire, `reprojectCanonical`/`patchDuplicateFindings` retirement) is untouched here by design — `format`
  still composes fixes pre-split. That is 03-impl's work.
