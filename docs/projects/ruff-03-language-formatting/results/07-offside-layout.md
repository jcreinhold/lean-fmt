# RLF-OFFSIDE — results

## What shipped

The offside re-indent primitive `RLF-BLOCKS` (prompt 09) will consume, delivered and **proven in
isolation** — no real record or tactic is re-laid-out here. Three functions in `LeanFmt/Printer.lean`
and seven property-test checks in `tests/printer/run.sh`:

- **`Tree.reindentBlock`** — the primitive. Emit a token span `[lo, hi]` with every *structural* line's
  indentation shifted by one constant delta `Δ = base − anchor`, `anchor` = the first token's column.
  Lines interior to a multi-line token (a block comment body, a multi-line string literal) are byte-exact.
- **`Tree.reindentSpanInModule`** — splice a re-indented block back: replace the first token's line
  indentation so it lands at `base`, emit the block from there, keep every byte before the block's line
  and after its last token. This is how a caller *applies* the primitive.
- **`Tree.firstIndentedBlock`** — a fixture's-eye block finder (first line-starting token indented past
  column 0, through the last token), so the capability can be tested without prompt 09's construct-aware
  selection. Plus the `printer-reindent` test entry point that drives all three.

The engine (`Doc`) is untouched. `ruff-02` is **not reopened**.

## The design-twice, and the one fact that decided it

`notes/06-offside-primitive.md` writes both designs out and compares them on the prompt's axes. **Design
A** adds a `Doc` constructor `reindent base block`; **Design B** is the printer-side `reindentBlock`
feeding the existing `verbatim`. They tie on faithfulness to Lean's offside semantics (both are a
uniform Δ shift), on caller cost, and on change-amplification (A wraps in a constructor, B calls a shared
helper — one line either way). They differ on exactly one axis: **A widens the engine's committed
surface** — `Doc.lean:34-43` states adding a constructor reopens `RLC-SPEC` — and forces the render
linear-bound guarantee to be re-argued; **B does neither.**

