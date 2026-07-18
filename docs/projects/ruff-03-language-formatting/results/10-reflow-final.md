# RLF-ACCEPT — results

`RLF-ACCEPT` is phase 2's acceptance audit. It adds no layout. It runs the reflowing formatter —
everything `RLF-NOTATION` through `RLF-BLOCKS` built — through the idempotence loop and the exact
fresh-frontend differential over the repository corpus, the frozen mathlib sample, generated
over-margin fixtures, and malformed input; it partitions every reflow behaviour into *laid-out* or
*cited-conservative* with a grammar citation, so nothing reflows silently; it records the performance
envelope; and it proves the parse-preservation gate is **non-vacuous** — a deliberately parse-changing
reflow fails it. It supersedes `RLF-FINAL`'s "whole-language coverage" claim, which closed the
*conservative* subset only (roadmap line 54).

## The one thing this audit changed in the tooling: the gate got stronger

An audit changes production code only to fix a defect it finds. This audit found one — not in the
printer, in the **gate** — and fixing it is the audit's main product.

The frozen-sample differential leans on `experiments/compare_tokens.py`: it reparses the formatted
output through the fresh `__analyze-exact` frontend and checks the projection against the input's. It
compared the **token stream** (count, order, text) and the **comments** (count, order, kind, text).
That is the losslessness claim, and it is exactly right for a formatter that only *re-spaces* — but
phase 2 also *re-indents* (`RLF-BLOCKS`), and on offside-sensitive Lean a re-indent can change the
parse **without changing the token stream**. The failure mode is a **re-association**: a re-index that
moves a tactic from an inner `by` block into the outer one. Confirmed first-hand —

    theorem t : True := by         theorem t : True := by
      have h : True := by            have h : True := by
        trivial                        trivial
        skip          ── skip ──►    skip
      exact h                        exact h

both parse, and both emit the **same 16 tokens in the same order**. A token-only gate cannot tell them
apart. What differs is the tree: the moved `skip` acquires a different parent (node 34's parent goes
from the inner tactic sequence to the outer one). So the gate now also compares the **parse tree** —
each node's `(kind, parent)`, resolved to the kind *name* and excluding the byte `start`/`stop` that
move with the whitespace. This is **sound**: a whitespace-only reformat that preserves the parse
produces the identical tree by definition, so the check never fails a legitimate reflow; and it is
**complete for re-association**, which is the one parse change tokens hide. Measured both directions: a
six-line β-break of an application changes the byte digest and leaves the `(kind, parent)` sequence
identical (the gate passes it); the re-association above leaves the tokens identical and changes the
sequence (the gate rejects it).

