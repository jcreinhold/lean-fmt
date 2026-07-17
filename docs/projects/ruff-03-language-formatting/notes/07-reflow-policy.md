# RLF-REFLOW — where a break is legal, and the break policy (design-twice)

This note discharges Plan steps 1 and 2 of prompt `08-reflow-expr`: characterize where a line break is
parse-legal, then design the break policy twice and choose. It is written *before* the implementation so
the two design-twice comparisons the prompt asks for are on the record, not reconstructed after the code.

## 1. Where a break is legal (Plan step 1)

Three facts, each confirmed first-hand in the toolchain at `/Users/jcreinhold/Code/lean4/src`, govern
every break this prompt emits.

### 1.1 The argument column constraint is real but conditional

`Lean/Parser/Term.lean:889-892`:

    def argument :=
      checkWsBefore "expected space" >>
      checkColGt "expected to be indented" >>
      (namedArgument <|> ellipsis <|> termParser argPrec)

and `app := trailing_parser:leadPrec:maxPrec many1 argument` (`:897`). So every argument of a function
application is guarded by `checkColGt`. But `checkColGt` is **not** unconditional. `checkColGtFn`
(`Lean/Parser/Basic.lean:1503-1510`):

    def checkColGtFn (errorMsg : String) : ParserFn := fun c s =>
      match c.savedPos? with
      | none => s                                    -- no active withPosition ⇒ no-op
      | some savedPos =>
        if pos.column > savedPos.column then s else s.mkError errorMsg

The check compares the token's column against the **nearest enclosing `withPosition`'s** saved column,
and is a *no-op when no `withPosition` is active*. Whether it bites a given app therefore depends on
context (a top-level `def` value versus an argument inside a `by`/`do`/`match` that saved a position).

### 1.2 The conservative rule that is always safe

Rather than track `savedPos?` through the parser (fragile, and the project's methodology is empirical
reparse, not parser-source tracing), the printer adopts the rule that is safe under *both* branches:

> **Every broken continuation lands at a column strictly greater than its construct's head.**

If `savedPos? = none`, any column parses (the check is a no-op). If `savedPos? = some p`, then `p.column`
is set by a `withPosition` that wraps something starting at or before the head, so `p.column ≤ head.col`;
a continuation strictly right of the head is `> head.col ≥ p.column`, satisfying the check. The rule is
sufficient for both branches, and — per the prompt's Stop condition — it is **verified by reparse at
every margin, not argued**. The same rule covers `checkColGe`/`checkColEq` conservatively: a continuation
strictly right of the head is never left of, nor equal to, a reference at or left of the head.

### 1.3 The engine is align-free, so "strictly right of head" forces move-the-value-down

The engine (`Doc.lean`) has no `align`/`pushAlign` — `notes/05` §3 rejected column-alignment and
`Doc.lean:71-73` records the decision. `render w d = go w [.doc 0 .brk d] 0 0 "" #[]`
(`Doc.lean:244-245`) starts at indent `i=0`, column `0`; `nest j` sets `i := i+j` (`:209`); a broken
`line` emits `newlineIndent i` — a newline plus exactly `i` spaces (`:216-218`). **`nest` is relative to
`i`, which is `0` at the command root and grows only through `nest` — never to the current column.**

The consequence is decisive. Consider breaking the arguments of `def foo := f a b c` *in place*, keeping
`f` after `:=`:

    def foo := f
      a            -- lands at column `nest`, i.e. i=0+nest — NOT at f's column

