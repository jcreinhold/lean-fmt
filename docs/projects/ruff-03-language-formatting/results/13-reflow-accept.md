# RLF-REFLOW-ACCEPT — results

**Claim:** `RLF-REFLOW-ACCEPT` — the acceptance for the **complete** reflow set. `RLF-ACCEPT` (`results/10`)
accepted the subset that existed when it ran (`Term.app` β-break + `by`/`do` offside re-index) and cited
operator/binder/`match`/record breaking as *conservative-with-a-reason, unbuilt*. `RLF-OPERATOR-BREAK`
and `RLF-RECORDS` built that breadth; this prompt re-runs the acceptance over it, rebuilds the coverage
table so those constructs move to *actively laid out*, and supersedes `RLF-ACCEPT`'s subset coverage.

This is an **audit prompt**: it adds tests and evidence and changes production code only to fix a defect
it finds. It found none in the layouts — every break already shipped is parse-preserving — and one
under-tested claim (the strict-implicit binder bracket and the arm-relative block re-index were laid out
but not fixture-backed), which it closes with two new fixtures.

## The four-way differential — every leg clean

The idempotence loop (`format (format x) = format x`) and the exact fresh-frontend differential (reparse
the output; compare token stream, comments, **and parse tree** via `compare_tokens.py`) were run over:

| Corpus | Result |
| --- | --- |
| **Repository** (all 20 modules, `tests/printer/run.sh` `printer-roundtrip`) | byte-identical: `commands=506 canonical=479 headers_canonical=20 failures=0`; every module `app_slack=0 binder_slack=0 match_slack=0` |
| **Frozen mathlib sample** (62 modules, `run-printer-sample.sh`, margin 80) | `modules_analyzed=62 skipped=0 failures=0 reformatted=13` — idempotent and token+tree parse-preserving on every foreign module |
| **Over-margin fixtures, every breaking construct** (`tests/printer/run.sh`) | app chain, operator chain (`op_lead`), multi-binder signature (all four bracket kinds), A1 record, arm-relative `by`-in-`match` — each broke over the margin and reparsed to the input token stream **and** parse tree at margins 0/1/40/80/100/1000; each idempotent |
| **Malformed input** | a module that does not parse yields no artifact, so the checks cannot silently pass on garbage (`printer-roundtrip` guard) |

**The sample reformats 13 of 62, unchanged from `RLF-ACCEPT`.** The evidence file
(`evidence/01-printer-sample.txt`) is byte-identical to the `RLF-ACCEPT` run: the new
operator/binder/record breaks require a *single-line, over-margin* construct in a breakable position
(`mayCollapse`, and `leadFlat` for a record), which this foreign sample at margin 80 does not present
beyond the `app` breaks already counted. That is the same finding `results/10` recorded and the corpus
round-trip re-confirms — reflow is a no-op on code already written in canonical form, so the *breaks* are
exercised by the synthetic over-margin fixtures, which is exactly where a no-op-on-canonical layout must
be tested. The property that must hold on foreign code — **`failures=0`**, idempotence and token+tree
parse-preservation — holds on all 62.

## Reflow coverage — every behaviour owned, laid out or cited

Zero silently unowned reflow behaviour, and — the change this acceptance ratifies — **zero deferred
*breaking* behaviour**. Every construct the roadmap Goal named as reflowable (`Term.app`,
operators/notations, bracketed binders, `structInst` records) now *actively breaks* over the margin, each
break proven parse-preserving by fresh-frontend reparse (token stream **and** parse tree). `matchAlt` is
offside-owned by design (`notes/09` §1.3/§4), not a β-break. The remaining *cited-conservative* entries
are genuine grammatical fallbacks — a body/head at a column the layout cannot prove is an offside scope, a
mid-line anchor a column check would reject, a horizontal collapse that moves a measured position — each
owned by a prompt and cited.

### Actively laid out