`RLF-BLOCKS` itself **never emits a re-association** — it shifts a whole block by a uniform delta, which
preserves every column relation and hence the tree (`notes/06`'s `RLF-OFFSIDE` theorem). The gate is
the backstop for a *future* bug, not a live one; the corpus and sample confirm the current printer
trips it nowhere.

## The differential, run four ways

All parse-preserving checks reparse through the fresh `__analyze-exact` frontend — never byte identity,
which only holds on already-canonical source. Every one below is `failures=0`.

- **Repository corpus** (`tests/printer/run.sh`, `printer-roundtrip`): `modules_checked=20 commands=506
  canonical=479 headers_canonical=20 members=68 failures=0`. Byte-identical at margins 0/1/40/80/100/
  large — the corpus is canonical, so every phase-2 layout (reflow, offside re-index) is a no-op on it,
  which is what "already formatted" *means* and what makes the fixtures below the load-bearing evidence.
- **Frozen mathlib sample** (`experiments/run-printer-sample.sh`, 62 modules at margin 80, the numbers
  in `evidence/01-printer-sample.txt`): `modules_analyzed=62 skipped=0 failures=0 reformatted=13`.
  Thirteen foreign modules are actually reflowed — phase 1's run of this harness reformatted fewer and
  was correctness-only; the `+1` over `RLF-BLOCKS`' own run is the offside re-index firing on one more
  module. Every one of the 62, and every one of the 13 that changed, reparses to the **same token
  stream, the same comments, and the same tree** (the strengthened gate above). Losses: `none`.
  Exclusions: `none`. The ownership partition passes — every syntax kind the printer refused is named
  and dispositioned in `experiments/kind-inventory.txt` (the run `exit 1`s otherwise).
- **Generated over-margin fixtures** (`tests/printer/run.sh`, the `RLF-REFLOW`/`RLF-OFFSIDE`/
  `RLF-BLOCKS` sections): applications that β-break, offside blocks re-indented from non-canonical
  columns, `do` blocks at the two hard base cases — each reparsed at six margins to the input's token
  stream, each idempotent, each width-behaviour pinned. This is where a layout that *changes* bytes is
  proven parse-preserving, since the corpus cannot produce one.
- **Malformed input** (`tests/printer/run.sh`, `hostile.lean`): a module with a `#exit` tail of
  non-Lean bytes, an unterminated block comment, and non-ASCII — `commands=7 canonical=3 tail_bytes=173`,
  round-trips with the tail and header preserved verbatim. The parser's own error recovery is the
  boundary; the printer touches only what parsed.

## Reflow coverage — every behaviour owned, laid out or cited

Zero silently unowned reflow behaviour. Each construct is either *actively laid out* (the printer emits
a width- or column-driven layout for it) or *cited conservative* (it keeps its bytes, for a first-hand
grammatical reason). The citations are the receipts.

### Actively laid out

| Construct | Layout | Driver / citation |
| --- | --- | --- |
| Module header, imports, namespaces, sections, attributes, declarations | Canonical vertical + spacing | `RLF-COMMANDS`; `Lean/Parser/Module/Syntax.lean:26` (`ppLine` header) |
| Application `f a b …` | β-break: `group`/`nest`/`line`, all-or-nothing at the margin | `RLF-REFLOW`; `reflows` = `kind == "Lean.Parser.Term.app"` (`Printer.lean:995`) |
| Operators / notations | Declared atom spacing (`a+b` → `a + b`) | `RLF-NOTATION`; the `v4` artifact's notation-spacing fact, `spacingOf`/`notationSpacing` |
| Bracketed binders `(x : T)`, match alternatives `\| p => e` | Declared flat spacing | `RLF-EXPRESSIONS`/`RLF-REFLOW`; `binder_slack`/`match_slack` census = 0 |
| Outermost `by` / `do` block | Offside re-index to canonical base (uniform Δ) | `RLF-BLOCKS`/`RLF-OFFSIDE`; `Term/Basic.lean:185` (no external `checkColGt`), `reindentClaims` |

### Cited conservative (bytes kept)

| Construct | Why it keeps its bytes | Citation |
| --- | --- | --- |
| `structInst` records | First field rides the `{ ` line → mid-line anchor; a uniform shift strands the brace. The vertical A1 break is designed but re-enables the horizontal-collapse hazard | `notes/08` §1a, §2; `results/02` §5b (`sepByIndent` saves inside the braces); `spacingOf` docstring |
| `where` bodies | Keyword leads its own node at a canonical column ≠ `+2` | `results/09` coverage; `reindentClaims` docstring |
| `let` bodies | Body sits `colGe` the `let`, not as an indented sequence | `results/09`; `reindentClaims` docstring |
| Focus `·` | A `tacticSeqIndentGt` with a real `checkColGt` floor; only ever *nested*, so shifted with its parent, never re-based alone | `Init/NotationExtra.lean:320-322`; `Term/Basic.lean:90-92` |
| `Id.run do` / own-line application heads | Head is line-leading at a column the layout cannot prove is an offside scope | `results/09`; `notes/08` §6 |
| Multi-line `structInst` horizontal collapse | Collapsing the gap after `{` moves a position a later line is measured against | `RLF-EXTENSIONS`; `state/current.md` "Horizontal collapsing is not unconditionally safe" |
| `strictImplicitBinder` `⦃x : T⦄` and other binder brackets | Declared spacing consumed where present; no reflow break | `RLF-REFLOW`; `notes/07` §2 (binder/operator/matchAlt breaking deferred) |
| Every refused command kind | Named with a guard/core/corpus disposition and citation | `experiments/kind-inventory.txt` (the sample gate `exit 1`s on any kind absent from it) |

Operator, binder, and match-alternative *breaking* (as opposed to spacing) is deferred with a citation
(`notes/07` §2): the corpus never exceeds the margin on these, so there is no golden to prove a break,
and the break is `RLF-REFLOW`-class work on a construct whose flat form is already canonical.

## Non-vacuity

The gate can fail, and a fixture proves it (`tests/printer/run.sh`, `--- non-vacuity … ---`):

- The re-association pair `reassoc_good`/`reassoc_bad` have an **identical 16-token stream** (asserted),
  so a token-only gate is demonstrably blind to the difference.
- `compare_tokens.py` **rejects** the pair — `parse tree changed at node 34: (kind, parent) ('null',
  32) -> ('null', 19)` — the moved `skip` reparenting from the inner to the outer sequence.
- `compare_tokens.py` **accepts** an identical pair, so it raises no false positive on a real no-op.

Honestly stated: token comparison alone catches token loss and an offside break that fails to parse (no
artifact, caught upstream), but **not** a parseable re-association. The tree comparison closes that gap
at the gate; independently, `RLF-BLOCKS`' uniform-Δ construction guarantees the printer never produces
one. Both are true, and the audit ships both — the construction argument *and* the gate that would
catch a regression in it.

## Performance envelope

- **Workload:** format `LeanFmt/Printer.lean` (the largest real module; **121,933-byte** source,
  **442,922-byte** projection envelope) at margin 100 — every command runs the reflow fit tests and the
  offside re-index scan.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB. **OS / toolchain:** Darwin 25.5.0 /
  `leanprover/lean4:v4.32.0`.
- **Commit:** the `RLF-ACCEPT` completion commit.
- **Wall time:** **0.13 s** real (min of five, `/usr/bin/time`), single `printer-format` process.
- **Peak RSS:** **63,569,920 bytes ≈ 60.6 MiB** (single process, `/usr/bin/time -l`).
- **Output:** byte-identical to input (the corpus is canonical, so reflow and re-index are no-ops; the
  measured cost is the fit tests and the ancestor-walk scan, linear in the command).
- **Trajectory:** unchanged from `RLF-BLOCKS` (60.7 MiB), because `RLF-ACCEPT` adds no production code —
  only a gate assertion and a test. Phase-2 single-module peak RSS held ~57–61 MiB across
  `RLF-REFLOW` (57.4) → `RLF-BLOCKS` (60.7) → `RLF-ACCEPT` (60.6), far under the 8 GiB / 256 MiB ceiling.
- **Acceptance-run envelope:** the frozen-sample differential is dominated by `lake setup-file` per
  module (mathlib elaboration context), not by the printer; the printer's own per-module cost is the
  single-module envelope above.

## What `RLF-FINAL` now means

`RLF-FINAL` closed the acceptance for phase 1: the **conservative** subset — commands, headers, and the
spacing/no-op layouts that change nothing on canonical source, with every deferral cited. Its language
"whole-language coverage" is narrowed here to that conservative subset (roadmap line 54 already carries
the narrowing). `RLF-ACCEPT` is the acceptance for the **reflowing** coverage: the layouts that change
non-canonical bytes (β-break, offside re-index) and the gate that proves they preserve the parse. The
two acceptances stack; neither is weakened.

## Remaining uncertainty

- **The reparse gate is test-time, not runtime.** The printer does not reparse at runtime; parse-
  preservation is an *argument* (uniform Δ / declared spacing) backed by the six-margin reparse-and-
  tree-compare gate over fixtures and the 62-module sample. A layout that broke a parse is a bug to fix,
  which is why the offside re-index owns only the two parents it can prove and keeps bytes elsewhere.
- **Records and operator/binder/match breaking are deferred, not incapable** — each designed
  (`notes/07` §2, `notes/08` §2) and cited, unbuilt because the corpus offers no golden and each
  re-enables a named hazard. A future `RLF`-class prompt could build them; the coverage table would gain
  rows, not lose citations.
- **The tree gate compares structure, not elaboration.** It certifies the *parse* is preserved, which is
  the write-safety ceiling this project set. It does not re-elaborate; a reflow that preserved the parse
  but changed elaboration (none is known, and the offside/spacing layouts cannot) would be outside its
  reach. This is the honest boundary of "parse-preservation as the hard ceiling."