For the continuation to land right of `f`, `nest` would have to exceed `f`'s column (here 11), which the
printer cannot know without measuring the rendered prefix — i.e. without `align`. So in-place argument
breaking is **not expressible** in this engine. The only align-free layout that puts continuations right
of the head is to break *before* the construct so its head starts a fresh line at a known `nest` base,
then nest the continuations one level deeper:

    def foo :=
      f            -- head at column 2 (the value's nest base)
        a          -- args at column 4 = 2+2 > 2  ✓ checkColGt
        b
        c

Because the command root renders at `i=0`, the engine's *relative* nest yields *absolute* columns
(2, then 4), and each level adds a fixed 2 — so a child is always ≥2 columns right of its parent's
line-start, and `checkColGt` holds structurally. This is also Black's canonical shape (explode the RHS
onto its own indented block); **the architecture and the house style agree, and the agreement is
forced, not chosen.**

## 2. Design-twice A — where the break opportunity lives

A break turns a gap between two parts (`shell→value`, `function→argument`, `operand→operator`) from a
horizontal separator into a vertical one. Two substantively different places can own that decision.

### Design α — term-local groups, gaps stay verbatim

`termDoc` wraps each breakable node in `group (head ++ nest 2 (…))` and keeps `gapDoc`'s existing output
(a `.text` separator or `.verbatim raw`) between parts. The value's preceding gap (the bytes between the
shell's `:=` and the value's first token) is emitted by `Tree.command`'s claim-stitching as a
`.verbatim " "` and is *outside* the value's group.

- **Abstraction boundary:** per-term; the gap between shell and value is not the term's to touch.
- **Fatal flaw:** when the value's group breaks, the preceding `.verbatim " "` has already been emitted —
  producing `def foo := ` **with a trailing space**, then a newline. Trailing whitespace is a defect
  (`git diff --check` fails it), and the space cannot be retracted once emitted. α cannot cleanly move a
  value down because the separator it must replace lives in a different claim.

### Design β — the breakable gap *is* a `line` (chosen)

The break opportunity replaces the gap. A breakable gap emits `Doc.line sep` — whose **flat** spelling is
the declared separator (from `RLF-NOTATION`, or the shape model's separator) and whose **break** spelling
is `newlineIndent i` — inside an enclosing `group`, with `nest` setting the continuation column. This is
the Wadler/Leijen idiom, and it is exactly what the engine's `line` constructor was built for
(`Doc.lean` `line (flat : String)`, flat form on `.flat`, `newlineIndent i` on `.brk`, `:214-218`).

    group( shellText ++ nest 2 (line " " ++ valueDoc) )
    -- flat:  "def foo := f a b c"
    -- break: "def foo :=\n  f\n    a\n    b\n    c"

- The gap's flat form is the *declared spacing* — β **consumes `RLF-NOTATION`** directly (the prompt's
  Target: "Operators break at the notation's declared spacing"). `gapDoc`'s `some separator` case becomes
  `.line separator` when the gap is breakable, instead of `.text separator`.
- No trailing space: the space is the `line`'s flat form and simply is not emitted when the line breaks.
- The head lands at the `nest` base (§1.3), so continuations are `checkColGt`-safe by construction.

**Decision: β.** α is disqualified by the trailing-space defect, which is not a rough edge but a
parse/lint failure it cannot avoid. β also *deepens* `gapDoc` — one call site already decides "declared
separator vs keep-bytes"; it now decides "flat separator vs *breakable* separator vs keep-bytes" behind
the same signature, rather than spreading break logic across `termDoc` and the claim-stitcher.

## 3. Design-twice B — the break policy for an argument list

When a construct breaks, how many of its gaps break? The prompt names this explicitly:
"all-or-nothing break of an argument list versus fill-mode."

### Policy P1 — all-or-nothing (Black-style; chosen)

A construct's `group` either fits flat (no gap breaks) or breaks **every** gap:

    def foo :=
      f
        argument_one
        argument_two
        argument_three

One `group` per construct; when it does not fit, all its `line`s break together (the engine breaks a
group as a unit). Nested constructs are independent groups, so an inner app may stay flat while its
enclosing operator breaks.

- **Diff stability:** adding or removing one argument changes one line; the other arguments keep their
  column and their line. A reviewer sees a one-line diff.
