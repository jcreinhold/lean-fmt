# RLF-REFLOW — results

## What shipped

The first layout that makes the engine **decide**. Before this prompt, `LeanFmt/Printer.lean` reached
`Doc` only through `verbatim`/`text`/`cat`/`empty`/`hard` — a flat run of tokens one space apart, no
`group`, `line`, or `nest` from real source, so `Doc.go`'s width measurement was exercised only by
`ruff-02`'s own fixtures. `RLF-REFLOW` emits the three breaking constructors for an over-margin
single-line function application, so an over-wide line is broken one argument per line and a line that
fits is left flat.

- **`Tree.termDoc`** — for a node whose kind reflows (`reflows kind`, today `Lean.Parser.Term.app`),
  that has ≥2 parts, all of whose interior gaps are pure spaces, emit
  `group (headDoc ++ nest 2 (line sep ++ partDoc … per non-head part))`. Flat: the declared separator
  between every part (byte-identical to the pre-reflow output). Broken: the head on its own line, then
  each argument on its own line, indented one level.
- **`Claim.leadFlat`** — the shell→value seam. When a reflowing value follows `:=` inside a single-line
  command, the value claim owns a breakable leading `line` (`group (nest 2 (line ws ++ baseDoc))`) and
  records the flat separator in `leadFlat`. `Tree.command` then emits the gap between `:=` and the value
  **minus** those separator bytes, so the space that would follow `:=` is the `line`'s flat form and
  simply is not emitted when the value breaks — no trailing space survives a break.
- **`reflows`** — the one-line predicate naming which kinds reflow, so the scope is a readable list
  rather than scattered `kindOf` tests.

The engine (`Doc`) is untouched. `ruff-02` is **not reopened.**

## The design-twice, and what forced the shape

`notes/07-reflow-policy.md` writes both comparisons out *before* the code.

**Where the break lives (β over α).** Design α wraps each term in a `group` and keeps the gaps verbatim;
it is disqualified by a defect it cannot retract — when the value's group breaks, the `.verbatim " "`
the claim-stitcher already emitted after `:=` becomes a **trailing space** before the newline, which
`git diff --check` fails. Design β (chosen) makes the breakable gap *be* a `Doc.line`: its flat form is
the declared separator (so β **consumes `RLF-NOTATION`** directly and the corpus round-trips
byte-identically — `line " "` flat renders identically to the old `text " "`), its break form is
`newlineIndent i`, and there is no separate space to leave behind.

**How many gaps break (P1 over P2).** Policy P1 is all-or-nothing (Black's shape): a construct's group
fits flat or every gap breaks. P2 is fill-mode (pack until the margin, then wrap). P1 wins on the
prompt's own axes — diff stability (adding one argument is a one-line diff, not a reflowed block),
idempotence (the broken shape is a fixpoint), and reparse safety (every continuation at one fixed
column). P2's only gain is vertical compactness, which a 100-column margin rarely needs.

**The align-free engine forces break-before-value.** `Doc` has no `align` (`Doc.lean:71-73`); `nest` is
relative to the command root's `i=0`, never to the current column. So breaking an app's arguments *in
place* under `:=` is not expressible — the continuation would land at `nest`, not right of the function
head. The only align-free layout that puts continuations strictly right of the head — the `checkColGt`
that governs every argument (`Lean/Parser/Term.lean:889-892`; a no-op when no `withPosition` is active,
`Basic.lean:1503-1510`, but the rule holds under both branches) — is to break *before* the value so its
head starts a fresh line at a known `nest` base:

    def wide : Nat :=
      target
        1111111111
        2222222222
        …

Head at column 2, arguments at column 4 = 2+2 > 2. Because the command root renders at `i=0`, the
engine's *relative* nest yields *absolute* columns and each level adds a fixed 2, so a child is always
≥2 columns right of its parent's line-start and `checkColGt` holds structurally. **The architecture and
Black's house style land on the same shape, and the agreement is forced, not chosen.**

## Scope, and why it is honest rather than partial

Reflow lives inside `Tree.mayCollapse` (single-line commands), the same boundary phase 1 drew for
parse-safety. A command already spanning multiple lines keeps its bytes (that is `RLF-BLOCKS`, prompt
09). **Idempotence falls out of the boundary**: the first format breaks a single-line over-margin
command into multi-line output `M`; `M` is multi-line, so `mayCollapse` returns `false`, and the second
format keeps `M` byte-for-byte — `format (format x) = format x` without the breaker needing to be a
fixpoint of itself on a re-entrant path.

Only `app` is wired. Operators, bracketed binders, and `match` alternatives are named by the prompt and
**deferred** (`notes/07` §2): the `group`/`nest`/`line` mechanism extends to them unchanged, but wiring
each is a separate claim `RLF-BLOCKS`/`RLF-ACCEPT` own, and the coverage is recorded here rather than
overstated.

## Cache identity — the trigger the old docstring named

`Application.canonicalWidth`'s pre-reflow docstring pre-committed: "whoever adds the first `group` to the
printer adds the key *and* its cache-identity component in the same commit, because at that moment this
value starts changing output and every cached `CanonicalText` becomes stale under an identity that never
mentioned it." `RLF-REFLOW` adds that first `group`. Tracing the cache showed the component **already
exists**: the `formatter` cache-identity digest is `Digest.ofBytes (← IO.FS.readBinFile application)`
(`Cache.lean:258`) — the hash of the application binary, into which `canonicalWidth` is compiled. A
margin change is reachable only by editing the constant and recompiling, which changes the binary, which
changes the `formatter` digest, which invalidates every cached `CanonicalText` at the old margin. The
old docstring's fear ("an identity that never mentioned it") was mistaken about the digest's scope. The
docstring is corrected to record this, to retire its false "emits no `group`, so every margin produces
identical output" premise, and to name the *next* unfired trigger: promoting the margin to a runtime
project-overridable `line-width` key would break the binary-hash argument (a runtime override changes
output without changing the binary), so whoever adds that key folds the resolved margin into the
`configuration` digest in the same commit. No caller needs a per-project override today, so none is
added speculatively — `renderCanonicalText` is the sole production caller and the tests drive `width`
through `format`'s required parameter directly (Plan step 5 audit: no non-test caller hardcodes a
different margin).

