# RYR-IMPL design notes

`RYR-IMPL`. Two new abstractions, each designed twice below (prompt Plan §2): a **projection query
surface** the syntax rules read through, and a **cache tier tag** that keeps the source-only shortcut
from poisoning a syntax `--select`. Everything else is rule bodies + tests + a doc refresh.

## What was already there (re-read against live code, not trusted)

- `SemanticAnalysis.ofEnvelope?` (`Semantic.lean:133`) already runs
  `runRules (.syntax (SyntaxFacts.of normalized artifact.source))` — the **full** registry against the
  projection. So a `.syntax` rule added to `ruleRegistry` executes with no new call site; the artifact
  path already builds `SyntaxFacts` and validates the projection against the bytes first.
- `RulePlan.requiredTier` (`Config.lean:283`) already folds `Tier.max` over selected rules, and the
  main flow (`Application.lean:1011`) already fetches the official artifact when `requiredTier != .source`.
  So selection→fetch→execute is wired end to end. The gap is only in the **cache**.

## The bug shipping a syntax rule exposes (cache tier-completeness)

The source-only shortcut (`Application.lean:429-444`) runs `runSourceRules normalized` — source-tier
findings only — and caches that via `SemanticAnalysis.success`. `cacheHitServes` (`:417`) and the
cache filter (`:990`) gate only on canonical presence, **not** on which tier produced the findings.
Today that is harmless because every rule is source-tier, so "source findings" == "all findings". The
moment FMT010 (syntax) ships:

1. `check --select FMT001` → `requiredTier == .source` → shortcut → caches an entry with **no** syntax
   findings.
2. `check --select FMT010` → `requiredTier == .syntax` → but `availableAnalysis` checks `cached?`
   first, `cacheHitServes` says yes, returns the source-only entry → **FMT010 reported clean on a file
   that violates it.** A persisted false negative (`writeAll`, `:1026`).

This is the "`availableAnalysis` source-only shortcut assumes every rule is source-tier" hazard
`docs/adding-a-rule.md:138-142` names.

### Design A (chosen) — tag the result with the tier it was computed at

Add `tier : Tier` to `SemanticResult`, bump schema `v4 → v5`. The shortcut tags `.source`;
`ofEnvelope?` tags `.syntax`. Serving gate gains a clause: an entry serves a run only when
`result.tier.satisfies plan.requiredTier`. A `.source` entry serves any source-only selection; a
`.syntax` entry (produced whenever the artifact path runs, i.e. `runRules` over the whole registry)
serves everything. So the common case — build the full `.syntax` entry once — still serves any
`--select`; only the narrow shortcut entry is honestly scoped narrow, and a syntax run recomputes and
overwrites it.

- **Caller knowledge:** the serving predicate needs `plan.requiredTier`, which every caller already
  has. Threading it is mechanical.
- **Invariant preserved:** "one entry serves any `--select`" becomes "…at or below its tier"; the
  full entry is still tier-`.syntax` and universal. `RulePlan.findings` still filters afterward.
- **Cache identity:** unchanged — `tier` is a *field of the value*, not part of the key. Overwrite on
  recompute is the existing behavior; a narrower entry is simply replaced by the full one.
- **Schema:** the `v5` bump makes every `v4` entry miss, exactly as `canonical?`/`suppression` did, so
  a pre-tier entry cannot be read as `.source`-by-default and mis-served.

### Design B (rejected) — never take the shortcut once a syntax rule exists

Gate the shortcut on `ruleRegistry.all (·.tier == .source)`. Simpler, but it deletes the shortcut for
*every* source-only, directive-free file the moment one syntax rule ships — the exact fast path
`ruff-05` built and measured. It trades a real steady-state cost for avoiding one field. Rejected: the
tier tag costs one `Nat` per cache entry and keeps the shortcut.

## The projection query surface

Rules receive `SyntaxFacts` = `{ source : SourceFacts, projection : LosslessSource }`. `LosslessSource`
is `kinds : Array String`, `nodes : Array Node {kind, parent, range}`, `tokens : Array Token {node,
start, stop, …}`. Rules need: node→kind string, a node's child nodes, a node's own tokens, and a
node's/token's source text. None exist yet.

### Design A (chosen) — a few total pure helpers on `LosslessSource`, byte-range based

```
LosslessSource.kindOf     (i : Nat) : String            -- kinds[nodes[i].kind]
LosslessSource.childNodes (i : Nat) : Array Nat          -- node indices with parent = some i, in order
LosslessSource.nodeTokens (i : Nat) : Array Token        -- tokens with .node = i, in order
LosslessSource.sliceText  (bytes) (r : SourceRange) : ByteArray   -- normalized byte subrange
```

Text comparison (FMT010/011) is on **byte subranges of `SourceFacts.bytes`**, not `String.Pos`
fiddling: an `attrInstance`/`derivingClass` node's `range` is the leaf hull (trivia excluded), so two
duplicates compare byte-equal and a trailing-arg variant does not. Node/kind lookups are the only
structure the six rules need; no rule walks precedence (the projection has none) or `choice`
alternatives (only the first survives — `LosslessSource.lean:300-306`).

- **Caller knowledge:** a rule sees kinds as strings and children as indices — the tree, without
  `Lean.Syntax`. Matches how `LosslessSource` already hides `Syntax`.
