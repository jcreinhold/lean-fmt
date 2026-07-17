# 06 — The offside re-indent primitive: design it twice

`RLF-OFFSIDE` (prompt 07) needs one capability: emit a multi-line block at a **chosen canonical base
column** while preserving every internal `colEq`/`colGt`/`colGe`/`lineEq` relationship, so the parse is
unchanged. This note writes the two candidate designs out, compares them on the axes the prompt names,
and chooses. It is the design-twice the roadmap and `notes/05-reflow-architecture.md` §3 defer here.

## 1. What a correct re-indent must preserve — reproduced, not assumed

`evidence/04-coleq-break.txt` is phase 1's parse-preserving violation, and it is the ground truth this
capability is built against. Two breaks, one lesson:

- **The first break** (`tacticSeq1Indented`): collapsing `(id     True)` → `(id True)` on line 3 moved
  `trivial` on line 4 left of the `by` block's offside column, and the reparse failed —
  `unexpected identifier; expected command`. A gap edit on one line changed a **column relationship
  across lines**.
- **The second break** (custom `withPosition(term colEq term)`): the same, but the offside check is a
  *user's* `colEq` that creates no node of its own, so no census of kinds can see it —
  `expected checkColEq` on reparse.

Lean's offside separators (`Lean/Parser/Extra.lean:199-208`, `manyIndent`/`sepByIndent`) and the column
combinators (`colEq` = same column, `colGt` = strictly right, `colGe` = at-or-right, `lineEq` = same
line) all constrain the **relative** column of tokens on different lines. The invariant a correct
re-indent must hold is therefore exact and simple:

> Shift every structural line of the block by the **same** column delta `Δ = base − blockBaseColumn`.
> A uniform shift preserves every pairwise column difference and every column equality, so every
> `colEq`/`colGt`/`colGe` inside the block still holds. `lineEq` is untouched because re-indent never
> moves a token to another line. The one thing that must **not** shift is the interior of a token that
> spans lines — a block comment body or a multi-line string literal — because that interior is the
> token's *value*, not layout (`Doc.lean:62-68`, the whole reason `verbatim` exists).

So the primitive is a uniform per-line leading-whitespace shift that skips continuation lines interior
to a multi-line token. That is the specification; the property test (§4) is what proves an implementation
meets it, because "a uniform shift preserves relative columns" is an argument and the ceiling is the
reparse.

## 2. Design A — a new `Doc` constructor `reindent (base : Nat) (block : Doc)`

Add a constructor to the engine sitting between `verbatim` (never re-indented) and `nest`+`hard`
(rebuilds each line): `reindent` re-bases a block's lines to `base`, preserving their relative
indentation.

- **`fits`**: a `reindent` block spanning lines can never be flat — identical to `verbatim`/`hard`'s
  case (`Doc.lean:174-177, 185-188`).
- **`go`**: emit the block's text with each line's leading whitespace shifted by `Δ`, then set `col` to
  the last line's width, as `verbatim` does (`:205-207`).
- **`wellFormed`**: a new clause, and the render linear-bound argument (`RLC-FINAL`'s owned hole,
  `:160-164`) must be re-stated to cover the new width-consuming path.
- **Cost**: widens the engine's *committed* surface. `Doc.lean:34-43` states plainly that adding a
  constructor **reopens `RLC-SPEC`**, not merely extends the type — the constructor set is the spec.
  `ruff-02`'s state and results reopen; its Doc/engine suite reruns; the linear-bound guarantee must be
  re-argued for the new case.
- **Benefit claimed**: the offside rule lives in the engine once, provably; callers stay declarative
  (`reindent base block`).

## 3. Design B — a shared printer-side `reindentBlock` over the existing `verbatim`

Keep `Doc` frozen. The printer already emits every offside block as `.verbatim (tree.tokenSpanText …)`
(`Printer.lean:591, 1039`): the bytes and their newlines pass through, and `go`'s `verbatim` case
(`Doc.lean:205-207`) emits them **without applying the ambient indent** — that is exactly a lossless
multi-line passthrough. Re-indent is then a single source→source transform feeding that primitive:

    private def reindentBlock (base : Nat) (block : «lines + which are token-interior») : String