- **Idempotence:** the broken shape is a fixpoint (§4) — re-formatting reproduces it byte-for-byte.
- **Reparse safety:** every continuation is at a single fixed column (head+2), the simplest column
  relation to keep `checkColGt`-true.

### Policy P2 — fill-mode (rejected)

Pack as many arguments per line as fit the margin; wrap when the next would exceed it:

    def foo :=
      f argument_one argument_two
        argument_three

- **Diff instability:** adding one early argument reflows the *fill* — every subsequent argument can jump
  lines. A one-token change produces a multi-line diff, the failure mode that made Black abandon fill.
- **Idempotence:** fragile — a fill boundary sits exactly at the margin, so a one-column change in an
  upstream construct reflows it; proving `format∘format = format` means proving the fill is stable under
  its own output, a strictly harder obligation.
- **Reparse:** continuations land at varied columns (still right of head, so still legal), but the
  varied columns buy nothing here and cost the two properties above.

**Decision: P1.** Fill-mode's only advantage is vertical compactness, which a 100-column margin rarely
needs and which the prompt's own comparison axes (diff stability, idempotence, reparse safety) all weigh
against. P1 is Black's choice for the same reasons.

## 4. Scope, and why it is honest rather than partial

`Tree.mayCollapse` (`Printer.lean:1037-1043`) already gates term respacing to **single-line commands**:
a command whose first and last tokens share a line, with only whitespace after. Multi-line commands keep
their bytes — the conservative parse-safe choice `RLF-EXTENSIONS` installed (`evidence/04-coleq-break.txt`
is the `theorem` a naive collapse would have broken). RLF-REFLOW lives exactly inside `mayCollapse`:

- **In scope:** a single-line command whose one line exceeds the margin. Reflow breaks it into several
  lines. This is the whole of "break app/operator/binder/match" — turning one over-wide line into a
  broken block.
- **Out of scope (→ prompt 09, RLF-BLOCKS):** a command *already* spanning multiple lines. Its bytes are
  kept. Re-laying-out multi-line block constructs (records, tactic/`do`/`where`/`let`) is what consumes
  the `RLF-OFFSIDE` primitive, and `09` owns it.

This division is not a shortcut: it is the same `mayCollapse` boundary phase 1 drew for parse-safety, now
carrying breaking as well as collapsing. **Idempotence falls out of it.** First format: a single-line
over-margin command breaks into a multi-line output `M`. Second format: `M` is now multi-line, so
`mayCollapse` returns `false`, and `M` is kept byte-for-byte. Hence `format (format x) = format M = M =
format x` — idempotence holds *because* the broken output leaves the `mayCollapse` domain, and does not
require the breaker to be a fixpoint of itself on a re-entrant path.

## 5. Margin

Default **100** (`notes/05` §5, decided with the user 2026-07-17; mathlib's own text linter). It stays a
required `format` parameter (`Printer.lean:1708-1710` — "required rather than defaulted … enters cache
identity"); `08` sets the *default* at the callers/tests, not inside `format`. No caller outside tests
hardcodes a different value silently (Plan step 5 audit).

## 6. Verification plan (Plan step 4)

- **Parse-preservation:** reparse every broken output through `__analyze-exact` and compare token streams
  to the input's, at margins **0, 1, 40, 80, 100, 1000** — the same fresh-frontend reparse the
  `RLF-OFFSIDE` property test uses, now over synthetic *over-margin* fixtures (Plan: "goldens that exceed
  the margin … assert the formatter changed lines").
- **Idempotence gate:** `format (format x)` byte-identical to `format x` at each margin.
- **checkColGt spot-check:** the head/continuation column relation (head at base `b`, args at `b+2`) read
  off the broken output, as `07`'s test reads `colEq` columns off the re-indented block.
- **Performance line:** `results/08` carries workload, machine, toolchain, commit, wall time, peak
  aggregate RSS — the first prompt to trigger real `group` fit-test measurement.
