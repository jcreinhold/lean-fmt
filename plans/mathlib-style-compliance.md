# Plan: fix lean-fmt output that trips mathlib's style linters

## Context

Scope confirmed with the user: exactly the three root causes below — no broader linter sweep.

Running lean-fmt v0.1.7 over kan-proofs (1473 files) introduced three classes of violations of mathlib's style linters,
which kan-proofs enables via `linter.mathlibStandardSet` (`lakefile.lean:41`, pulls in `linter.style.longLine` and
`linter.style.cdot`). The formatted tree has since been reverted; all evidence below was captured from `git show
HEAD:<file> | lean-fmt diff --stdin-filename <file>` replays, which reproduce every class.

Confirmed scale (formatted tree vs HEAD):

- **Isolated cdot `·`**: 0 at HEAD → 449 occurrences in 194 files after formatting.
- **Long lines**: the user's build showed `linter.style.longLine` warnings in `Monoid/Integral.lean:210`,
  `Monoid/Saturated.lean:73`, `Group/Submonoid/Localization.lean:59` — all three are doc comments inside
  `@[to_additive …]` attributes (see class 3). Raw byte counts (10623 vs 3665) are unicode-inflated; the linter counts
  *characters* (`FileMap.toColumn` iterates char-wise), and char-accurate diff replay shows the attribute doc-comment
  class is essentially the only introduced long-line source.
- **Vertically broken imports**: `public import <long module name>` became `public\nimport\n<module name>`; the bare
  module-name line (>100 chars) is *not* exempt from the longLine linter (`isImport` only exempts lines starting with
  `import`/`public import`, and the linter checks header lines at EOI).

## Root causes (all reproduced with minimal examples)

### 1. Isolated cdot — `LeanFmt/Formatter/NativeLayout.lean`

`· calc …` (and `· exact (…)`, any multi-line tactic block) comes back as `·` alone on a line with the tactic indented
below — even when `· calc` fits on the line. Mathlib's cdot linter flags any `cdotTk` whose trailing whitespace contains
a newline.

The syntax is `syntax (name := cdot) cdotTk tacticSeqIndentGt : tactic` (`Init/NotationExtra.lean:322`). Its
auto-generated category formatter puts a soft break between `·` and the tactic sequence; when the block can't stay flat,
that break fires and isolates the `·`. lean-fmt has **no** cdot-aware boundary handling: `collectIndentedSequenceStarts`
deliberately skips the cdot carrier (only one terminal precedes the list, so `delimiterIntervenes` says no), so the core
formatter's break survives the transform untouched.

### 2. Broken imports — `LeanFmt/Formatter/Command.lean: importDocument`

Header tokens are joined with a breakable `Doc.line " "` inside `Doc.group`. A long import (`public import` + 80+-char
module name) overflows the group and every token lands on its own line. This contradicts lean-fmt's own style contract
(`docs/style.md`, `header.imports`: "ordered imports at the left margin, one import statement per line") and achieves
nothing — an import cannot be shortened, which is exactly why mathlib's linter exempts whole import lines.

### 3. Attribute doc-comment re-indentation — `NativeLayout.lean` (no attribute awareness)

`@[to_additive /-- multi-line doc -/]` (and any attribute carrying a doc comment) is laid out in the canonical broken
form with the entry nested ~6 columns deep:

```
@[to_additive
      /-- The **integralization** … universal        ← was exactly 100 chars at col 0 → now 106
map … -/
    ]
```

