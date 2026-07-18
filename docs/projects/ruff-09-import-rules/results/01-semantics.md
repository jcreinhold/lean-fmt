# RIR-SPEC — Freeze import-rule specifications

**Verified.** The frozen spec is `notes/01-semantics.md`. This records what was run, what it showed,
and what changed while running it.

No product behavior changed. `LeanFmt/` is untouched — the correct footprint for a spec prompt, and
what `state/next.md` declared this to be ("Module: (docs only)"). The characterization ships as a
reproducible evidence experiment (`evidence/01-semantics.lean`), following the `RSR-SPEC` precedent;
the persistent regression suite and fixtures are `RIR-IMPL`'s to write against this note.

## The headline

**Two measured facts decide the whole import family, and both cut against the obvious design.**

1. **The surface header is not the abstract import list.** `parseImports'` — the reader Lake and the
   product already use — prepends two synthetic `Init` imports to an ordinary file (one plain, one
   `meta`), a `prelude` marker suppresses them, and the `module` marker flips a written import's
   `exported` flag. It also discards every source range, comment, and modifier spelling. So import
   rules read the **surface header** `[0, headerStop)` — already modeled by `LosslessSource.headerStop`
   + `Suppression.headerComments` + the printer's kind-based header groups — never `parseImports'`.

2. **Redundancy is a graph finding a pure rule cannot produce.** A `RuleImpl` is IO-free and cannot
   fetch `transImports`; redundancy therefore lives in a private `Project`-graph operation (the
   no-build facet pattern already in `batchModuleStatuses`), threaded in beside the pure header rules.

```
  written header                     parseImports'.imports (measured)
  import X            (ordinary)  ->  Init, Init(meta), X          <- 2 phantom entries
  prelude; import X              ->  X                             <- prelude suppresses Init
  module; import X               ->  Init, Init(meta), X(exp=false)<- module flips exported
  import X; import X  (duplicate) ->  ..., X, X   (count preserved) <- accepted, replay-idempotent
```

## Ships — three rules, category `imports`

- **FMT005 duplicate import** — fixable, `.safe`, default-enabled. Same module **and same modifiers**
  written twice; fix deletes the later line, preserving comments. The only auto-fix, because it is
  the only removal that leaves the exact ordered header unchanged.
- **FMT006 redundant import** — **report-only**, default-enabled, **withholding**. A plain written
  import transitively covered by another; reported as a candidate, never auto-removed. `import all` /
  `meta import` / re-exported imports are **withheld** (count recorded by `RIR-FINAL`), because
  reachability cannot reason about their exposure.
- **FMT007 non-canonical order/grouping** — **report-only by default, fix opt-in only**. Sort within
  existing blank-line groups; never reorder under unattended `fix` (import order is
  elaboration-observable). The reorder is delivered only through the opt-in organizer.

Plus **one private organizer operation** (dedup + opt-in canonical sort) exposed to CLI and LSP
without exposing graph internals.

## Rejected / deferred (with cause)

- **Auto-fixing redundancy or ordering.** Reachability is not semantic equivalence, and reordering is
  observable to elaboration (measured §2, §D). Both stay report-only / opt-in per the roadmap stop
  rules — not under-delivery but the contract ("duplicate removal safe only when exact ordered header
  behavior is unchanged").
- **Reading `parseImports'.imports`.** Killed by the measured phantom `Init` and dropped ranges/comments.
- **Redundancy as a `RuleImpl`.** Killed by `Rules.lean:17-19` (a rule cannot fetch a Lake facet).

## Commands run

- `lake env lean docs/projects/ruff-09-import-rules/evidence/01-semantics.lean`
  → `evidence/01-semantics.txt`. The header/import facts of `notes/01-semantics.md` §1–2.
  Toolchain `leanprover/lean4:v4.32.0`.
- `LEAN_NUM_THREADS=1 lake build` — clean, 40 jobs (no production change; confirms the tree builds).
- `tests/boundary/run.sh` — passes; the source/dependency boundary is unchanged.
- From `/Users/jcreinhold/Code/kan-proofs` (pyyaml via `uv`):
  `check_stack.py <stack> --structural` and `write_next.py --check <stack>` — pass.
- `git diff --check` — clean.

## Remaining uncertainty

- **The `FMT006` withholding boundary is frozen conservatively** (withhold on any `all`/`meta`/
  re-export). `RIR-IMPL` may find, with corpus evidence, that a narrower reported set is honest — which
  would reopen this note rather than drift. The report-only stance is not negotiable regardless.
- **The organizer's `Facts`/threading shape is specified, not implemented.** §1b fixes the *semantics*
  (header rules pure; redundancy a `Project` operation with the live workspace); the exact seam
  (a new `header` fact case vs. a source-derived header parse; how the graph finding is threaded from
  `execute`) is `RIR-IMPL`'s to design-twice and verify, within the frozen constraint that a rule
  stays pure.
- **Order-effect divergence is characterized, not exhaustively reproduced.** §2/§D measure that order
  is preserved and replayed; the specific elaboration divergence a reorder can cause (notation /
  instance / `initialize`) is asserted from replay semantics and the frozen non-negotiable, and
  `RIR-FINAL`'s differential is where a committed order-significant fixture proves the default `fix`
  never reorders it.
