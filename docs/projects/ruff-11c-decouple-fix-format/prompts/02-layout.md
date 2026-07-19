---
claim_id: RDF-LAYOUT
status: planned
depends_on: [RDF-SPEC]
---

# Move whitespace/newline normalization into the formatter; retire FMT001/FMT002

## Task

Deliver **RDF-LAYOUT**: Make the canonical reflow the sole, sound owner of trailing-whitespace and
final-newline normalization, and retire FMT001/FMT002 as lint rules. After this prompt, `Printer.format`
output trims the trailing horizontal whitespace it lays down (in the whitespace *trivia* it emits — never
token text, so string literals are safe **by construction**) and ends with exactly one final newline;
FMT001 and FMT002 are gone from `ruleRegistry` and their rule definitions are deleted; and every
persistent test that used FMT001/FMT002 as its fixable-source vehicle is migrated onto a surviving
import/syntax/semantic rule. This lands **before** the RDF-IMPL patch split so `format` never regresses:
while `format` still composes fixes (pre-split), the printer already owns ws/newline and FMT001/FMT002 no
longer exist.

Read `roadmap.md`, `results/01-spec.md` (the frozen resolution and the first-hand evidence that the
printer does *not* subsume ws/newline today, and the FMT001 string-corruption defect), `notes/01-model.md`,
`AGENTS.md`, `docs/adding-a-rule.md`, and the live seams before changing an interface.

## Target

- **Printer (`LeanFmt/Printer.lean`).** Extend the canonical trivia model so the rendered output is
  whitespace/newline clean as **layout**:
  - Trim trailing horizontal whitespace (`0x20`, `0x09`) that the printer emits before each newline **in
    trivia it lays down**, never inside a token. The last token's trailing run and the verbatim-token
    slots (doc comments, attributes, string literals) hold token/verbatim bytes; the trim must touch only
    the whitespace trivia the printer itself produces, so a multi-line string literal
    (`"alpha   \n  beta"`) keeps its interior trailing spaces. Prove this is sound by construction — the
    trim operates on the printer's own whitespace emission, not on a byte scan of the final string.
  - Guarantee the output ends with exactly one `"\n"` (append when absent; do not multiply). Match the
    normalized-source coordinate discipline (`raw.crlfToLf`); denormalization restores line endings at
    publish as it does today.
  - Whichever mechanism (trim the trivia `Doc` nodes as they are built, or a structured post-pass that
    knows token vs trivia spans via the renderer's `Mark`/source map — **not** a naive per-line
    `String` trim, which would re-commit the FMT001 corruption) — justify the choice against soundness
    and the existing `verbatim`/`Doc` model, and record the rejected alternative.
- **Rules (`LeanFmt/Rules.lean`).** Remove FMT001 and FMT002 from `ruleRegistry` and delete
  `trailingWhitespace`/`trailingWhitespaceFinding`/`finalNewline` and any now-unused helper
  (`isHorizontalWhitespace` if it has no other reader). FMT003/FMT004 (report-only source-tier security
  rules) are untouched, so a default `check`/`format` `requiredTier` stays `.source` and keeps the
  source-only fast shortcut. Confirm no other module imports the deleted rule symbols.
- **Test migration (the retirement's blast radius).** FMT001/FMT002 are the fixable-source vehicle across
  the persistent suite. Migrate each onto a surviving rule, preserving what the test actually proves:
  - `LeanFmtTest.lean`: the `extend-safe-fixes`/`extend-unsafe-fixes` applicability cases need a `.safe`
    and an `.unsafe` example — use a surviving `.safe` fix (a syntax rule, e.g. FMT010/FMT011/FMT013) and the
    `.unsafe` FMT014; the conflict-rejection case (FMT001 vs FMT013 overlapping edits) uses two surviving
    rules' overlapping edits or synthetic findings through the engine seam; the per-file-ignore and
    plan-projection cases use any surviving rule code.
  - `tests/suppression`, `tests/modes`, `tests/check`, `tests/imports`, `tests/service`: replace the
    FMT001/FMT002 vehicle with a surviving rule and its fixture; where a test asserted FMT001's
    *whitespace* behavior specifically, re-home it as a **formatter** assertion (the reflow now owns it).
  - Do **not** rewrite historical prerequisite-stack docs under `docs/projects/*/{results,notes,evidence,
    state}` — they are dated records. Only live code, live tests, `docs/adding-a-rule.md`, and `CLAUDE.md`
    references change.
- **New regression tests (`tests/printer/run.sh` or `tests/modes`, persistent).**
  - `format` with **no rule selected** trims trailing horizontal whitespace (interior and final line) and
    adds a final newline — the normalization is the reflow's, not a rule's.
  - An in-string-trailing-whitespace fixture (`"alpha   \n  beta"`) keeps its string value under `format`
    and under `fix` — the old FMT001 corruption cannot recur, and no rule reports it.
  - A verbatim tail (`#exit` / trailing garbage) still trims its trailing horizontal whitespace and gains
    a final newline as layout.
- Keep CLI presentation in `LeanFmt.Cli`; no `Environment`/`InfoTree`/`Position`/`FileMap` crosses into a
  rule; the plugin/library-glob boundary is untouched (the printer already lives in the application, not
  the rule closure).

## Plan

1. Write the printer regression tests (no-select ws/newline trim; in-string value preserved) — they fail
   against the current printer.
2. Extend the canonical trivia model to trim emitted trailing whitespace + guarantee one final newline,
   sound by construction; make the tests pass.
3. Retire FMT001/FMT002 from the registry and delete their defs; build; fix every reference.
4. Migrate the FMT001/FMT002-vehicle tests onto surviving rules, preserving each test's actual claim.
5. Re-run the full suite; grep for surviving FMT001/FMT002 references in live code/tests.

## Stop

- The formatter's ws/newline trim must be sound **by construction** — trivia only, never token/string
  bytes. If a test shows a string value changing under `format`, stop and fix the trim rather than
  narrowing the test.
- Do not leave FMT001/FMT002 dormant in the registry, and do not reintroduce a "format applies a rule
  fix" coupling — the ws/newline normalization is layout, unconditional, no `--unsafe-fixes` gate.
- Do not rewrite historical prerequisite-stack records. Do not give rules lifecycle authority.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the touched suites (`tests/printer/run.sh` if present,
  `tests/modes/run.sh`, `tests/check/run.sh`, `tests/suppression/run.sh`, `tests/imports/run.sh`,
  `tests/semantic/run.sh`, `tests/lossless/run.sh`, `lake exe lean-fmt-tests`).
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Grep to prove FMT001/FMT002 are absent from `LeanFmt/Rules.lean`'s registry and from live tests.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-11c-decouple-fix-format`.
- Run `git diff --check` and read all output before marking RDF-LAYOUT verified. Write
  `results/02-layout.md` with commands, outputs or evidence locators, decisions changed during execution,
  files changed, checks read, and remaining uncertainty; update `state/current.md` after reading the
  checks, then regenerate `state/next.md`.