A doc-comment token is multi-line, so the group can never be flat; the broken form's nesting pushes the fixed first
payload line past 100. The comment contract ("comments keep exact payload bytes; reindentation changes surrounding
layout, never text inside a token") forbids reflowing the payload, so the only legal fix is a shallower placement for
the entry.

## Approach

### Fix 1: join the cdot boundary (`NativeLayout.lean`)

Add a collector `collectCdotStarts` that finds every `cdotTk` atom in *tactic* syntax (not `Term.cdot` — `(· + ·)` is
unrelated) and emits the source position of the first terminal after it as `BoundaryLayout.flat`, flattening the
cdot→first-token span so no break is left behind. This mirrors the existing `collectGuardBailouts`/`joined` mechanism
exactly ("a collector answers *where*, `BoundaryLayout` answers *what*" — `NativeLayout.lean:2092`), and composes with
`collectOffsideConstraints` for the reparse check.

- Joining only the **first token** (`· calc`, `· exact`) is always safe: tactic heads are short atoms; the rest of the
  group can still break normally (`· exact\n      (longTerm)`).
- Continuation indentation is unchanged (steps stay at their current nest), e.g. `· calc\n      n = n := h`.
- Edge cases to cover in fixtures: nested cdots (`· · calc`), cdot + bracketed sequence, cdot with a comment before the
  tactic, `case h =>` (deliberately *not* joined — mathlib accepts a broken case arrow and the linter doesn't flag it),
  `Term.cdot` in terms (untouched).

### Fix 2: unbreakable import rows (`Command.lean`)

In `importDocument`, replace the inter-token `Doc.line " "` with an unbreakable `Doc.text " "`; comment-forced
boundaries keep `Doc.hard`. Import rows then always render as one line; over-100 module names overflow flat, which the
style contract already permits ("registry-owned opaque atom may exceed it") and mathlib's `isImport` exemption covers.

### Fix 3: attribute doc-comment placement (`NativeLayout.lean`)

**Confirmed with the user.** When an attribute-list entry begins with (or is) a multi-line doc-comment token, place that
entry — and the closing `]` — at the attribute list's own indentation instead of the nested depth, i.e. the hand-written
form kan-proofs HEAD already used:

```
@[to_additive
/-- The **integralization** … (≤100 chars) -/
]
```

Rationale: the payload was authored to fit at that column and cannot shrink, so minimum legal indent is the only
width-safe canonical placement. Concretely this is a shape rule beside the existing
`collectDocCommentRanges`/`BoundaryLayout.dedented` machinery: detect doc comments whose owner is an `attrInstance`
inside `Lean.Parser.Term.attributes`, and dedent the entry boundary (and the `]` boundary) to the `@[` column. Scoped to
attribute entries only — the general "never indent fixed multi-line payload past the width" principle stays a stated
invariant, not new machinery, until a second construct needs it (module-design: generalize the interface, not unused
functionality).

(Alternative considered and rejected: keep nesting and let the payload overflow — the linter fires; reflow the doc text
— violates the exact-payload contract.)

## Files to modify

- `LeanFmt/Formatter/NativeLayout.lean` — `collectCdotStarts` + wire into `boundaryStarts` (Fix 1); attribute
  doc-comment dedent rule (Fix 3).
- `LeanFmt/Formatter/Command.lean` — `importDocument` separator (Fix 2).
- `docs/style.md` — record the two new layout decisions (cdot joins its first token; doc-bearing attribute entries sit
  at the `@[` column; imports never break) — matrix rows in `tests/fixtures/style/matrix.json` if the policy IDs require
  it.
- Test fixtures: `tests/fixtures/native-layout/` (cdot cases), a header/import fixture for long import rows, an
  attribute/doc-comment fixture (declaration- or command-formatter suite), including regression cases replayed from the
  kan-proofs failures (`FinitePresentation.lean` `· calc`, `Monoid/Integral.lean` `to_additive` doc, `KanProofs.lean`
  long imports).

## Reuse

- Boundary-correction pipeline: `boundaryStarts` assembly at `NativeLayout.lean:2102-2110`; `collectGuardBailouts`
  (`:848`) is the template for "join this span"; `BoundaryLayout.flat` consumption is already implemented by the
  transform.
- `collectDocCommentRanges` (`:1045`) already finds doc comments; the attribute rule adds an owner test (`attrInstance`
  ancestor), not a new walk.
- `Trivia.decorate*` helpers in `Command.lean: importDocument` are untouched — only the separator changes.
- Repro/verification harness: `git show HEAD:<f> | .lake/build/bin/lean-fmt diff --root <proj> - --stdin-filename <f>`
  replays any kan-proofs file without writing it.

## Steps

- [ ] Fix 2 (imports) first — smallest, self-contained in `Command.lean`; add a long-import
      fixture.
- [ ] Fix 1 (cdot): implement `collectCdotStarts`, wire as `BoundaryLayout.flat` + span
      flatten; verify the minimal repro (`· calc` stays joined; steps keep their indent) and
      idempotence.
- [ ] Fix 3 (attribute docs): implement the `attrInstance`-owned doc-comment dedent; verify
      the three kan-proofs warning sites replay clean.
- [ ] Add fixtures/matrix rows + `docs/style.md` entries for all three decisions.
- [ ] Run lean-fmt's own suites (`lake build`, the fixture suites) — no regressions.
- [ ] Downstream verification on kan-proofs (below).

## Verification

1. lean-fmt repo: `lake build` + full test suite green.
2. Replay the known failure sites and assert the diffs no longer contain the violation:
   - `FinitePresentation.lean` — no `^+  ·$` lines; `· calc` joined.
   - `Monoid/Integral.lean`, `Monoid/Saturated.lean`, `Group/Submonoid/Localization.lean` — no char-length >100 added
     lines.
   - `KanProofs.lean` — every import stays one line.
3. Whole-repo char-accurate audit: for every kan-proofs `.lean` file, replay the format via stdin diff and count (a)
   isolated-cdot added lines, (b) added lines >100 *characters* (python `len`, not bytes). Both counts must be 0 (or
   equal to HEAD's own count).
4. Ground truth: fresh `lean-fmt format --root .` run on kan-proofs, then `lake build` — zero `linter.style.longLine` /
   `linter.style.cdot` warnings versus the pre-fmt baseline.