- **Error surface:** helpers are total (bounds-guarded, `getD`), so a malformed index is silence, not
  a throw — a rule is `Facts → Array Finding` with no error channel by design.
- **Exactness:** byte ranges index the normalized string, the one coordinate system; findings and
  fixes land in it with no conversion.

### Design B (rejected) — rebuild a `Lean.Syntax` from the projection and reuse core matchers

Reconstructing `Syntax` would let rules use quotation patterns like Mathlib's linters. Rejected: it
re-introduces the `Syntax` dependency `LosslessSource` exists to remove, needs synthetic `SourceInfo`
(which `structurallyValid` forbids — every token must be `.original`), and buys nothing the four
helpers do not, since the rules match on kind strings and ranges, not on elaborated structure.

## Rule kinds (all `.syntax`; kinds cited in `notes/01-catalog.md` §2 / `evidence/01-catalog.md` §1)

| code | reads | fires |
| --- | --- | --- |
| FMT008 | node kinds | has `declaration`, no `moduleDoc` → flag first declaration |
| FMT009 | top-level command kinds + name tokens | `«namespace»`/`«section»` open outnumber `«end»` at terminal |
| FMT010 | `attributes` → `attrInstance` children text | two byte-identical siblings |
| FMT011 | `derivingClass` siblings text | two byte-identical siblings |
| FMT012 | `«set_option»` → option ident text | name root ∈ {debug, pp, profiler, trace} |
| FMT013 | `paren` child nodes | exactly one child node, kind `paren` |

Fixes: FMT010/011/013 emit `.safe` (byte-range delete / drop outer pair); FMT008/009/012 report-only.

## Owed beyond rule bodies (from `notes/01-catalog.md` §5)

- `SemanticResult.tier` + `v5` bump + serving-gate clause (above).
- `renderCanonicalText` docstring (`Application.lean:358-369`): the "only source-tier rules run here"
  limit is now **non-vacuous** — reword from "nothing is skipped today" to "syntax findings on
  canonical text are deferred to `ruff-06`'s fix-composition decision". No behavior change: `format`
  and `fix` still re-run only `runSourceRules` on canonical text. A syntax `.safe` fix is *reported*
  by `check` on original coordinates, but `fix` does not apply it (see the repair addendum below) —
  RFX-SPEC froze the choice (re-project canonical text, not translate edits onto moved bytes) and the
  successor stack `ruff-10b-syntax-fix-composition` owns wiring it into `fix`.
- `testEngineTiers`: its "every shipped rule is source-tier" probe is now false for `ruleRegistry`;
  update the assertion to the new reality and keep the engine-seam probes (which pass their own array).
- `docs/adding-a-rule.md`: refresh the "first `.syntax`-tier rule" caveat into a description of shipped
  code.
- Fixtures + tests per `notes/01-catalog.md` §5.2–5.4.

## Repair addendum — preview scaffold correction (made mid-implementation)

The freeze had FMT009–FMT012 `enabled`; implementing that surfaced two facts and the stack shipped all
six as **preview** instead. The full rationale is `notes/01-catalog.md` §3; the implementation
consequences are:

- **`default` selector.** `defaultEnabled` was never enforced — the default selection was literally
  `"all"`, so FMT008/FMT013 (already frozen `preview`) were in fact *running* by default. `Config.lean`
  gains a `default` selector that expands to the `defaultEnabled` rules, and `defaultConfig`/`parseConfig`
  seed `#["default"]` instead of `#["all"]`. `all` still means every registered rule. This is the
  minimal enforcement ruff-10 needs for its own preview rules; `ruff-12-rule-lifecycle` owns graduating
  a preview rule into the default set, `ruff-16` the incremental cache, `ruff-19` the default-run cost.
- **Quotation guard.** A defect *inside* a `` `(…) `` quotation is generated-syntax data, not code, and
  must not fire (catalog §5.2). `LosslessSource.inQuotation` walks a node's `parent` chain and returns
  true under any `*quot*` kind; FMT008/010/011/012/013 skip a node the guard flags. FMT009 reads only
  `topLevelNodes`, which a quotation body never reaches, so it needs no guard.
- **Fix deferral is a limit, not a shim.** The three `.safe` fixes (FMT010/011/013) are reported by
  `check` with edits on original coordinates, but `fix` renders canonical text and runs only
  `runSourceRules`, so it neither applies nor withholds them — the file is left byte-identical and the
  finding is still surfaced. `tests/syntax/run.sh` pins this; RFX-SPEC (`ruff-06`) froze the model and
  the successor stack `ruff-10b-syntax-fix-composition` closes it.
- **Tests.** `tests/syntax/run.sh` covers positives (findings + fix bytes), a clean negative, the six
  documented near-misses, quotation/custom-syntax exclusion, malformed-input handling, and the fix
  deferral, all via the exact frontend (the fixtures are unbuilt, so no artifact/module evidence
  exists). `tests/modes/run.sh` moved its `select = ["all"]` config fixtures to `["default"]` (they test
  source-tier FMT001 behaviour and `all` now pulls in the syntax rules) and its `rules --json`
  assertion now lists all thirteen rules with FMT008–013 marked `preview`/`syntax`.