## Verification

All in `tests/printer/run.sh` (`--- reflow, margin-driven line breaking (RLF-REFLOW) ---`), synthetic
over-margin fixtures because the corpus is already canonical and cannot exceed the margin (the goldens
cannot degenerate into copies of their input), reparsed through the fresh `__analyze-exact` frontend at
margins **0, 1, 40, 80, 100, 1000**:

- **Identity at margin 1000** — nothing exceeds it, so the output is its input.
- **Changed at margin 100** — the over-margin `wide`/`nested` commands are broken (2 lines rewritten),
  so the golden is not a copy of its input.
- **Parse-preservation** — every margin reparses to the input's exact token stream (`reflow_verify.py`
  compares token streams across all six margins). No break changes what parses.
- **`checkColGt` column relation** — read off `reflow.40.out`: the value head lands at column 2 and every
  argument at column 4 (strictly right of the head).
- **Idempotence** — formatting the output again is byte-identical, at every margin.

`failures=0`. The full suite (notation, offside, reflow, idempotence) is green; `tests/boundary/run.sh`
passes; the module-artifact unit suite (`testCacheIdentity`, `testDoc`, `testConfig`, …) exits 0.

The break is visible on the fixture at margin 40 — a 123-column single-line app becomes an 11-line block
(head at column 2, nine arguments at column 4), widest line 123 → 57, while `def fits : Nat := target 1
2 3 4 5 6 7 8 9` stays flat.

## Performance line

The first prompt to trigger real `group` fit-test measurement.

- **Workload:** format `LeanFmt/Printer.lean` (1809 lines; 405,700-byte projection envelope) at margin
  100 — the largest real module in the repository; every `app` node now carries a `group` and a
  flat-width fit test.
- **Machine:** Apple M4 Pro, 12 cores, 24 GiB.
- **OS / toolchain:** Darwin 25.5.0 / `leanprover/lean4:v4.32.0`.
- **Commit:** the `RLF-REFLOW` commit (parent `d26e92f`).
- **Wall time:** 0.05 s real (0.04 s user, 0.00 s sys), single `printer-format` process.
- **Peak aggregate RSS:** 60,211,200 bytes ≈ **57.4 MiB** (single process; `/usr/bin/time -l`).
- **Output:** 1809 → 1809 lines. The canonical corpus is already multi-line, so almost nothing is a
  single-line over-margin command and the fit tests all resolve flat — the measurement is the cost of
  the fit tests themselves, and it is negligible. The break path's cost is bounded by the same linear
  `render` guarantee `ruff-02` proved; the synthetic fixtures exercise it and stay well inside the
  resource envelope.

## Remaining uncertainty

- **`app`-only.** Operators, binders, and `match` alternatives are deferred (above). The prompt lists
  them; `notes/07` §2 records the deferral against the mechanism that already extends to them.
- **The fit boundary is conservative.** The group's flat-width test measures from the value's `nest`
  base, so a line a column or two over the margin can be left flat rather than broken (observed:
  `def fits …` at 42 columns stays flat at margin 40). This is an under-break, never a parse violation —
  `checkColGt` constrains only *broken* continuations, and a flat line moves nothing — so it is a
  cosmetic conservatism, not a soundness gap. Tightening it belongs with the operator/binder wiring.
- **Multi-line commands are untouched here**, by the `mayCollapse` boundary, and are `RLF-BLOCKS`'s.
