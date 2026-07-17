# 05 — Reflow architecture (phase 2)

Phase 1 (`RLF-COMMANDS`..`RLF-FINAL`) shipped the formatting that is *provably safe today* and
characterized, with parser citations, why the rest was deferred. Its finding, repeated seven times, is
that the safe-today subset is a **no-op on already-canonical Lean** (`app_slack=0`, `binder_slack=0`,
`match_slack=0`, `tactic_blank_gaps=0` on 62 mathlib modules). That is honest and correct — but the
roadmap Goal promised *canonical* formatting of terms, records, tactics, and `do`, and the parts that
would change non-canonical bytes were deferred, not built. Phase 2 builds them, at the **reflowing**
ambition (rebreak to a target width, ruff/Black-style), decided with the user 2026-07-17. This note is
the design-twice for the capability and the layer map the phase-2 prompts execute against.

## 1. What phase 1 proved is missing, restated as three capabilities

The deferrals are not one gap. They are three, with different owning layers:

- **N — declared notation/atom spacing.** Operators and notations keep their source bytes because
  canonical spacing is the notation's *declared* atom string (`infixl:65 " + "`,
  `Init/Notation.lean:284`; documented as a pp-hint at `Init/Prelude.lean:5389`), and the projection
  records a token's *source* text, never its declaration (`LosslessSource.lean:64-86`). The declared
  gap lives **only** in the notation's registered formatter — the untrimmed `sym` baked into
  `symbolNoAntiquot.formatter` (`PrettyPrinter/Formatter.lean:442-446`), which `pushToken` turns into a
  breakable line — **not** in the token table, since the parser trims the symbol before registering it
  (`Parser/Basic.lean:1114`). (ruff-05b RSF-SPEC F1 corrects an earlier draft here that said the fact
  is read from the token table.) Recovering it needs `env := ← getEnv`, an `Environment` that exists
  **only inside the frontend**. So N is a *fact-capture* problem at the analysis layer, not a printer
  problem.
- **O — offside-preserving vertical layout.** Records defer under *any* spacing model because
  `sepByIndent` makes a shared column the field separator (`checkColEq >> checkLinebreakBefore`,
  `Lean/Parser/Extra.lean:202-208`); tactics/`do`/`where`/`let` defer because indentation *is a token*
  (offside). Re-laying-out these blocks requires emitting a multi-line block at a canonical base column
  while preserving every internal `colEq`/`colGt`/`colGe` relationship. That is a *layout-engine*
  capability the current `Doc` does not offer.
- **B — margin-driven line breaking.** The engine already has `group`/`nest`/`line` (`Doc.lean:44-81`),
  but no layout ever emits them from real source (phase-1 state, "Doc's break behaviour is still
  exercised only by ruff-02's own fixtures"), and no margin is set (`Printer.format` requires `width`
  but no caller passes one). B is a *printer* problem: choose break points that respect `checkColGt`
  (a wrapped argument must land at a column strictly greater than its function's, or it stops being an
  argument, `Term.lean:885-892`).

## 2. Design it twice — where does the layout knowledge live?

The pivotal decision is the interface between *(syntax tree + environment)* and *the `Doc`*: how the
printer learns, per node, its canonical spacing and its break/offside behaviour.

### Design A — self-contained layout-regime model

A pure `layoutOf : SyntaxKind → Regime` classifier the formatter owns, with three regimes —
`Reflowable` (inside `withoutPosition`, use `group`/`nest`/`line`), `Rigid` (offside-load-bearing,
re-indent preserving column invariants), `Verbatim` (unknown/custom, keep bytes) — and declared
spacing hardcoded per kind from the *pinned* v4.32.0 grammar for the closed core set. Custom notations
stay conservative.

- **Depth / self-containment:** high. No new dependency on the frontend; cites only pinned grammar.
- **Complecting:** clean. Spacing and break policy are separate tables.
- **Fatal cost:** it *cannot format the open set*. `Arithcc.«term_≃[_]_»` is declared by the code being
  formatted; a table the printer hardcodes cannot know its spacing, and phase-1 already refused a
  hardcoded core table on the ground that it "goes stale silently the moment `Init/Notation.lean`
  changes, and no gate here would notice" (phase-1 state, operators bullet). Design A is that refused
  table with more entries.

### Design B — adopt Lean's `PrettyPrinter` formatter tables

Lean's own `Formatter` already knows every notation's declared layout and every parser's column
behaviour — it is the inverse of the parser, reading each parser's `formatter` attribute from the
`Environment`. Drive *those* tables to emit our `Doc`.

- **Open set:** solved for free — the `Environment` knows every notation, core or corpus-declared.
- **Correctness of spacing/offside:** by construction (it is the parser's own inverse).
- **Fatal cost:** it **loses comments and re-flows verbatim content** — precisely the defect
  `ruff-01`/`ruff-02` exist to fix. Adopting it wholesale reintroduces comment loss and forfeits the
  lossless projection. It also couples the formatter to `PrettyPrinter` internals, which are volatile
  across toolchains (a maintainability cost the stack has otherwise avoided by citing *stable* grammar).

### Chosen — Hybrid: environment-derived *facts*, our lossless `Doc` *engine*

Take B's answer to the open set as **data, not control flow**, and keep A's comment/idempotence
guarantees:

> Capture each notation node's declared inter-atom spacing (and each construct's offside disposition)
> **as a fact, computed from the live parser table during analysis** — where the `Environment`
> exists — and consume that fact in the printer, which still drives layout through our lossless `Doc`
> with our own comment attachment.

