# RLF-BLOCKS — records and offside blocks: the invariant, and the two design-twices

This note discharges Plan steps 1 and 2 of prompt `09-reflow-blocks`: reproduce the invariant each
layout must preserve, then design the record break and the tactic re-indentation base twice each and
choose. Written *before* the implementation so the comparisons are on the record.

## 1. The invariant, reproduced (Plan step 1)

`evidence/04-coleq-break.txt` is phase 1's parse-preserving violation and the ground truth here. Its
lesson, and the offside grammar confirmed first-hand in `lean4/src` at v4.32.0:

- `sepByIndent p sep` = `withPosition $ sepBy (checkColGe >> p) sep (psep <|> checkColEq >>
  checkLinebreakBefore >> pushNone)` (`Lean/Parser/Extra.lean:202-204`). Elements sit at **colGe** the
  first element; two elements on consecutive lines with no literal separator are held together by
  **colEq + a line break**. This is `structInst`'s field separator and (via `sepBy1IndentSemicolon`)
  the tactic separator.
- `structInst := "{ " >> withoutPosition (… structInstFields (sepByIndent structInstField ", "
  (allowTrailingSep := true)) …) >> " }"` (`Lean/Parser/Term.lean:352-357`). The braces are declared
  **spaced** — `"{ "`, `" }"`. The `withoutPosition` switches off the *outer* saved position, but
  `sepByIndent` re-establishes its own `withPosition` **inside** it, so the fields are measured against
  the **first field's** column, not the brace's.
- `tacticSeq1Indented := sepBy1IndentSemicolon tacticParser` (`Term/Basic.lean:74-75`); `tacticSeq :=
  tacticSeqBracketed <|> tacticSeq1Indented` (`:83-84`), and `byTactic := " := " >> " by " >>
  tacticSeq` (`:185`) with **no external `checkColGt`** — contrast `tacticSeqIndentGt` (`:90-92`),
  which prepends `checkColGt "indented tactic sequence"`. "Delimiter-free indentation is determined by
  the *first* tactic" (`:81-82`); `by skip skip` does not parse, `by\n skip\n skip` does (`:57-65`).

The re-indent invariant `RLF-OFFSIDE` proved (`notes/06` §1) still governs: **a uniform per-line delta
`Δ = base − anchor` preserves every internal `colEq`/`colGt`/`colGe`, because it preserves every
pairwise column difference.** `reindentBlock` (`Printer.lean:363`) is that shift, token-interior lines
byte-exact. What `RLF-BLOCKS` *adds* to `RLF-OFFSIDE` is that it now **chooses** the base against real
constructs, and a chosen base introduces two hazards a uniform shift alone does not answer:

### 1a. The mid-line-anchor hazard — the counterexample, restated for a chosen base

`reindentBlock`'s anchor is the first token's column, and it shifts only lines that **begin** with a
structural newline. If the block's first token does **not** begin its own line — `by skip` with `skip`
sharing `by`'s line — then `skip` is the anchor but is never itself shifted (it has no preceding
structural newline), while a continuation `trivial` on the next line *is* shifted. The two fall out of
`colEq`. This is exactly `evidence/04`'s first break. **Safety condition A: a block is re-indentable
only when its first token begins its own line** (`firstOnLine`), so the anchor moves with the block.
When it does not, the block keeps its bytes.

### 1b. The external-anchor hazard — Δ is internal, the block's floor is not

A uniform shift preserves everything *inside* the block but says nothing about the block's relation to
an **enclosing** live column check. `byTactic`'s plain `tacticSeq` has none, so a `by` block that
begins its own line may be re-based to any column ≥ 0 and still parse (verified below by reparse). But
`tacticSeqIndentGt` (focus dots `·`, and the `do`/`let`/`where` bodies that use it) prepends
`checkColGt` against whatever position is saved when it runs, so its base has a **floor**: strictly
right of that saved column. `RLF-BLOCKS` cannot track `savedPos?` through the parser (fragile, and this
project's method is empirical reparse), so it adopts the same conservative rule `RLF-REFLOW` did:
**Safety condition B: the chosen base is never left of the block's original anchor** (Δ ≥ 0 for the
floor direction is not enough on its own — see §3's base choice), and **every re-indented output is
reparsed and compared token-for-token to the input; a block whose re-indent does not round-trip keeps
its bytes.** The reparse is the ceiling, not the argument (prompt Stop condition).

## 2. Design-twice A — the record (`structInst`) break

A `structInst` that fits the margin stays one line: `{ x := 1, y := 2 }` (braces spaced per the
declaration, fields `", "`-joined — the flat form is byte-identical to canonical source, as
`RLF-NOTATION`/`RLF-REFLOW` require). When it exceeds the margin, how do its fields break?

### Design A1 — one field per line (chosen)

    { x := 1,
      y := 2,
      z := 3 }

Every field on its own line at one shared column. **This is the align-free engine's natural output**:
`group ("{ " ++ nest N (field₁ ++ "," ++ line ++ field₂ ++ …) ++ " }")` breaks every `line` together
(P1, `RLF-REFLOW` §3), and because `nest` is relative to the command root (`notes/07` §1.3), every
broken field lands at the **same absolute column** — which is exactly `checkColEq`, the separator the
grammar accepts between two fields on consecutive lines. The colEq the record needs is not something
the layout must arrange; it **falls out of** breaking at a fixed nest base. The trailing `,`
(`allowTrailingSep := true`) is kept so each field line is self-contained.

### Design A2 — fill to margin (rejected)

    { x := 1, y := 2,
      z := 3, w := 4 }

Pack fields until the margin, wrap. Rejected for `RLF-REFLOW` §3's reasons (diff instability,
idempotence fragility) **plus one specific to records**: a wrapped field must be `colEq` the *first*
field, but a fill packs the first line's fields at descending columns, so the wrap column (first
field's) is a column no later same-line field sits at — the layout has to compute and hold it
explicitly, where A1 gets it free from the nest base. Fill trades the grammar-given colEq for a
computed one, against every axis the prompt names.

