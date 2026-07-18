# 01 — The semantic-rule catalog and the fact boundary

RMR-SPEC. This note characterizes which Lean 4.32.0 compiler/elaboration facts have **stable
machine-readable identity and stable ranges**, selects four semantic-tier rules that rest only on
those facts, and specifies the projection, cache/demand-gating, and rule-engine interface precisely
enough for RMR-IMPL to build without rediscovering the boundary. No tier, schema, or rule code ships
in this prompt (the same discipline RSF-SPEC held). Every mechanism claim is grounded first-hand in
the pinned toolchain source (`~/.elan/toolchains/leanprover--lean4---v4.32.0/src/lean/`) and confirmed
by running the pinned compiler on `evidence/fixtures/` (raw in `evidence/01-semantic-diagnostics.txt`).

The foundation is `ruff-05b`: `Tier.semantic` exists in the `source ≤ syntax ≤ semantic` lattice
(`Rules.lean:35-55`), `ModuleArtifact` is `v4` carrying an optional `SemanticProjection`
(`ArtifactModel.lean:100-131`), and the `SemanticResult` cache is `v6` recording its `tier`
(`Semantic.lean:26-78`). Crucially, **`Facts`/`RuleImpl` have no `semantic` case yet** and **no rule
reaches `.semantic`** — only the *formatter* demands it, via `RulePlan.demandedTier`
(`Config.lean:302-303`, `Rules.lean:93-114`). This stack adds the first semantic *rules*; it extends
that machinery rather than paralleling it (`state/current.md`).

## 1. Two mechanisms for a semantic-tier rule

