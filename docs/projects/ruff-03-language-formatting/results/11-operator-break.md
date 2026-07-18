# RLF-OPERATOR-BREAK — results

`RLF-OPERATOR-BREAK` extends the margin-driven β-break `RLF-REFLOW` built for `Term.app` to the two
constructs `RLF-REFLOW` named but deferred as β-breaks — **over-margin operators/notations** and
**bracketed-binder signatures** — and, following the design in `notes/09`, assigns the third named
construct, **`matchAlt`**, to the offside layer that already owns its shape rather than building a
β-break that would split its leading `|` token. Each break is parse-preserving (token stream *and* parse
tree, reparsed through a fresh frontend at margins 0/1/40/80/100/1000), consumes the `RLF-NOTATION`
declared spacing for its separators, and is a byte no-op on any construct that fits. It discharges
`notes/07` §2 and the operator/binder/`match` rows of `results/10`'s coverage table.

## What shipped, and the fact that makes each break safe

The break mechanism is unchanged from `RLF-REFLOW`: `termDoc` emits `.group (head ++ .nest 2 tail)`
where `tail` hangs each part after the head one `nest` (2 columns) below the head, and the `.group`
collapses to flat when the construct fits the margin (`Printer.lean` `termDoc`; `Doc.lean:44-81`). This
prompt widened **where** that mechanism fires and added a per-kind choice of **which** gap is the break
point (`notes/09` §2, Design B).

### Operators / notations — `op_lead`, fact-gated

Operators cannot be reached by a kind list — `«term_+_»`, `«term_∧_»`, and every user mixfix are
distinct kinds (`notes/09` §1.1). They are reached by the same authority that *spaces* them: the
`ruff-05b` declared-spacing fact. The break gate in `termDoc` is

> `mayCollapse && (reflows (kindOf node) || isDeclared) && parts.size ≥ 2`

where `isDeclared` is a local `match spacing with | .declared _ => true | _ => false` — the concept is
used only inside `termDoc`, so it is a `let`, not a top-level def (keeping the self-referential corpus at
506 commands; see *Corpus* below). A fact-covered notation breaks **before its operator token**, gluing
the following operand to it (`op_lead`): `left`↵`  + right`. This is Black's binary-operator convention
and collapses a left-associative chain to one operand per line at a single column, because the operator
`«term_+_»` = `syntax:65 term:65 " + " term:66` carries **no `checkColGt`** on either operand
(`notes/09` §1.1) — every break shape reparses, and `op_lead` is the canonical one. A notation with no
fact stays on the lossless flat path (spacing `.keep`, gate false).

### Bracketed-binder signatures — break-before-each-binder through `optDeclSig`/`declSig`

The binders of `def f (a : T) (b : T) (c : T) : T` are not their own container kind — their parent is an
anonymous `null` node (`notes/09` §1.2). But their grandparent `optDeclSig` (and `declSig`, the required
form) *is* a stable kind, and `Tree.liftedParts` flattens the binder-group `null` and the return-type
`null` into one parts list `[binder, binder, binder, typeSpec]`. So `optDeclSig`/`declSig` were added to
`reflows` and given `.flat` spacing in `spacingOf`; their lifted binders (and the `: type`) become the
β-break points. The as-built shape hangs each binder — and the return type — one `nest` below the head at
**column 2**:

    def f (aaaaaa : Nat)
      (bbbbbb : Nat)
      (cccccc : Nat)
      : Nat := aaaaaa

`declSig`/`optDeclSig` = `many (ppSpace >> (binderIdent <|> bracketedBinder)) >> typeSpec`
(`Lean/Parser/Command.lean:130-135`) carries **no column check** — `ppSpace`/`ppIndent` are
pretty-printer hints with no parsing effect — so any continuation column reparses. Verified by reparse at
every margin, not argued.

### `matchAlt` — offside-owned, not a β-break (design decision, `notes/09` §1.3/§4)

