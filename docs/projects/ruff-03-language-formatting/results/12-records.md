# RLF-RECORDS — results

**Claim:** `RLF-RECORDS` — an over-margin `structInst` (record literal) in `leadFlat` position breaks
**A1**: one field per line at a fixed nest base, so the shared field column satisfies `sepByIndent`'s
`checkColEq`/`checkColGe` by construction. Every other record shape stays byte-flat on the lossless path.

This is the first β-break whose target carries a **column check**. Operators and binders reparsed at any
column (`notes/09` §1.1–1.2); a record's continuation fields must `checkColGe`/`checkColEq` the *first*
field's column (`sepByIndent` re-establishes a `withPosition` inside the braces, `Term.lean:353`). The
work is the design that makes that column *fall out of* the layout rather than be arranged, and the gate
that arms the break only where it is parse-safe.

## What shipped, and the fact that makes each break safe

The renderer accumulates a running indent from the command root and a broken `.line` emits *that* indent
(`Doc.lean:209,229`), independent of the head's output column. A record laid out as
`.group (.text "{ " ++ .nest 2 (field₁ ++ "," ++ .line " " ++ field₂ ++ …) ++ .text " }")` breaks every
field `.line` together, and because `"{ "` is two columns and the `nest` is two, field₁ (right after
`{ `) and every continuation land at the **same** column — running-indent + 2. That shared column is
exactly what `checkColEq` between fields accepts. **The colEq the record needs is not computed; it is a
consequence of breaking at a fixed nest base** (`notes/12` §1 — this is why A1 was chosen over A2/fill,
which would need a computed colEq the layout does not carry).

The break is parse-safe **only when `{` sits at the running indent** — i.e. when the record is
line-leading. A mid-line record (its `{` right of the running indent) would anchor field₁ right of where
the nest breaks the rest, and every continuation would land left of the anchor: `checkColGe` fails, the
parse changes (`notes/12` §2). The engine already places a value line-leading exactly once — **`leadFlat`**
(move-value-down): an over-margin `:=` value hangs on its own indented line, its head at the indent base.
So:

- `structInst` joins the `leadFlat` gate and is claimed as a term (it was `keep`, hence never laid out).
- `termDoc` emits the A1 body (fields as `.line`-separated parts, **no group of its own**) only under a
  `breakRecord` flag, which `termClaims` sets **iff** the record is the `leadFlat` value.
- Because the A1 body carries no group of its own, its field `.line`s break exactly when the enclosing
  `leadFlat` group breaks — the same event that placed the record line-leading. **Break and safety
  coincide by construction, not by a runtime column test.**
- Recursion into fields passes `breakRecord := false`, so a **nested** record (a field value, mid-line
  after `field :=`) takes the flat/`keep` path and keeps its bytes — the conservative fallback
  (`notes/08` §4), enforced structurally rather than by a column guess.
- A record is *plain* (breakable) only when its sole non-empty node-child is the `structInstFields`: a
  `with`-clause, `: T` ascription, or `..` ellipsis makes it `none` and it stays flat. A comment between
  fields makes the inter-field gap non-clean and it stays flat, comment unmoved.

## Verification

- **Over-margin fixtures** (`tests/printer/run.sh`, `--- record layout (RLF-RECORDS) ---`): a plain
  record `def wide : P := { … }`, a `nested` record (a field value that is itself a record), a
  `commented` record (a `/- keep -/` between fields), and a fitting `f`. Formatted at margins
  **0 1 40 80 100 1000**.
- **Broke, not copied:** at margin 40 the wide record is rewritten (goldens cannot degenerate to the
  identity); at margin 1000 the whole file is the identity (a break only fires over-margin).
- **A1 shape at margin 40:** `def wide : P :=` then `  { x := 111111111,` (`{` at column 2) then
  `    z := 333333333 }` (continuation at column 4) — field₁ and every continuation at the one column
  `checkColEq` accepts.
- **Parse-preservation, token AND tree:** every margin's output reparses to the input's token stream and
  **parse tree** (`compare_tokens.py`). The tree gate is load-bearing here: a field landing left of the
  first field's column would break `checkColGe`, and a same-token reparse to a different tree is exactly
  where that could hide.