A semantic rule reads a fact only elaboration can produce. There are exactly two honest ways to obtain
one, and the completion contract ("normalize only diagnostics with stable semantics and ranges") plus
the stop-rule ("if a compiler message lacks stable machine-readable identity, retain it as a compiler
diagnostic rather than inventing a brittle rule") decide between them:

- **SURFACED / normalized.** The compiler itself, during our exact frontend run, already emitted a
  diagnostic tagged with a stable `kind` (the linter's option name, or the deprecation attribute name)
  and an exact source range. The rule *normalizes* that diagnostic into a lean-fmt `Finding` — it
  preserves the compiler's original message text as detail and asserts only the stable `(kind, range)`
  identity. It does **not** re-derive the fact. Available for any diagnostic with a stable tag.
- **OWNED / derived.** The rule reconstructs the finding from immutable *data* facts — an
  `Environment` attribute keyed by `Name`, plus the resolved constant at each source occurrence — so it
  fires deterministically regardless of the module's own `set_option linter.*` state and can carry a
  structured fix. Available only where the fact is genuine `Environment` data (not an elaboration
  by-product) **and** the source occurrence can be resolved to the keyed `Name`.

The decision rule: **prefer SURFACED unless the rule needs to fire independently of the module's linter
options or needs a structured fix; those require OWNED, which in turn requires the info-tree occurrence
walk (§8).** Re-deriving a diagnostic that is only an elaboration by-product (unused variables, unused
simp args, unreachable tactic) would mean reimplementing a linter from info trees and the metavariable
context — exactly the brittle invention the stop-rule forbids. Those stay SURFACED.

## 2. Inventory — stable identity per candidate fact (completion contract)

Grounded in the compiler-source sweep; `verdict` follows the stop-rule.

| Fact | Source (v4.32.0) | Verdict |
| --- | --- | --- |
| Deprecation entry `{newName?, since?, text?}` of a `Name` | `Linter/Deprecated.lean:24-62`; retained for imported **public** decls via `Attributes.lean:295-305` | STABLE-QUERYABLE (data) |
| Deprecated **occurrence** (which source range uses a deprecated `Name`) | emitted `withRef ref` at `TermElabM.lean:2111-2113`, tag `` `deprecatedAttr `` `Deprecated.lean:95`; or resolve via info-tree `addConstInfo` `InfoTree/Main.lean:344-353` | SURFACED (range from the message) **or** OWNED-via-info-tree (§8) |
| Unused variable / binder | `Linter/UnusedVariables.lean:478-573`, computed from info trees + mctx; emitted `logLint linter.unusedVariables` | DIAGNOSTIC-ONLY → SURFACED only |
| Unused section variable | `Elab/MutualDef.lean:563-582`, `logLint linter.unusedSectionVars header.ref` | DIAGNOSTIC-ONLY → SURFACED only |
| Bound var resembling a nullary constructor | `Linter/ConstructorAsVariable.lean`, `linter.constructorNameAsVariable` | DIAGNOSTIC-ONLY → SURFACED only |
| Message structure `{pos, endPos, severity, data, kind}` | `Message.lean:44-46,510-538` | Stable / structured |
| Linter message provenance (`logLint` double-tags option-name + `linterMessageTag`) | `Linter/Init.lean:133-145`; `logLintIf` `:158-160` | Stable dedup key |
| Whole-file info trees vs `waitForFinalCmdState?` | reset per command `Command.lean:642-643`; final cmdState holds only the **last** command's trees | Pitfall — §8 |

**Message-vs-linter provenance, corrected first-hand.** Not every diagnostic goes through `logLint`.
Deprecation is emitted by `logWarning <| .tagged `` `deprecatedAttr `` … ` (`Deprecated.lean:95`), so its
top-level `kind` is `Lean.Linter.deprecatedAttr` and it is **not** an `isLinterMessage`. The unused
linters go through `logLint`, so their `kind` is the option name (`linter.unusedVariables`, …) and they
*are* `isLinterMessage`. The normalizer therefore keys on `SerialMessage.kind` (the top-level tag),
which is stable for both provenances — confirmed empirically (`evidence/01-semantic-diagnostics.txt`).

## 3. What ships — four SURFACED rules (all empirically firing on v4.32.0)

All four are demonstrated firing with a stable `kind` and an exact range in
`evidence/01-semantic-diagnostics.txt` (fixture `evidence/fixtures/Diagnostics.lean`). All four rest on
**default-on** options, verified in source (`defValue := true`), so a stock build emits them without
configuration. Following the product's stance that only the core text/security rules (FMT001–004) are
on by default and every structural/syntax rule (FMT008–013) is opt-in, **all four default OFF** — a
lean-fmt run opts into them for a batch audit, and the default avoids double-reporting what the
compiler/editor already shows (§9).

| Code | Rule | `kind` tag | Tier | Default | Fix (RMR-IMPL) |
| --- | --- | --- | --- | --- | --- |
| FMT014 | use of a deprecated declaration | `Lean.Linter.deprecatedAttr` | semantic | off | report-only (owned autofix deferred, §8) |
| FMT015 | unused variable / binder | `linter.unusedVariables` | semantic | off | report-only |
| FMT016 | automatically-included section variable unused in a theorem | `linter.unusedSectionVars` | semantic | off | report-only |
| FMT017 | bound variable resembles a nullary constructor | `linter.constructorNameAsVariable` | semantic | off | report-only |

- **FMT014 — deprecated declaration use** (category `deprecation`). Fires per source occurrence whose
  resolved constant carries `@[deprecated]`. Range = the occurrence ident (the emitter's `withRef ref`
  — measured `L9:20-L9:27` over `oldName` in the fixture). Message preserves the compiler's own
  "`oldName` has been deprecated: Use `newName` instead", which already embeds `newName?`/`since?`.
  Report-only in the first cut; the structured `newName?` autofix is the deferred OWNED enhancement (§8),
  not text-parsed from the message (stop-rule).
- **FMT015 — unused variable / binder** (category `unused`). Range = the binder (`L12:15-L12:16` over
  `x`). Report-only: removing a binder can change elaboration (implicit-argument inference, motive
  synthesis), which no fact in this projection can prove safe — so no fix, ever, for this rule.
- **FMT016 — unused section variable** (category `unused`). Fires only for *automatically included*
  section variables unused in a theorem's type and body (`MutualDef.lean:565-576`); an explicitly
  `include`d or referenced variable is excluded. Range = the theorem `header.ref` (`L17:0-L17:47`).
  Report-only; the compiler's message already suggests restructuring the `variable` block.
- **FMT017 — constructor-name variable** (category `naming`). Fires when a bound variable's name is a
  nullary constructor (e.g. a binder named `true`). Range = the binder (`L21:13-L21:17`). Report-only.

These four satisfy the roadmap's "at least four rules ... including deprecated declaration use and
unused-binder/variable diagnostics": FMT014 and FMT015 are the two named; FMT016 and FMT017 prove the
surfaced mechanism generalizes across both the `logLint` and the `deprecatedAttr` provenances and
across three distinct linters. `linter.extra.unreachableTactic` was a candidate but is **rejected**:
its option `defValue := false` (`Linter/Extra/UnreachableTactic.lean:32`), so it does not fire on a
stock build — surfacing an off-by-default diagnostic would ship a rule that silently never fires.

## 4. Capture — normalize the MessageLog we already collect

`analyzeExact` already collects the module's `MessageLog` to decide accept/reject
(`Analysis.lean:16-20,133`) and today discards everything but the error/no-error verdict. The surfaced
rules read that same log: filter to the owned `kind`s, convert each message's `(pos, endPos)` to a
`SourceRange`, keep `severity` and the original `data` text. **No info-tree walk and no `Environment`
query** — the surfaced fact is the compiler's own already-emitted diagnostic. This is a *fact* in the
`ArtifactModel` sense (only the frontend can make it; a reader cannot recompute it from bytes), and the
rule concludes the *finding* (code, message shape, applicability) from it — the facts-not-findings line
holds (`ArtifactModel.lean:104-121`).

The projection gains one field beside `notations` (extend, do not parallel):

```lean
/-- One normalized compiler diagnostic: its stable kind tag, the range it owns, its severity, and the
compiler's own message text preserved verbatim. Facts, never findings — the rule concludes the code. -/
structure Diagnostic where
  kind : String            -- SerialMessage.kind, e.g. "linter.unusedVariables"
  range : SourceRange      -- normalized-source byte offsets (§5)
  severity : Severity
  message : String

structure SemanticProjection where
  notations   : Array NotationSpacing   -- ruff-05b, formatter fact (unchanged)
  diagnostics : Array Diagnostic := #[]  -- ruff-11, rule fact (new in v5)
```

`artifactSchema` bumps `v4 → v5`; a `v4` payload misses rather than decoding a diagnostics-less module
as "no diagnostics captured" (the same stale-payload discipline as every prior bump,
`ArtifactModel.lean:133-138`).

## 5. Range recovery — `Position` to normalized byte offset

A `Message` carries `pos : Position` and `endPos : Option Position` (1-based line, 0-based column;
`Message.lean:510-530`). A `Finding.range` is a `SourceRange` of **byte offsets into the normalized
source** `raw.crlfToLf` (`Rules.lean:57-63`, CLAUDE.md coordinate rule). The conversion is exact and
lossless because `Parser.mkInputContext` normalizes before assigning any position, so the frontend's
`FileMap` — the same `FileMap` the messages were positioned against — indexes the normalized string,
i.e. **the identical coordinate system as the projection**. RMR-IMPL converts `(pos, endPos)` through
that `FileMap` (`FileMap.ofPosition`/`toPosition`) at capture time, inside `analyzeExact` where the
`FileMap` is live, and stores byte offsets in `Diagnostic.range`. Converting at capture keeps the
rule pure (it never sees a `Position` or a `FileMap`) and keeps the stored fact in one coordinate
system. A message whose `endPos` is `none` (whole-line diagnostics) recovers its stop from the line end
via the `FileMap`; RMR-IMPL pins this against the fixture.

## 6. Demand-gating and cache identity — design twice

The open question ruff-05b left: `.semantic` had exactly one sub-fact (`notations`), demanded only by
`renderCanonical`. ruff-11 adds a second sub-fact (`diagnostics`) demanded by a *different* trigger — a
selected semantic rule — so `requiredTier` can now reach `.semantic` from the rule fold for the first
time (a `check --select FMT015` demands it; `Config.lean:291,302-303`). Two designs for how the two
sub-facts share the tier:

### Design A — monolithic `.semantic` capture  *(chosen for the first cut)*
Whenever `.semantic` is demanded (by rendering **or** a selected semantic rule), `analyzeExact`
captures **both** sub-facts: `notations` (the existing descriptor walk) and `diagnostics` (the new
MessageLog filter). A `.semantic` artifact is therefore always complete, so `Tier.satisfies` stays a
**sound** gate and `cacheHitServes` (`Application.lean:449-459`) needs no change: a `.semantic` result
serves any `.semantic` need. Cost: a `format` run also runs the (cheap) MessageLog filter, and a
`check --select FMT014` also runs the descriptor walk (RSF-FINAL measured this at ≈ run-to-run noise,
`ruff-05b/results/03-final.md`). Both new sub-facts are cheap — neither needs info trees — so
over-capture is within budget and buys a monolithic, sound tier.

### Design B — capability-tracked `.semantic`  *(rejected for now; required later, §8)*
Split the demand into a `SemanticCaps {notations, ruleFacts}` record, make each `SemanticProjection`
sub-field `Option` (none = not captured vs some = captured-possibly-empty), record the captured caps in
`SemanticResult` (`v6 → v7`), and extend `cacheHitServes` to require `demandedCaps ⊆ entry caps`. This
avoids over-capture but adds a capability axis beside the tier and a schema field. It earns its keep
**only** when a sub-fact becomes expensive — i.e. when the OWNED/info-tree FMT014 autofix lands (§8),
whose whole-file info-tree walk should not be forced onto every `format` run. Until then Design A is
strictly simpler and equally correct. Recorded here so the later split is a known, bounded extension,
not a rediscovery.

**Verdict: A now, B when §8 lands.** The trap Design A must avoid — a syntax-only or notations-only
artifact silently serving a semantic-rule need — is closed by the same tier-tagging ruff-10 introduced
(`SemanticResult.tier`, `notes/02-implementation.md`): a `.source`/`.syntax` result cannot satisfy a
`.semantic` `requiredTier`, and a monolithic `.semantic` result is complete by construction.

## 7. Rule-engine interface (specified, not shipped)

RMR-IMPL adds the `semantic` case to the three types that `ruff-05b` deliberately left at
`source | syntax`, and the fact view the rules read:

```lean
structure SemanticFacts where          -- what a `semantic`-tier rule may read
  private mk ::
  «syntax» : SyntaxFacts                -- richer facts contain cheaper (as SyntaxFacts nests SourceFacts)
  diagnostics : Array Diagnostic         -- the normalized compiler diagnostics (§4)

inductive Facts where
  | source (facts : SourceFacts)
  | «syntax» (facts : SyntaxFacts)
  | semantic (facts : SemanticFacts)     -- new

inductive RuleImpl where
  | source (run : SourceFacts → Array Finding)
  | «syntax» (run : SyntaxFacts → Array Finding)
  | semantic (run : SemanticFacts → Array Finding)   -- new; RuleImpl.tier → .semantic
```

`runRulesOf`'s match (`Rules.lean:696-699`) gains the `.semantic` rows (a `.semantic` rule runs only on
`.semantic` facts; skips on cheaper facts — the skip stays the fallthrough case, never a `satisfies`
guard, per the existing rationale). Each of FMT014–017 is a `.semantic` rule whose body filters
`facts.diagnostics` by its `kind` and maps each to a report-only `Finding` (preserving `message`,
`severity`, `range`), then `qsort findingOrder` (unchanged) orders the mixed-tier stream. The rules
add **no** new import into the compiler plugin and **no** glob growth (`tests/boundary/run.sh`): the
diagnostics are produced by `analyzeExact` in the reporting process, exactly like the notation fact.

## 8. The OWNED / fixable FMT014 enhancement — specified, deferred

A report-only FMT014 ships in RMR-IMPL. Its **structured unsafe autofix** (replace the occurrence text
with the deprecation's `newName?`) is deferred, and this section freezes it so the later prompt does
not rediscover it:

- The substrate is real and verified: `deprecatedAttr.getParam? env declName : Option DeprecationEntry`
  returns `{newName?, since?, text?}` from `Environment` data, retained for imported **public** decls
  (`Deprecated.lean:24-62`, `Attributes.lean:295-305`); the fixture query prints
  `newName?=(some newName) since?=(some 2024-01-01)` (`evidence/01-semantic-diagnostics.txt`).
- What it needs beyond the surfaced path: the **resolved constant at each occurrence**, which only the
  info tree carries (`TermInfo` via `addConstInfo`, `InfoTree/Main.lean:344-353` — `ti.expr.isConst` →
  `constName`, `ti.stx.getRange?` → range). The projection would carry, per deprecated occurrence,
  `(range, declName, newName?, since?, text?)`; the rule emits an `unsafe` fix (`newName?` only, and
  only for a bare-identifier occurrence — a textual name swap does not preserve dot-notation, argument
  structure, or `open` context, so it is never `safe`; `ArtifactModel.lean:8-24`).
- **Why deferred — the info-tree pitfall.** Info state is reset per command
  (`Command.lean:642-643`), so `waitForFinalCmdState?` (the state `analyzeExact` reads today,
  `Analysis.lean` via `Frontend.lean:243`) holds only the **final** command's trees, not the module's.
  The whole-file trees live in the incremental snapshot tree
  (`Frontend.lean:118-122,357-358`); capturing them is a distinct, measured change to the producer.
  Forcing that walk onto every `format` run is the cost Design B (§6) exists to prevent — so the owned
  FMT014 autofix and the capability split land together, after the surfaced first cut is proven.

## 9. Deduplication with compiler diagnostics

The surfaced facts *are* the compiler's diagnostics, so double-reporting is a real risk the completion
contract names ("deduplicate predictably and preserve original detail"):

- **CLI batch (`check`/`format` on the shell).** lean-fmt owns the surface; there is no second consumer
  showing the compiler's stream, so surfacing is additive, not duplicative. Preserving `message`
  verbatim (§4) satisfies "preserve original detail".
- **LSP / editor integration (ruff-17, ruff-18).** The editor already renders the compiler's own
  diagnostics. A surfaced-rule finding whose `(kind, range)` matches a diagnostic already in the
  editor's stream must be suppressed there to avoid a duplicate squiggle. The dedup key is exactly the
  stable pair this note establishes — `SerialMessage.kind` + range — so the integration layer can dedup
  without re-parsing message text. Recorded as a constraint those stacks inherit; not built here.

## 10. Toolchain-version behavior (no promise beyond v4.32.0)

- **Identity is the `kind` tag** (an option name or attribute name) — a stable identifier, not prose.
  The four tags are pinned to v4.32.0 in `evidence/01-semantic-diagnostics.txt`.
- **Message text is version-volatile** and is therefore *preserved as detail, never asserted* as the
  rule's own claim — a wording change across toolchains changes the displayed detail, not the finding's
  identity or range.
- **Ranges are version-stable** (positions in normalized coordinates), recovered per §5.
- **Graceful degradation, no cross-toolchain promise** (stop-rule). If a future toolchain flips an
  option's default off, removes a linter, or renames a tag, that `kind` simply stops appearing in the
  MessageLog and the rule yields no findings — it never mis-fires on a stale assumption. The surfaced
  mechanism only ever reads tags the running compiler actually emitted, so it cannot invent a
  diagnostic the toolchain no longer produces. RMR-FINAL exercises a toolchain-mismatch case to confirm
  the degradation is silent-empty, not a crash or a false finding.

## 11. What RMR-IMPL owes (roadmap work order 2)

1. `Diagnostic` + `SemanticProjection.diagnostics` (schema `v4 → v5`, stale-miss guard); `SemanticFacts`
   / `Facts.semantic` / `RuleImpl.semantic` (`RuleImpl.tier → .semantic`); the `runRulesOf` rows.
2. Capture in `analyzeExact`: filter the collected `MessageLog` by the four owned `kind`s, convert
   `(pos, endPos)` via the live `FileMap` (§5), store byte-range `Diagnostic`s; monolithic with the
   existing notation capture (Design A, §6). Gate on `.semantic` demanded by rule **or** render.
3. The four rules FMT014–017 as `.semantic` rule bodies (report-only), their `RuleInfo`s in the
   registry (default off, categories per §3), and `allRuleInfos`/`allRulesJson` coverage.
4. Fix classification: FMT014–017 all report-only in this cut (no `Fix`); recorded, not silent.
5. Preserve the source-only/syntax-only fast paths: a run selecting no semantic rule and not rendering
   never demands `.semantic` (verify `requiredTier`/`demandedTier` unchanged for FMT001–013 selections).
6. Persistent tests at the owning layer: engine (`.semantic` lattice/`satisfies`/`runRulesOf` skip),
   projection round-trip (`v5` diagnostics; `v4` clean miss), the four rules over `Diagnostics.lean`
   (kind→code, range, report-only), and a `tests/semantic/`-style differential that the surfaced range
   equals the compiler's own emitted range.

## 12. Decisions changed while freezing this, and remaining uncertainty

- **Changed: surfaced-first, owned-deferred.** The roadmap's phrasing ("compiler and elaboration-backed
  rules") could read as owned-from-`Environment` for all four. The inventory (§2) shows only deprecation
  is genuine queryable `Environment` data, and even it needs the info-tree occurrence walk for the
  autofix. The four shipping rules are all SURFACED (from the MessageLog we already collect) — cheaper,
  no info-tree pitfall, and still "consume immutable projections, never a mutable `Environment`/`CoreM`"
  (the projection is the captured diagnostics). The owned/fixable path is fully specified but deferred
  (§8).
- **Changed: `linter.extra.unreachableTactic` dropped** — off by default, would never fire on a stock
  build (§3).
- **Changed: Design A over B for now** — both sub-facts are cheap, so a monolithic `.semantic` keeps the
  tier a sound gate with no capability axis; B is reserved for when §8's info-tree walk makes a sub-fact
  expensive.
- **Uncertainty for RMR-IMPL.** (a) `endPos = none` range recovery for whole-line diagnostics — the
  `FileMap` line-end fallback is specified but unpinned. (b) Whether any owned `kind` can appear with a
  range **outside** the module's own source (macro-expanded positions attributed to a macro call site —
  `DeprecatedSyntax.lean:56-59` reattributes to the caller); RMR-IMPL must clamp surfaced ranges to the
  module's byte span and drop any that fall outside, so a rule never emits a finding off the file.
  (c) Interaction with suppression (`FMT900`/`FMT901`, `Suppression.lean`): a `# lean-fmt: disable`
  directive must suppress a surfaced finding by code exactly as it does a source/syntax one — the
  finding carries a lean-fmt code (FMT014–017), so the existing suppression path should apply unchanged;
  RMR-IMPL confirms it does.
