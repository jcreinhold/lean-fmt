# RLF-BLOCKS — results

## What shipped

`RLF-OFFSIDE` (prompt 07) delivered the *primitive*: a uniform per-line delta `Δ = base − anchor` that
re-indents a multi-line block while preserving every internal `colEq`/`colGt`/`colGe`, proven by
fresh-frontend reparse. `RLF-BLOCKS` **applies** it to real source — the roadmap's literal verb, "apply
`RLF-OFFSIDE` to … tactic/`do`/`where`/`let` blocks at canonical indentation." Where prompt 07 chose the
base by hand in a test, `RLF-BLOCKS` computes it against the enclosing construct.

- **`Tree.reindentClaims`** — a coarse claim over the *outermost* `by`/`do` block of each command. It
  walks the command's node range, and for the first `tacticSeq1Indented` (a `byTactic` body) or
  `doSeqIndent` (a `Term.do` body) whose first item begins its own line, it re-indexes the whole block
  to a canonical base and records the original indent in `Claim.leadReindent`. The block's whole subtree
  is then off-limits to the finer `termClaims`, so a nested `·` body or a `have … := by` inside it shifts
  *uniformly* with the outer block rather than being re-based against a floor it does not share.
- **`Claim.leadReindent`** — the sibling of `RLF-REFLOW`'s `leadFlat`: the seam between the shell's `:=`
  gap and the re-indexed body. `Tree.command` emits the gap **minus** the original leading-whitespace
  run, and the claim's `Doc` supplies the canonical run instead, so the block's first line lands at the
  chosen column with no double indent and no stranded whitespace.
- **The base formula** — one level right of the block's *offside parent* (below).

The engine (`Doc`) is untouched; the re-index is `verbatim` bytes computed by `reindentBlock`, so it is
width-independent (takes no margin) — the property that distinguishes it from reflow and that the
fixtures pin across all six margins.

## The design-twice, and the base formula's two hard cases

`notes/08-blocks-layout.md` §3 wrote the base comparison before the code: **B1** (canonical base = the
enclosing construct's indent + one level, Black's model — indentation is a function of nesting depth)
versus **B2** (preserve the author's base, repair only internal drift). B2 is the identity on
well-formed input — a formatter that leaves indentation as it found it is not formatting it — so **B1**
was chosen, gated by condition A (first token line-leading, §1a) and the reparse ceiling (§1b).

Implementing B1 forced a sharper question the note stated abstractly as "enclosing construct's indent":
**which construct, read how?** Two corpus cases broke the naive readings and fixed the formula:

- **`commandIndent + 2` is too shallow.** A `do` inside a `match` arm (`LeanFmt/Service.lean`'s
  `.analyze` arm at column 2) has its items at arm + 2 = 4, not command + 2 = 2. The base must track the
  *arm*, not the command.
- **The keyword's physical line indent is too deep.** A wrapped signature —
  `private def requiredAs (…)`↵`    [Lean.FromJson α] : … := do`↵`  item` — lands `do` on a continuation
  line indented 4, but the item belongs at command + 2 = 2, not 4 + 2 = 6. The keyword's line is a
  signature continuation, not an offside scope. `LeanFmt/Printer.lean`'s `Id.run do` on a wrapped value
  line is the same shape.

The formula that survives both: the base is one level right of the **offside parent**, and which
construct that is turns on whether the keyword begins its own line.

- **Own-line keyword** (`:=`↵`by`↵`tac`): the `by`/`do` *is* the offside column and already carries the
  block's depth, so the base is its column + 2.
- **Mid-line keyword** (`:= by`, `:= do`, `Id.run do`, the wrapped-signature `:= do`): the keyword rides
  the value's line, so the parent is the enclosing *statement*. The walk climbs the ancestor chain to the
  nearest node whose first token both **precedes** the block's head (skipping the transparent
  `tacticSeq` wrapper that shares the head) and **begins its own line** (skipping the mid-line `Term.do`
  `do` and `declValSimple` `:=`). It re-indexes only when that ancestor is a `matchAlt` (base = arm + 2)
  or sits at the command's own column (the `Command.declaration`/`Command.theorem`/`declModifiers` header
  nodes share that column; base = command + 2) — parents this layout can *prove*. Any other line-leading
  ancestor — an own-line application head (`Id.run do`), a `where`/`let` body — is a column this layout
  does not own, so **the block keeps its bytes**.

This is a fixpoint by construction (the base is a pure function of the tree, so a second format recomputes
it and changes nothing) and diff-stable (an edit above the block does not move it relative to its parent).

## Coverage — what is laid out, and what is cited conservative fallback

**Laid out:** the outermost `by` and `do` block of a command, when its first item begins its own line and
its offside parent is a `matchAlt` or the command header. Both bodies are `sepByIndent` sequences held
together by `checkColEq`/`checkColGe` with **no external `checkColGt`** on the block
(`Term/Basic.lean:185` for `by`; `Term.do` likewise) — confirmed by reparse, a top-level own-line block
de-indents to any column ≥ 1 and re-parses (only column 0 fails, and the re-index never moves the
`by`/`do` keyword).

**Cited conservative fallback (bytes kept), each for a first-hand reason:**