- **Nested stays flat:** the mid-line inner record `{ a := { … }, … }` keeps its bytes even when it
  overflows — only the line-leading outer record breaks.
- **Comment survives** at every margin; the **fitting** record stays byte-canonical at margin 40.
- **Idempotence:** a second format is byte-identical to the first at every margin (a broken record is
  multi-line ⇒ `mayCollapse` declines it ⇒ its bytes are kept).
- **Corpus round-trip:** `printer-roundtrip` over all 20 modules is byte-identical
  (`commands=506 canonical=479 failures=0`), and every module reports `app_slack=0 binder_slack=0
  match_slack=0` — the real corpus's records fit and stay flat, so `RLF-RECORDS` is a no-op there, as
  every prior layout is on the canonical corpus.
- **Gates:** `check-quoted-figures.py` (33 checked) after the node-count churn (see below); the generic
  stack structural checker and `write_next.py --check`; `git diff --check`.

## Performance envelope

- **Workload:** format `LeanFmt/Printer.lean` (the largest real module; **129,041-byte** source) at margin
  100 through the isolated printer (`lean-fmt-tests printer-format env.json Printer.lean 100`), the
  pre-generated `__analyze-exact` artifact supplied — so the measurement is the printer's own cost (fit
  tests, the new record field-navigation and A1 emit, the offside re-index scan), not `lake setup-file`.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB. **OS / toolchain:** Darwin 25.5.0 /
  `leanprover/lean4:v4.32.0`.
- **Commit:** the `RLF-RECORDS` commit on `main` (parent `ab11b57`, `RLF-OPERATOR-BREAK` final).
- **Wall time:** **0.14 s** real (min of five, `/usr/bin/time -l`, single process).
- **Peak RSS:** **64,618,496 bytes ≈ 61.6 MiB** (min of five, single process).
- **Swap delta:** 0 swaps. Far under the 8 GiB / 256 MiB ceilings.
- **Output:** byte-identical to input (canonical corpus ⇒ the new break is a no-op; the measured cost is
  the fit tests and the scan).
- **Trajectory:** peak RSS **60.7 → 61.6 MiB** from `RLF-OPERATOR-BREAK`. The uptick is the inlined
  record field-navigation and A1 emit; wall time is unchanged (0.14 s) because the canonical corpus has
  no over-margin record to break.

## Decisions changed

- **A1 confirmed against the built engine** (`notes/12` §1). The design chose A1 over A2 (fill) abstractly
  in `notes/08` §2; building it showed the engine makes A1 *free* (the colEq falls out of the nest) and A2
  *expensive* (a computed colEq against every field). Decision unchanged, now with the mechanism named.
- **The mid-line-anchor hazard became an exact condition** (`notes/08` §1a → `notes/12` §2). `structInst`
  is the first β-breakable kind with a column check, so the "break only line-leading" caution is now a
  hard gate: `breakRecord` is set iff the record is the `leadFlat` value, and recursion clears it.
- **No new corpus command.** The field-navigation helper is a local `let recordFields?` inside `termDoc`,
  not a top-level `def`, so the self-referential corpus stays at 506 commands — the same discipline
  `RLF-OPERATOR-BREAK` adopted after a top-level helper bumped it 506→507 and failed the stale-evidence
  check (`results/11`). Node-count figures did churn (49,780 → **50,221**) and the quoted figures in
  `notes/01` and `Printer.lean` were updated to match; `check-quoted-figures.py` passes (33).

## Remaining uncertainty

- **A `with`/typed/ellipsis record never breaks.** These stay flat even when over-margin — the A1 break
  reasons only about a plain field list. Extending to them would need each optional slot's own layout and
  is out of scope; the fallback is lossless, never a guessed layout.
- **A2 (fill) is unbuilt.** One field per line is the only record layout; a wide record with many short
  fields uses more vertical space than a fill would. A2 needs a computed colEq (`notes/12` §1) and is
  deferred, not refuted.
- **The mid-line overflow is accepted.** A nested record that overflows stays flat and its line exceeds
  the margin — parse-safety is preferred over width here, consistent with every prior conservative
  fallback.
