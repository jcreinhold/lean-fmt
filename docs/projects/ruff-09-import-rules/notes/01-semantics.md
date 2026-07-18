# The import-rule catalog

`RIR-SPEC`. This freezes which import rules `lean-fmt` ships, what each means, which are safe to fix
and which stay report-only, and — the harder half — the two facts that decide the whole family: the
surface header is **not** the abstract import list Lake parses, and import redundancy is a
graph-derived finding a pure rule cannot produce. It changes no product behavior. `RIR-IMPL`
implements the accepted rules against this note.

Every acceptance claim below is measured, not assumed. The experiment is
`evidence/01-semantics.lean`; its transcript is `evidence/01-semantics.txt`, on
`leanprover/lean4:v4.32.0` (this repo's `lean-toolchain`).

## 0. Codes: the roadmap's "IMP" family is the product's `FMT` namespace

The roadmap names "IMP rule codes." The product ships a single flat `FMT0xx` code space with a
`category` field (`LeanFmt/Rules.lean:118-124`, `283-324`): `FMT001`/`FMT002` (`text`),
`FMT003`/`FMT004` (`security`), `FMT900`/`FMT901` (`ruff-07` suppression directives). There is no
`IMP` prefix in the wire shape (`Rules.lean:136-144`), the selectors, or the docs, and inventing one
would be the actual source-clash — it would contradict the frozen single-namespace scheme every
`--select`, `rules --json`, and suppression path already depends on. So "IMP" is the *family* name;
its members are `FMT005`–`FMT007` in a new `imports` category. Category selection is registry-derived
(`ruff-08` generalized `isCategory` off `ruleRegistry`), so `--select imports` works the moment the
rules land, with no per-category code.

## 1. The two facts that decide everything

### 1a. The surface header is not the abstract import list

A rule that reads `Lean.parseImports'` — the header reader Lake and the product already use
(`LeanFmt/Project.lean:218`, `LeanFmt/Analysis.lean:113-119`) — does **not** see the written header.
Measured (`evidence/01-semantics.txt` §A):

| written header                    | `parseImports'.imports`                                             |
| --------------------------------- | ------------------------------------------------------------------ |
| `import Lean.Data.Json` (once)    | `Init`, `Init` (meta), `Lean.Data.Json` — **count 3**              |
| `prelude` `import Lean.Data.Json` | `Lean.Data.Json` — **count 1** (no `Init`)                          |
| `module` `import Lean.Data.Json`  | `Init`, `Init` (meta), `Lean.Data.Json` (`exported=false`)          |

Two things the surface text never wrote appear in the abstract list, and one thing the text did write
changes shape:

- **Phantom `Init`.** An ordinary file gets two synthesized `Init` entries (a plain one and a `meta`
  one) prepended by the implicit prelude; a `prelude` marker suppresses them. A duplicate- or
  redundancy rule that counted occurrences in `parseImports'.imports` would hallucinate an `Init`
  import on nearly every file and miss it on prelude files.
- **The `module` marker flips `exported`.** Under `module`, a written `import` parses with
  `isExported=false`; without it, `isExported=true`. Same bytes, different abstract import.

`parseImports'` also **discards** every source range, every interleaved comment, and the surface
modifier *spelling* — it keeps only `{module, importAll, isExported, isMeta}` (`Lean/Setup.lean:25-33`).
A dedup fix that deletes "the second `import`" needs the byte range and the comments attached to it;
the abstract list has neither.

**Conclusion (frozen).** Import rules operate on the **surface header**, `[0, headerStop)`, never on
`parseImports'.imports`. The surface header is already modeled: `LosslessSource.headerStop`
(`LosslessSource.lean:187`) bounds it, `Suppression.headerComments` (`Suppression.lean:222-254`)
byte-scans it, and the printer parses it to `Lean.Syntax` and enumerates its groups by kind —
`Lean.Parser.Module.moduleTk`, `«prelude»`, `«import»` (`Printer.lean:1867-1885`). The header grammar
is tiny and closed (`Suppression.lean:212-221`): only the `module` marker, an optional `prelude`, the
`import` lines, and interspersed whitespace/comments live before `headerStop`; module- and
doc-docstrings parse as commands and sit *past* it. This is the "lossless header model" the roadmap's
`RIR-IMPL` names — it exists, and `RIR-IMPL` reuses it rather than re-deriving one.

### 1b. Redundancy is a graph finding a pure rule cannot produce

A `RuleImpl` is pure and IO-free by construction (`Rules.lean:17-19`: "A rule cannot reach a
workspace, a cache, an `Environment`, or `IO`"). Redundancy needs the transitive module graph —
`mod.transImports.fetch` and `mod.input.fetch` (`Lake/Build/Infos.lean:63-84`), which are Lake facets
fetched under a no-build build context. A rule cannot fetch them; a rule that claimed to would be
lying about its tier, which is the exact defect this engine was built to make impossible
(`Rules.lean:104-110`). So **redundancy is not a `RuleImpl`**. It is a finding produced by a private
`Project`-level operation that has the live `Lake.Workspace` (`Application.lean:828`,
`project.workspace`) and the no-build graph pattern already in `Project.batchModuleStatuses`
(`Project.lean:171-187`), threaded into the finding set alongside the header rules. Duplicate and
order/group, by contrast, read only the surface header and *are* pure — they are header rules.

## 2. Acceptance and idempotence, measured

Measured (`evidence/01-semantics.txt` §B–D):

- **A literal duplicate import is accepted.** `import X` written twice parses and loads without error
  (`dup accepted = true`). The environment's import replay is idempotent, so the second occurrence is
  a no-op to elaboration.
- **`parseImports'` preserves the duplicate** (count 4 on a doubled `import`, §C) — it does not
  collapse it, confirming the duplicate is a real surface fact, not a parser artifact.
- **Written order is preserved** (§D: `[Json, HashMap, RBMap]` read back in written order). Order is
  the coordinate the environment replays, and it is observable to elaboration (notation/instance
  resolution, `initialize` order). That is why AGENTS.md and the roadmap make "exact ordered imports"
  non-negotiable, and why every reordering below is report-only or opt-in.

## 3. What ships: three rules in category `imports`

### FMT005 — duplicate import  *(fixable, safe, default-enabled)*

- **Fires when** the surface header contains two `import` lines with the **same module name and the
  same modifier set** (`all`, `meta`, and — under `module` — the same `public`/exported spelling).
- **Why "same modifiers" is load-bearing:** `import A` and `import all A` are *not* duplicates
  (measured §A: `all=false` vs `all=true`); nor are `meta import A` and `import A` (`meta=true` vs
  `meta=false`). They expose different data / IR, so removing one changes what is in scope. Only an
  exact modifier match is a duplicate.
- **Fix (`.safe`):** delete the **later** occurrence and its line, preserving any comment attached to
  the surviving occurrence. Safe because an identical repeated import is an elaboration no-op (§2) and
  deleting the later line leaves the first — and thus the exact ordered set the environment replays —
  unchanged. This is the one import rule whose removal "the exact ordered header behavior is
  unchanged" (roadmap completion contract), so it is the one that auto-fixes.
- **Report vs the phantom `Init`:** the two synthesized `Init` entries are never in the surface text,
  so FMT005 (which reads the surface header) can never fire on them. A file that literally writes
  `import Init` twice *would* be a duplicate — because those are surface occurrences.
- **Severity:** `warning`. **Category:** `imports`. Offsets index the normalized source.

### FMT006 — redundant import  *(report-only, default-enabled, withholding)*

- **Fires when** a written import `Iₖ`'s module is in the **transitive closure** of another written
  import `Iⱼ` (j≠k) of the same file — i.e. `Iⱼ` already pulls `Iₖ` in — so `Iₖ`'s declarations are
  reachable without the direct line.
- **Report-only (`fix? := none`), always.** Reachability is *necessary* but not *sufficient* for
  "removing this import preserves behavior" (roadmap: "Do not infer redundancy solely from graph
  reachability"; "heuristic reachability is never called semantic equivalence"). Transitive
  availability does not equal identical elaboration: import order effects, and re-export visibility to
  downstream modules, are not captured by reachability. The finding says *"transitively available via
  `Iⱼ`; verify before removing,"* never *"safe to delete."*
- **Withholding (recorded, not silent).** A candidate is **withheld** — not even reported — when it
  carries any exposure-changing modifier or role that reachability cannot reason about: `import all`
  (exposes private data a transitive plain import does not), `meta import` (brings IR), or a
  re-exported `public import` in a `module` file (removing it changes what the module re-exports).
  `RIR-FINAL` records how many candidates are withheld and why (its Stop rule). Only plain,
  non-re-exported, transitively-covered imports are reported.
- **Fact source:** the private `Project` graph operation of §1b (`transImports`/`input` facets, no
  build). Duplicates are excluded first (they are FMT005's, not redundancy).
- **Severity:** `warning`. **Category:** `imports`.

### FMT007 — non-canonical import order/grouping  *(report-only by default; fix is opt-in only)*

- **Fires when** the written imports are not in canonical form: within a contiguous import group, not
  sorted by module name; or blank-line grouping does not match the canonical policy.
- **Canonical policy (frozen):** imports are sorted lexicographically **by module name within each
  existing blank-line-delimited group**; groups and their order are preserved, not merged or
  resorted; the `module` marker, `prelude`, and every modifier stay attached to their import; comments
  attached to an import move with it. This matches the printer's existing decision to *keep* blank-line
  groups and treat sorting as separate (`Printer.lean:1936-1941`, from `RLF-COMMANDS`).
- **Report-only by default; opt-in fix.** Reordering imports is observable to elaboration (§2), so the
  default `fix` never reorders (roadmap stop rule: "Stop if an ordering rule cannot preserve exact
  syntax; keep it opt-in or display-only"). The canonical rewrite is available only through the
  explicit organizer (below), which the user opts into; it is never part of unattended `fix`.
- **Severity:** `warning`. **Category:** `imports`.

## 4. The organizer: one private operation, opt-in, CLI + LSP

`RIR-IMPL` adds **one** private organizer operation that produces a canonical header from a file's
surface header: dedup (FMT005's safe removal) composed with the FMT007 canonical sort/group. It is
exposed to callers as an "organize imports" capability usable by both the CLI and the LSP **without
exposing graph internals** (roadmap completion contract) — callers receive a rewritten header or the
edits to produce it, never a `Lake.Workspace` or a module set. The organizer's reorder half is opt-in;
its dedup half is the same safe edit FMT005 emits. Redundant-import (FMT006) removal is **not** part
of the organizer's automatic output — it is report-only, so the organizer surfaces FMT006 candidates
for the user but does not delete them.

## 5. What is report-only, and why the count is not under-delivery

Three roadmap capabilities, three rules; only one (duplicate) auto-fixes. That is the contract, not a
shortfall: the roadmap's own completion contract says duplicate removal is safe "only when exact
ordered header behavior is unchanged," redundancy needs "a proof that removing an import preserves
required direct dependencies" (which reachability is not), and ordering must be "opt-in or
display-only" when it cannot preserve exact syntax. An honest import family is one safe fix, one
report-only graph diagnostic with recorded withholding, and one opt-in reorder — not three auto-fixes
that reorder a file the compiler reads in order.

## 6. Fixtures `RIR-IMPL` owes (roadmap completion contract)

Per the prompt's list — duplicated imports, transitive imports, scoped syntax, plugins, preludes,
modifiers, comments — at the owning layer (`LeanFmtTest.lean` characterization via the `runRulesOf`
synthetic-registry seam for the header rules; a `Project`-level test for the graph operation; on-disk
`tests/check/` or a new `tests/imports/` fixtures for the CLI pipeline):

- **duplicated imports:** exact-duplicate (fires FMT005, fix deletes the later line); same module
  under different modifiers (`import A` + `import all A`) — **not** a duplicate; a literal
  `import Init` twice (fires — surface occurrence, not the phantom).
- **transitive imports:** `Iⱼ` transitively importing `Iₖ` with a plain `Iₖ` line (fires FMT006,
  report-only); the same with `import all Iₖ` / `meta import Iₖ` / a re-exported `Iₖ` (**withheld**,
  count recorded).
- **preludes:** a `prelude` file (no phantom `Init`; rules see only written imports) and an ordinary
  file (phantom `Init` present in the abstract list, absent from the surface — no rule fires on it).
- **modifiers:** `module` marker flipping `exported`; `public`/`meta`/`all` spellings preserved
  through the organizer.
- **comments:** a comment between two imports, and a comment on a duplicated line, both preserved
  across the dedup fix and the organizer's reorder (no comment dropped or reattached to the wrong
  import).
- **scoped syntax / plugins:** a file whose import order is elaboration-significant — the default
  `fix` must **not** reorder it (FMT007 report-only), and the organizer's reorder is only applied when
  opted into. This is the differential `RIR-FINAL` runs.
- **negative / malformed:** a canonically-ordered dup-free file (no findings); a header that fails to
  parse (no rule fires — nothing accepted to lint).

## 7. Decisions changed while freezing this

- **Redundancy left the `RuleImpl` engine.** An early design made all four import capabilities
  `RuleImpl`s. Rejected on contact with `Rules.lean:17-19`: a rule is pure and cannot fetch a Lake
  facet, and the whole point of the tier-as-constructor design is that a rule cannot read what its
  tier does not grant. Redundancy is a `Project`-graph finding threaded in beside the header rules;
  duplicate/order/group stay pure header rules. This keeps the engine's "a rule cannot lie about what
  it reads" invariant intact.
- **The surface header, not `parseImports'`, is the substrate.** Measured phantom `Init` (§1a) killed
  the tempting shortcut of counting `parseImports'.imports`. The header rules read `[0, headerStop)`
  through the existing header model, which also gives them the ranges and comments a fix needs.
- **Ordering ships report-only, fix opt-in — not display-only-and-dropped.** The roadmap allows
  "opt-in or display-only." Display-only alone would waste the canonical-header work the organizer
  must do anyway for CLI/LSP; opt-in fix reuses it and keeps unattended `fix` from ever reordering.