| Construct | Layout | Driver / citation |
| --- | --- | --- |
| Module header, imports, namespaces, sections, attributes, declarations | Canonical vertical + spacing | `RLF-COMMANDS`; `Lean/Parser/Module/Syntax.lean:26` |
| Application `f a b …` | β-break: `group`/`nest`/`line`, all-or-nothing at the margin; over-margin value hangs (`leadFlat`) | `RLF-REFLOW`; `reflows` ∋ `Term.app` |
| Operators / notations `a + b + …` | Declared atom spacing (`a+b`→`a + b`) **and** `op_lead` β-break before the operator token when over-margin | `RLF-NOTATION` (spacing) + `RLF-OPERATOR-BREAK` (break); fact-gate `reflows ∥ isDeclared`; `«term_+_»` carries no `checkColGt` |
| Bracketed binders `(x:T) {x:T} [C] ⦃x:T⦄` | Declared spacing **and** break one-per-line at column 2 when over-margin (all four bracket kinds) | `RLF-OPERATOR-BREAK`; `optDeclSig`/`declSig` = `many (ppSpace >> bracketedBinder) >> typeSpec` (`Command.lean:130-135`), no column check |
| `structInst` records `{ x := …, … }` | Declared spacing **and** A1 vertical break — one field per line at a fixed nest base — when over-margin in `leadFlat` position | `RLF-RECORDS`; `sepByIndent`'s `checkColEq` (`Term.lean:353`) satisfied by the nest base; `breakRecord` gated to `leadFlat` (`notes/12` §2) |
| `by` / `do` block (outermost, or a `match` arm's RHS) | Offside re-index to canonical base — `commandIndent+2`, or **arm-col+2** when the block is a `matchAlt` RHS | `RLF-BLOCKS`/`RLF-OFFSIDE`; `reindentClaims` (`Printer.lean:1475` reads the arm as offside parent); `Term/Basic.lean:185` (no external `checkColGt`) |
| `matchAlt` `\| p => e` gaps | Declared flat spacing (`\| 0 => 1`); `match_slack=0` | `RLF-EXPRESSIONS`; `matchAlt` = `flat` (`Printer.lean:981`) |

### Cited conservative (bytes kept, for a grammatical reason)

| Construct | Why it keeps its bytes | Citation |
| --- | --- | --- |
| Nested / mid-line `structInst` records | Not `leadFlat` ⇒ `breakRecord=false`; a mid-line `{` sits right of the nest base, so an A1 break would land fields left of the first field's column and fail `checkColGe` | `RLF-RECORDS`; `notes/12` §2 |
| `with` / typed / `..`-ellipsis `structInst` records | A1 reasons only about a plain field list; each extra optional slot is another non-empty child the break declines | `RLF-RECORDS`; `notes/12` §3 |
| Pure-term match-arm RHS overflow; `\|` arm columns | A multi-line `match` is `mayCollapse=false` (bytes kept); `matchAlts`' `sepByIndent` owns the arm columns (already one-per-line, canonical) | `notes/09` §1.3; `Printer.lean:955` |
| `where` bodies | Keyword leads its own node at a canonical column ≠ `+2` | `results/09`; `reindentClaims` docstring |
| `let` bodies | Body sits `colGe` the `let`, not as an indented sequence | `results/09` |
| Focus `·` | A `tacticSeqIndentGt` with a real `checkColGt` floor; only ever *nested*, so shifted with its parent, never re-based alone | `Init/NotationExtra.lean:320-322`; `Term/Basic.lean:90-92` |
| `Id.run do` / own-line application heads | Head is line-leading at a column the layout cannot prove is an offside scope | `results/09`; `notes/08` §6 |
| Multi-line `structInst` horizontal collapse | Collapsing the gap after `{` moves a position a later line is measured against | `RLF-EXTENSIONS`; `state/current.md` "Horizontal collapsing is not unconditionally safe" |
| Every refused command kind | Named with a guard/core/corpus disposition and citation | `experiments/kind-inventory.txt` (the sample gate `exit 1`s on any kind absent from it) |

**No *breaking* deferral remains.** `results/10`'s table cited operator/binder/`match`/record breaking as
*conservative-with-a-reason, unbuilt*; `RLF-OPERATOR-BREAK` and `RLF-RECORDS` built all of it, and this
row set moves them to *actively laid out*. The cited-conservative rows are grammatical fallbacks (a column
check that would fail, a body/head the layout does not own) or the parse-safety sub-cases of an owned
break (a mid-line record, a `with`-record, a pure-term arm) — every one owned by a prompt and cited, none
a capability deferred to a later prompt.

## Two fixtures the audit added

- **The strict-implicit binder `⦃x : T⦄`.** `RLF-OPERATOR-BREAK` broke explicit/implicit/instance binders
  and tested those three; the fourth `bracketedBinder` variant rides the same `optDeclSig` path with no
  column check, so it breaks identically, but no fixture pinned it. The `binder` fixture now carries a
  `⦃ssssss : Nat⦄` binder and asserts it hangs on its own line at margin 40 (all four bracket kinds).
- **The arm-relative block re-index.** `notes/09` assigned `matchAlt` to the offside layer, and
  `reindentClaims` (`Printer.lean:1475`) re-indexes a `by`/`do` block that is a match arm's RHS to
  arm-col+2. A new `matcharm` fixture pins that (an over-indented `by` under `\| 0 =>` re-indents to
  column 4) alongside the conservative pure-term arm (kept), with token+tree parse-preservation and
  idempotence at margins 40/80/100/1000.

## Non-vacuity

The parse-preservation gate can fail, and a fixture proves it (`tests/printer/run.sh`,
`--- non-vacuity … ---`), unchanged from `RLF-ACCEPT` and re-run here:

- The re-association pair has an **identical 16-token stream** (asserted), so a token-only gate is blind.
- `compare_tokens.py` **rejects** the pair on the tree — `parse tree changed at node 34: (kind, parent)
  ('null', 32) → ('null', 19)` — the moved `skip` reparenting between sequences.
- The new `matcharm` fixture is itself a non-vacuity case for the arm-relative re-index: a re-index that
  moved a tactic between arms would reparent it (a re-association the tokens hide), and the tree gate
  passing on it means the uniform-Δ shift preserved every arm's parentage.

Honestly stated: the tree comparison closes the re-association gap at the gate; independently,
`RLF-BLOCKS`' uniform-Δ construction guarantees the printer never produces one. Both ship.

## Performance envelope

- **Workload:** format `LeanFmt/Printer.lean` (the largest real module; **129,041-byte** source,
  **467,547-byte** projection envelope) at margin 100 through the isolated printer
  (`lean-fmt-tests printer-format env.json Printer.lean 100`) — every command runs the reflow fit tests,
  the per-kind break-point decision, and the offside re-index scan.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB. **OS / toolchain:** Darwin 25.5.0 /
  `leanprover/lean4:v4.32.0`.
- **Commit:** the `RLF-REFLOW-ACCEPT` commit on `main` (parent `c23f1b0`, `RLF-RECORDS`).
- **Wall time:** **0.14 s** real (min of five warm, `/usr/bin/time -l`, single process).
- **Peak RSS:** **64,651,264 bytes ≈ 61.7 MiB** (min of five, single process).
- **Swap delta:** 0 swaps. Far under the 8 GiB / 256 MiB ceilings.
- **Output:** byte-identical to input (the corpus is canonical, so every reflow and re-index is a no-op;
  the measured cost is the fit tests and the ancestor-walk scan, linear in the command).
- **Trajectory:** peak RSS **57.4 → 60.7 → 60.6 → 60.7 → 61.6 → 61.7 MiB** across `RLF-REFLOW` →
  `RLF-BLOCKS` → `RLF-ACCEPT` → `RLF-OPERATOR-BREAK` → `RLF-RECORDS` → `RLF-REFLOW-ACCEPT`. The last step
  adds no production code (two test fixtures only), so its 0.1 MiB is measurement noise. Phase-2 peak held
  ~57–62 MiB throughout, far under the ceiling.
- **Acceptance-run envelope:** the frozen-sample differential is dominated by `lake setup-file` per module
  (mathlib elaboration context), not the printer; the printer's own per-module cost is the single-module
  envelope above.

## What the acceptances now mean

- **`RLF-FINAL`** closed phase 1: the *conservative* subset (commands, headers, member shells).
- **`RLF-ACCEPT`** is narrowed here to what it accepted — the **application-and-offside subset**
  (`Term.app` β-break + `by`/`do` offside re-index). It is not weakened: it was honest about being a
  subset, and cited the rest.
- **`RLF-REFLOW-ACCEPT`** is the acceptance for the **complete** reflow set: application, operators,
  binders, and records all break over the margin; `by`/`do` blocks (including match-arm RHS) re-index;
  every break is parse-preserving by reparse, idempotent, and a no-op on canonical bytes. **Zero deferred
  breaking behaviour remains.** Phase 2 is complete.

## Remaining uncertainty

- **A `with`/typed/ellipsis record never breaks**, and a wide such record over-margin keeps its bytes.
  This is a *scope* limit of the A1 break (it lays out a plain field list), not a grammatical bar — a
  future prompt could extend it. It is owned and cited (`notes/12` §3); the fallback is lossless.
- **A2 (fill) is unbuilt.** One field per line is the only record layout; A2 needs a computed colEq
  (`notes/12` §1) and is deferred, not refuted.
- **The sample reformats nothing new.** The expanded break set is a no-op on the 62 foreign modules at
  margin 80 — the property proven there is safety (failures=0), not that the new breaks fire on real code.
  Their firing is proven only on synthetic fixtures, which is the structural limit of a formatter whose
  every layout is a no-op on canonical input. A larger foreign corpus with single-line over-margin
  constructs would exercise them further; complete mathlib is forbidden by the stop rules.