- **`structInst` records.** Under `RLF-OFFSIDE`'s re-indent lens a record is a **mid-line anchor**: the
  first field `x` rides the `{ ` line, so a uniform shift would strand the `{` and pull the fields out of
  their `checkColEq` — `notes/08` §1a's own counterexample. The record therefore fails safety condition A
  and keeps its bytes. The *vertical* A1 break `notes/08` §2 designs (one field per line at a fixed nest
  base, colEq falling out) is a distinct `RLF-REFLOW`-style **breaking** capability, not a re-indent: it
  would require re-enabling the `structInst` horizontal-collapse hazard that `spacingOf` deliberately
  avoids (`results/02` §5b — `sepByIndent` saves a position *inside* the braces, so collapsing the gap
  after `{` moves the first field and breaks a later line). The A1 design stays **on the record and
  deferred**; the reflow-coverage acceptance is `RLF-ACCEPT` (roadmap line 54). The single-line-fits and
  canonical-brace-spacing cases the prompt also names already hold — a record that fits is one line and
  its bytes are its declared spacing.
- **`where`** — the keyword leads its own node at a different canonical column than `+2`.
- **`let`** — its body sits `colGe` the `let`, not as an indented sequence.
- **focus `·`** — a `tacticSeqIndentGt` with a real `checkColGt` floor, but always *nested* inside a
  `by`/`do` block and so shifted uniformly with it, never re-based on its own.
- **`Id.run do` and other own-line application heads** — the head is line-leading at a column this layout
  cannot prove is an offside scope, so the block keeps its bytes.

Every fallback is a *no-op on the canonical corpus* (which is already at these columns), so the coverage
is honest, not silent: the fixtures below carry the proof the capability changes a byte, and the corpus
round-trip proves it changes none where it must not.

## Verification

All in `tests/printer/run.sh`, synthetic fixtures with deliberately non-canonical indentation (the corpus
is already canonical and cannot produce a golden that differs from its input), reparsed through the fresh
`__analyze-exact` frontend at margins **0, 1, 40, 80, 100, 1000**:

- **`--- offside blocks, canonical re-indentation (RLF-BLOCKS) ---`** — `by` blocks: over-indented,
  under-indented, nested with `·` bullets, with a comment, with a multi-line string, and an inline
  `by trivial`. Checks: the blocks are re-indexed (13 lines rewritten); output is byte-identical across
  all six margins (width-independent); every margin reparses to the input's token stream (`checkColEq`
  preserved); every block sits at column 2, nested bullets at 2 and their continuations at 4
  (`colEq`/`colGt`); a comment inside a block survives on its own line, shifted with the block; a
  multi-line string's interior is byte-exact (unmoved by the shift); the inline `by trivial` is left
  alone (condition A); idempotent at every margin.
- **`--- do blocks (RLF-BLOCKS over Term.do) ---`** — the base formula's two hard cases: `direct` (a
  command-value `do`), `wrapped` (the wrapped-signature `:= do`), and `keptHead` (an own-line
  `Id.run do`). Checks: `direct` and `wrapped` bodies land at column 2 — proving the base is the offside
  parent (the command), **not** the keyword line's indent + 2 (= 6 for `wrapped`); `keptHead`'s body is
  left at its non-canonical column 8 (the conservative fallback, bytes kept); width-independent,
  parse-preserving across all six margins, and idempotent.
- **Corpus round-trip** — `printer-roundtrip` over all 20 modules: `commands=506 canonical=479
  headers_canonical=20 failures=0`, byte-identical. The re-index is a no-op on every canonical module (as
  every prior layout's was), so the capability adds coverage without disturbing the corpus.

`failures=0`. `tests/boundary/run.sh` passes; the module-artifact unit suite exits 0;
`experiments/check-quoted-figures.py` agrees with `evidence/01-projection-shape.txt` (33 checked);
`git diff --check` is clean.

## Performance line

- **Workload:** format `LeanFmt/Printer.lean` (the largest real module; 121,443-byte source,
  442,727-byte projection envelope) at margin 100 — every command now runs the offside re-index scan in
  addition to the reflow fit tests.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB.
- **OS / toolchain:** Darwin 25.5.0 / `leanprover/lean4:v4.32.0`.
- **Commit:** the `RLF-BLOCKS` completion commit (parent `2756a26`, the by-block increment).
- **Wall time:** 0.14 s real (min of five, `/usr/bin/time`), single `printer-format` process.
- **Peak RSS:** 63,635,456 bytes ≈ **60.7 MiB** (single process, `/usr/bin/time -l`).
- **Output:** byte-identical to input (the corpus is canonical, so the re-index is a no-op and the added
  cost is the ancestor-walk scan itself, which is linear in the command and negligible).

## Remaining uncertainty

- **Records are deferred, not incapable.** The A1 vertical break is designed (`notes/08` §2) and provably
  safe *as a break*; it is unbuilt because it is `RLF-REFLOW`-style breaking that re-enables the
  `structInst` collapse hazard, and belongs with the reflow-coverage acceptance (`RLF-ACCEPT`). Under the
  re-indent lens this prompt delivers, a record is genuinely a mid-line anchor and keeps its bytes.
- **`where`/`let`/`·` keep their bytes**, each for the cited grammatical reason above. Extending the
  re-index to `where` (a distinct canonical column) or `let` (a `colGe` body, not a sequence) is a
  separate claim, recorded here rather than overstated.
- **The reparse ceiling is test-time.** The projection printer does not reparse at runtime, so the base
  formula's safety is an *argument* (offside-parent + 2, uniform shift preserves every internal column
  relation) backed by the fixtures' six-margin reparse gate — not a runtime fallback. A base that broke a
  parse would be a bug to fix, which is why the mid-line walk re-indexes only the two parents it can prove
  and keeps bytes everywhere else.