This is the synthesis the stack's own principles point to: "closed-versus-open is the line" (phase-1)
is answered by reading the open set from the environment instead of hardcoding it, and the
comment-loss objection to B is answered by never handing layout to Lean's formatter — only its
*declared-spacing lookup*. The projection stays lossless; the fact is additive.

**Consequence for scope — corrected 2026-07-17.** N is a *semantic-tier* fact: it needs the frontend
`Environment`, which is live only at the compiler-plugin producer (`CompilerPlugin.lean:27`), and
`ruff-05` shipped `Tier` with `source`/`syntax` only — the semantic tier does not exist yet. So N is
**not** built inside `ruff-03`; that would re-derive the semantic tier in the wrong layer, where
`ruff-11`'s rules could not reuse it. N is owned by a dedicated foundation stack,
**`ruff-05b-semantic-facts`** (`Tier.semantic` + `ModuleArtifact` `v4` + the `Environment`-capture
producer + the notation-spacing fact), which both this reflow phase and `ruff-11`'s lint rules depend
on. Phase 2 prompt `06` only *consumes* the fact. With no `Environment` outside the frontend there is
no lighter path to operator spacing — phase 1 said so — but the honest home for that path is the
foundation, not a `ruff-03` prompt.

## 3. The `Doc.align` verdict

The phase-1 audit flagged "missing `Doc.align`." That is half right and the wrong half. `align` (align
to the current column, as `sepByIndent.formatter`'s `pushAlign (force := true)` does,
`Lean/Parser/Extra.lean:224`) is what Lean's formatter uses to *inherit* a column it did not choose. A
ruff/Black-class formatter deliberately does the opposite: it re-indents to a *canonical fixed* column,
because column-alignment is unstable under renames (a longer identifier shifts every aligned line).
So the offside capability O needs is **a parse-preserving re-indent to a chosen base column**, not
column-alignment. Whether that is best expressed as a new `Doc` constructor (reopening `ruff-02`, which
wrote its no-align decision at `Doc.lean:71-73`) or as printer-side line reconstruction over the
existing `nest`/`hard` is a genuine design-twice with real tradeoffs (a new primitive widens the
engine's committed surface; printer-side reconstruction keeps the engine frozen but may duplicate line
logic). **That decision is deferred to prompt `07`, which must write both out and compare** — it is not
prejudged here beyond ruling out plain `align`.

## 4. Governing invariants (every phase-2 prompt is gated on these)

1. **Parse-preservation.** The output must reparse to the same token stream and the same comments as
   the input, and — for every construct *not* offside-load-bearing — elaborate the same. This is the
   hard ceiling Lean's whitespace-sensitivity imposes; a reflow that changes the parse is a bug, not a
   style choice. Checked by a fresh-frontend differential (reparse the output, compare), not asserted.
2. **Idempotence.** `format (format x) = format x`, checked by re-analyzing the first pass's output and
   formatting again — a real second format, as phase 1 already does for the shell layouts.
3. **Comment/verbatim preservation.** No comment is moved or dropped; `verbatim` interior is never
   re-indented (`Doc.lean:62-68`). A reflow that would drop a comment refuses the construct and keeps
   its bytes, per the phase-1 `respaceable`/`triviaClean` guards.
4. **Performance.** Reflow adds `group`/measurement work the phase-1 flat runs never triggered. Each
   reflow prompt records a performance line (workload, machine, toolchain, commit, wall time, peak
   aggregate RSS) and stays within the roadmap's 8 GiB / 256 MiB-swap envelope; `render`'s bounded
   linear guarantee (`ruff-02`) must not be broken by the new call sites.

## 5. Target width

Default margin **100 columns**, matching mathlib's own 100-column text linter
(`Mathlib.Tactic.Linter.TextBased`) and Lean community convention (decided with the user 2026-07-17).
It is configuration and enters cache identity (`RLC-SPEC` §5); prompt `08` sets the default and a
project may override it. It is a reviewed product-policy value, not a parser-forced one.

## 6. Layer map (which prompt touches which layer)

| Capability | Owning layer | Prompt |
| --- | --- | --- |
| N — declared notation/atom spacing **fact** (`Tier.semantic`, artifact `v4`, `Environment` capture) | **`ruff-05b-semantic-facts`** (new foundation; `RSF-SPEC`/`IMPL`/`FINAL`) | — |
| N applied — operators/notations take declared spacing | `ruff-03` printer (consumes `ruff-05b`) | `06` RLF-NOTATION |
| O — offside re-indent primitive | `ruff-02` `Doc` (design-twice; reopen only if a constructor wins) + `ruff-03` printer | `07` RLF-OFFSIDE |
| B — margin line-breaking for app/operator/binder/match | `ruff-03` printer (engine ready) | `08` RLF-REFLOW |
| O applied — records + tactic/`do`/`where`/`let` | `ruff-03` printer (consumes `07`) | `09` RLF-BLOCKS |
| Idempotence / parse-preservation / perf / corpus acceptance | `ruff-03` | `10` RLF-ACCEPT |

**Dependency edge:** `ruff-05b` depends on `ruff-01` + `ruff-05` (both verified) and is runnable now;
`ruff-03` phase 2 and `ruff-11` both depend on `ruff-05b`. So the build order for reflow is
`ruff-05b` (RSF-SPEC→IMPL→FINAL) → `ruff-03` `06`→`10`.