The deciding observation is that **re-indent is width-independent**. The engine exists to make one
decision — flat versus broken, by a bounded fit test against the margin. A re-indent has no such
decision: a multi-line block is always broken, exactly like `verbatim`, and the base is *chosen
absolutely* (`notes/05` §3's rejection of `align`), not measured against a width. So re-indent needs
nothing the engine uniquely provides. Design A would pull a width-independent pure transform into the
width-driven core for a capability the engine makes no decision about. **Decision: B.** This also honors
the prompt's Stop condition directly — "if `ruff-02` is reopened, its `render` linear-bound guarantee
must survive" — by not reopening it at all.

## The correctness the naive version gets wrong

`evidence/04-coleq-break.txt` is phase 1's parse-preserving violation, and it is the exact shape a wrong
re-indent reproduces. Lean's offside checks (`colEq`/`colGt`/`colGe`, `Lean/Parser/Extra.lean:199-208`)
constrain the **relative** column of tokens on different lines. The subtlety the primitive must respect:

> A re-indent that shifts *only continuation lines* while leaving the first line fixed changes the
> relationship between the block's reference column and its constrained tokens — precisely the
> `by skip⏎ trivial` break in the evidence, where `skip` on the first line is the reference and `trivial`
> on the next is shifted away from it.

The correct primitive shifts the **whole block by one Δ**: the caller positions the first token at
`base`, and `reindentBlock` shifts every continuation line to `base + (its original column − anchor)`.
Because *every* token moves by the same Δ, every pairwise column difference and equality is preserved,
so every internal `colEq`/`colGt`/`colGe` still holds. This is checked, not argued (below): the `match`
and both its `|` arms share one column at every base.

## The property, checked by the fresh frontend at several bases

The fixture is a `match` block whose anchor is column 4. `printer-reindent` re-indents it to a **left**
base (2), the **identity** (4), and a **right** base (6); each output is reparsed by `__analyze-exact`
(non-vacuous: `broken.lean` pins that a parse error yields no artifact). Seven checks:

| check | what it pins |
|---|---|
| bases 2, 4, 6 each re-parse | every re-indent is valid Lean |
| base 4 (= anchor) is the identity | Δ = 0 perturbs nothing; idempotence rests on it |
| bases 2 and 6 moved bytes | the off-anchor property is not vacuous |
| token stream identical across 2, 4, 6 and the input | **parse-preservation** — re-indent moves whitespace, adds/drops/merges no token |
| match and both arms share one column at every base | **`colEq` preserved** — the uniform Δ shift is faithful |
| a block with a multi-line string re-indents and re-parses | the `verbatim` interior does not break the parse |
| the multi-line string token is byte-exact across bases | its interior **never shifts** with the block (`Doc.lean:62-68`) |

The token-stream check is the parse-preservation invariant (`notes/05` §4.1) made concrete: token texts
are the source sliced at each token's `[start, stop)`, and comparing the streams across three
byte-different modules proves the transform touched only whitespace. The column check is the offside
invariant made concrete: `columnOf`-style codepoint columns of `match`, `| 0`, `| _` are all equal to
`base` at each base — the arms track the block, not the page.

## Exact commands

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
    bash tests/printer/run.sh          # --- offside re-indent (RLF-OFFSIDE primitive) ---
    bash tests/boundary/run.sh
    experiments/run-projection-shape.sh
    python3 experiments/check-quoted-figures.py
    git diff --check
    uv run …/check_stack.py --structural docs/projects/ruff-03-language-formatting
    uv run …/write_next.py --check docs/projects/ruff-03-language-formatting

`tests/printer/run.sh` passes with `failures=0`; the boundary suite passes (the printer's import set is
unchanged — `reindentBlock` reads the projection, adds no dependency).

## Measurements

The shape evidence moved again, because **this repository is the printer's own corpus** and the three
new functions in `Printer.lean` grew it. `evidence/01-projection-shape.txt`, regenerated:

    nodes=48260 (was 47329)  empty=17240 (35.7%)  ambiguous=7539 (15.6%)  commands=504 (was 501)  declarations=435 (was 432)

`check-quoted-figures.py` re-passes on all 33 figures across `Printer.lean`, `notes/01`, and
`state/current.md` — the `RLF-FINAL` gate holding, two prompts after it was built, on exactly the drift
it was built to catch.

## What is left uncertain

- **The primitive is proven, but nothing calls it in anger yet.** `RLF-BLOCKS` (prompt 09) is where
  records, tactic sequences, `do`, `where`, and `let` select their blocks and choose a base; the
  block-selection this proves in isolation uses `firstIndentedBlock`, a fixture heuristic, not the node
  structure 09 will consult. The primitive's contract — *first token to `base`, structural lines by Δ,
  token-interiors byte-exact* — is what 09 consumes.
- **The base is chosen by the caller, and choosing it wrongly is a parse break the primitive cannot
  prevent.** Re-indenting a top-level command to a non-zero base, or a nested block to a base left of its
  enclosing offside anchor, produces invalid Lean — the property test uses bases that keep the block
  properly nested. 09 must choose a base that satisfies the enclosing construct's offside, and its own
  reparse gate is what will catch a bad choice.
- **Leading whitespace is canonicalized to spaces.** `reindentBlock` emits `Δ`-shifted indentation as
  spaces, which preserves the codepoint column count `columnOf` compares against but rewrites a tab-
  indented line's bytes. On mathlib-style (space-indented) source this is invisible; it is a deliberate
  normalization, not a parse change, since columns are preserved.
- **The margin is set (100) and still unexercised by breaking.** Re-indent chooses *where* a block sits,
  not *whether* it breaks. Margin-driven line-breaking is `RLF-REFLOW` (prompt 08), and the engine's
  `group`/`line`/`nest` are still unexercised by real source — `RLC-FINAL`'s standing caveat.