computes `Δ = base − blockBaseColumn` and rewrites each structural line's leading whitespace by `Δ`,
leaving multi-line-token interiors byte-exact, then hands the result to the existing `.verbatim`. One
helper, called by every construct `RLF-BLOCKS` will lay out (records, tactic/`do`/`where`/`let`).

- **Cost**: the offside logic lives in the printer, and needs the block's token/trivia structure to know
  which lines are token-interior — line logic the engine does not provide. `notes/05` §3 names this: "may
  duplicate line logic."
- **Mitigation**: it is **one** shared helper, not per-construct code. Adding a construct in `09` is "call
  `reindentBlock`," the same one-line change Design A's "wrap in `reindent`" would be. The duplication
  `notes/05` worried about is duplication only if each construct re-derives the shift; a shared helper
  has none.
- **Benefit**: `Doc` stays frozen, `RLC-SPEC` is not reopened, and `render`'s linear-bound guarantee is
  untouched because **no new engine path exists** — `reindentBlock` runs before the string reaches the
  engine, and the engine sees a `verbatim` it already handles.

## 4. The comparison, on the prompt's axes

| axis | A (engine constructor) | B (shared printer helper) |
|---|---|---|
| engine surface widened | **yes** — reopens `RLC-SPEC` (`Doc.lean:34-43`) | **no** — `Doc` frozen |
| where the invariant is provable | engine, but linear-bound must be re-argued | printer; engine guarantee untouched |
| change-amplification (new offside construct) | wrap in `reindent` | call `reindentBlock` — same |
| caller cost | declarative constructor | one helper call — same |
| faithfulness to offside semantics | uniform Δ shift | uniform Δ shift — **identical** |

The two designs are **equal on faithfulness, caller cost, and change-amplification**. They differ on one
axis that matters: A widens the engine's committed surface and forces the linear-bound guarantee to be
re-argued; B does neither.

## 5. The decision: B, and `ruff-02` is **not** reopened

The deciding observation is that **re-indent is width-independent**. The engine exists to make one
decision — flat versus broken, by a bounded fit test against the margin (`Doc.lean:34-43`, "the only
choice in the algebra is flat versus broken"). A re-indent has no such decision: a multi-line block is
always broken, exactly like `verbatim`, and the base is *chosen absolutely* (§3's rejection of `align`),
not measured against a width. So re-indent needs nothing the engine uniquely provides — no fit test, no
dynamic column, no margin. Putting it in the engine (Design A) pulls a width-independent pure transform
into the width-driven core, reopening the spec for a capability the engine does not make any decision
about.

Design B expresses re-indent as exactly what it is: a source→source transform feeding the `verbatim`
primitive that `RLC-IMPL` already built for lossless multi-line passthrough. The engine stays frozen,
its linear-bound guarantee is untouched, and the one honest cost — B needs token structure to skip
token-interior lines — is a cost A pays too (its `go` case would need the same information to avoid
shifting a string literal's body, and the engine does not have it, which is itself an argument that this
logic does not belong in the engine).

**This also honors a Stop condition directly.** The prompt says: "If `ruff-02` is reopened, its `render`
linear-bound guarantee must survive; stop rather than trading it for the constructor." B does not reopen
`ruff-02` at all, so there is nothing to trade.

## 6. What B commits prompt 07 to build

1. `reindentBlock` (in `Printer.lean` or a small sibling): uniform Δ shift of structural line indents,
   token-interior lines byte-exact, Δ from a chosen `base`.
2. A **property test**: for a representative offside fixture, re-indent to several bases, reparse each
   via the fresh frontend, and assert the token stream is identical across all of them
   (`notes/05` §4.1). The bases include one that shifts left and one that shifts right of the original.
3. A `verbatim`-interior check: a fixture whose block contains a multi-line string literal / block
   comment, re-indented, with the interior asserted byte-exact.
4. **No real record or tactic is re-laid-out here** — that is `09`. This prompt delivers and proves the
   *capability* in isolation, so `09` consumes a proven primitive.

Open question carried to the implementation: `blockBaseColumn` — is it the first token's column, or the
minimum column across the block's structural lines? The first-token column is what an offside block's
own anchor is (Lean measures the block against where it starts), so that is the candidate; the property
test at multiple bases is what will catch it if a block has a line left of its anchor that a first-token
base would push negative.