**Decision: A1.** Records reuse `RLF-REFLOW`'s β machinery (gap-as-`line`, all-or-nothing) with two
deltas: the bracket pair takes its declared spacing, and the inter-field separator is the declared
`", "` whose flat form is a comma-space and whose break form is `",\n<base>"`.

## 3. Design-twice B — the offside re-indentation base

For a multi-line offside block (tactic/`do`/`where`/`let` body) that begins its own line (§1a), to what
base does `reindentBlock` re-index it?

### Design B1 — canonical base = enclosing construct's indent + one level (chosen)

Re-index the block so its first token lands at `commandIndent + 2·depth` — the indentation a canonical
document gives that nesting level, independent of what the author typed. `def f :=\n      by\n        e`
(over-indented) becomes `def f :=\n  by\n    e`. This is Black's model: indentation is a function of
nesting depth, not of the author's whitespace.

- **Parse safety:** the shift is uniform (internal colEq/colGt/colGe preserved), the first token is
  line-leading (§1a), and the result is **reparsed and compared** before it is kept (§1b). A base that
  breaks the parse is discarded and the block keeps its bytes — so B1 can never *ship* a broken parse;
  the worst case is a no-op.
- **Idempotence:** a fixpoint by construction — the canonical base is a pure function of nesting depth,
  so re-formatting recomputes the same base and the second pass is byte-identical.
- **Diff stability:** renaming or reflowing the parent does not move the block relative to it; the block
  is always `+2` from its construct, so an edit above it does not reflow it.

### Design B2 — preserve the author's base (rejected)

Keep the first token's column; re-index only to repair *internal* drift (a continuation line whose
indentation disagrees with its siblings). On well-formed input this is the **identity** — a block whose
internal columns already parse has no drift to repair — so B2 canonicalizes nothing. A formatter that
leaves indentation as it found it is not formatting it; B2 is `RLF-OFFSIDE`'s own null case (re-index to
the anchor is the identity, `results/07`) dressed as a policy. Its only advantage over B1 is that it
cannot change a parse — but B1 cannot *ship* one either, because of the reparse gate, so B2 buys nothing
for the cost of doing nothing.

**Decision: B1**, gated by §1a (line-leading), §1b (reparse), and the conservative byte-fallback the
prompt's Stop condition mandates. The corpus is already canonical, so B1 is a **no-op on every real
module** (the sixth—now eighth—consecutive no-op the phase-2 notes predicted); the fixtures carry the
proof it changes a byte, exactly as every prior layout's did.

## 4. Scope, and what stays conservative

- **In scope:** a `structInst` that is single-line-over-margin (A1 break) or single-line-fits (flat,
  canonical brace spacing); an offside block (tactic/`do`/`where`/`let` body) whose first token begins
  its own line and whose B1 re-index round-trips (Plan names all four).
- **Out of scope, bytes kept:** a `structInst` whose *horizontal collapse* would be needed (multi-line
  → one-line) — that is the `sepByIndent`-saves-inside hazard `RLF-EXTENSIONS` deferred
  (`state/current.md`, "Horizontal collapsing is not unconditionally safe"), unchanged here. A block
  whose first token is mid-line (§1a). Any block whose B1 re-index fails to reparse (§1b). A block
  holding a comment that the re-index would move onto a different column relative to code — the comment
  must survive **unmoved** in its own line's shift, which `reindentBlock` already guarantees for
  structural lines, but a comment *interior* to a token is byte-exact and a comment on its own
  structural line shifts with the block (its relative column preserved), which the fixture pins.

## 5. Verification plan (Plan step 4)

- **Parse-preservation:** reparse every re-indented / broken output through `__analyze-exact` and
  compare token streams to the input's, over synthetic fixtures with **deliberately non-canonical
  indentation** and **over-margin records**, at margins 0/1/40/80/100/1000.
- **Idempotence gate:** `format (format x)` byte-identical to `format x` at each margin.
- **Comment survival:** a fixture with a comment inside a block asserts the comment's bytes survive and
  its line moves with the block (relative column preserved), and a fixture with a nested block asserts
  the inner block re-indents with the outer.
- **colEq spot-check:** a broken record's fields and a re-indented tactic block's tactics share one
  column, read off the output (as `RLF-OFFSIDE`'s test reads colEq off the re-indented block).
- **Performance line:** `results/09` carries workload, machine, toolchain, commit, wall time, peak RSS.