`matchAlt` = `"| " >> ppIndent (… >> darrow >> checkColGe … >> rhsParser)` leads with a **token** (`|`),
and the β-mechanism breaks before every part after the head — which for `matchAlt` is the `|` itself,
splitting it from its pattern (non-canonical, and a different layer's job). Its arms are already
one-per-line by `matchAlts`' `sepByIndent`; its only over-margin case is a long rhs, which is an **offside
re-indent** owned by `RLF-BLOCKS`'s primitive, not a β-break. So the coverage table records match arms as
*offside-laid-out*, and `RLF-REFLOW-ACCEPT`'s "zero deferred *breaking* behaviour" holds with no β-break
waiting on a later prompt. This is the honest reading of the prompt's "matchAlt": the construct is
covered, by the layer whose invariant it lives under.

The `leadFlat` (move-value-down) branch of `termClaims` was widened by the same gate
(`reflows kind || (declaredAtoms? node).isSome`), so an over-margin operator/binder **value** after `:=`
hangs at the indent base (col 2), placing continuations strictly right of the head — the strongest of the
reparse-safe shapes.

## Verification

All gates green at commit `5394583` (toolchain `leanprover/lean4:v4.32.0`).

- **Printer suite** (`tests/printer/run.sh`) — `failures=0`. Two new sections:
  - *operator / notation reflow*: fixture with a wide operator chain, a nested operator, an operator with
    an interior comment, and a fits-flat case; `captureSemantic=1`; margins `0 1 40 80 100 1000`. Asserts
    identity at 1000, changed lines at 40, `op_lead` continuation shape (`^  + `-style at the break
    column), comment survival, fits-flat, idempotence, and token+tree parse-preservation via
    `experiments/compare_tokens.py` at every margin.
  - *bracketed-binder signatures*: fixture with explicit/implicit/instance binders, a commented signature
    (stays flat — the break would move the comment), a `theorem` (`declSig`) case, and a small fits case;
    same margin sweep and gate structure. Asserts binders hang one-per-line at col 2, the commented
    signature stays byte-flat, `declSig` breaks, fits stays flat.
- **Modes / boundary / semantic / layout / lossless** suites — all pass (`integration tests passed`;
  `boundary passed`; `semantic differential + demand-gating tests passed`; layout `failures=0`; lossless
  `the oracle rejected all 13 mutations` / `projection corpus passed`).
- **Corpus** (`experiments/run-projection-shape.sh`) — `commands=506 canonical=479 failures=0`,
  byte-identical round-trip: the corpus is canonical Lean with no over-margin operators or binders, so the
  new breaks never fire and the formatter stays a no-op, exactly as every prior layout.
- **Parse-preservation is non-vacuous** for the new kinds: the over-margin fixtures *do* change bytes
  (asserted `changed` at margin 40) and still reparse to the identical token stream and tree.

## Performance envelope

- **Workload:** format `LeanFmt/Printer.lean` (the largest real module; **125,075-byte** source) at margin
  100 through the isolated printer (`lean-fmt-tests printer-format env.json Printer.lean 100`), the same
  harness `results/10` used — the pre-generated `__analyze-exact` artifact is supplied, so the measurement
  is the printer's own cost (fit tests, the new per-kind break-point decision, the offside re-index scan),
  not `lake setup-file`.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB. **OS / toolchain:** Darwin 25.5.0 /
  `leanprover/lean4:v4.32.0`.
- **Commit:** `5394583` (`RLF-OPERATOR-BREAK`, binder half; operator half `a7e811d`).
- **Wall time:** **0.14 s** real (min of five, `/usr/bin/time -l`, single process).
- **Peak RSS:** **63,668,224 bytes ≈ 60.7 MiB** (min of five, single process).
- **Swap delta:** 0 swaps; peak memory footprint ≈ 18.4 MiB. Far under the 8 GiB / 256 MiB ceilings.
- **Output:** byte-identical to input (canonical corpus ⇒ the new breaks are no-ops; the measured cost is
  the fit tests and the scan).
- **Trajectory:** peak RSS held at ~60.7 MiB — unchanged from `RLF-BLOCKS` (60.7) and `RLF-ACCEPT` (60.6).
  The new production code (one `let isDeclared`, two `spacingOf` cases, two `reflows` entries, one gluing
  branch) adds no measurable cost because the canonical corpus has nothing over-margin to break. Phase-2
  single-module peak held ~57–61 MiB across `RLF-REFLOW` (57.4) → `RLF-BLOCKS` (60.7) → `RLF-ACCEPT` (60.6)
  → `RLF-OPERATOR-BREAK` (60.7).

## Decisions changed

- **The operator break point is `op_lead`, not `op_appstyle`** — decided in `notes/09` §2 by comparing
  both parse-safe shapes on output quality (chain compactness `n+1` vs `2n+1` lines) against ~one predicate
  of code. Design A (uniform every-part break) would have shipped knowingly non-canonical operator output
  for the headline feature.
- **`matchAlt` is not a β-break** — reassigned to the offside layer with the `Lean/Parser/Term.lean`
  citation. This is a scope *clarification*, not a deferral: the roadmap's "match alternatives" line is
  discharged by placing the construct in its correct layer, and `RLF-REFLOW-ACCEPT`'s no-deferred-breaking
  invariant is preserved.
- **The gate is fact-driven (`isDeclared`), not a kind enumeration** — a notation is broken on the same
  authority by which it is spaced. `reflows` keeps `app` and gains `optDeclSig`/`declSig` for binders (kinds
  the fact does not cover); operators ride the `.declared` disjunct.
- **`isDeclared` is a local `let`, not a top-level `def`** — a top-level `Spacing.isDeclared` would have
  added a command to the self-referential corpus (506→507) and failed the stale-evidence check; the concept
  is used only in `termDoc`, so inlining it is also the deeper design.

## Remaining uncertainty

- The break shapes are proven parse-preserving on **focused over-margin fixtures** at six margins, not on a
  corpus of naturally over-margin operators/binders (the repository corpus is canonical, so it has none).
  `RLF-REFLOW-ACCEPT` (prompt 13) runs the complete reflow set through the frozen mathlib sample under the
  strengthened token+tree gate; that is where over-margin real operators/binders, if any exist in the
  sample, are exercised.
- Bracketed-binder breaking currently breaks **all** binders of an over-margin signature (uniform), not the
  minimal set to fit. That is parse-safe and idempotent; a fill-style "break only enough binders" policy is
  a possible future refinement, not a correctness gap, and is not a Goal obligation.
