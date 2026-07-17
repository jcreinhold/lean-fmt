# 01 — The semantic fact boundary and the declared-spacing representation

RSF-SPEC. This note characterizes exactly where declared notation/atom spacing lives in the live
`Environment`, corrects a source-false premise the consumer stacks inherited, designs the fact
representation twice, and specifies the tier / schema / demand-gating shape precisely enough for
RSF-IMPL to build without rediscovering the boundary. Every claim here is grounded first-hand in the
pinned Lean 4.32.0 toolchain source (`~/.elan/toolchains/leanprover--lean4---v4.32.0/src/lean/`) and
this repo's producers.

## 1. Mechanism — where declared spacing actually lives (four findings)

### F1 — Declared spacing is a formatter pp-hint, **not** a token-table entry

The reflow architecture note and this stack's roadmap both said the fact is read "from the token
table via `parseToken`." That is **source-false** and is corrected here.

- The parser **trims** the declared symbol before it ever reaches the token table:
  `symbolNoAntiquot (sym) := let sym := sym.trimAscii.copy; …` (`Lean/Parser/Basic.lean:1113-1116`).
  `symbolInfo`'s `collectTokens` therefore registers the *trimmed* `"+"` (`Basic.lean:1105-1108`), and
  `TokenTable := Trie Token` with `Token := String` (`Lean/Parser/Types.lean:37,39`) stores that
  trimmed string. **The token table cannot supply the gap.**
- The declared gap survives only on the **formatter** side: `symbolNoAntiquot.formatter (sym : String)`
  is generated with the *untrimmed* `" + "` and calls `pushToken info sym false`
  (`Lean/PrettyPrinter/Formatter.lean:441-446`). `pushToken` (`Formatter.lean:366-417`) is what turns
  a **declared trailing space** into a breakable `Format.line` (`Formatter.lean:412-414`) and consults
  the token table *only* for the discretionary-adjacency question — "would `+x` re-lex as one token?"
  (`Formatter.lean:385-399`) — never for the declared gap itself.
- The compiler documents this in its own words: *"Whitespace before or after the atom is used as a
  pretty printing hint. `" + "` parses `+` and pretty prints it with whitespace on both sides. The
  whitespace has no effect on parsing behavior."* (`Init/Prelude.lean:5389`, `Syntax.symbol` doc).

So the fact is captured from the notation's **registered formatter (the parser's authoritative
inverse)**, not from the parser/token table. This is still "captured, never guessed" — but the source
is corrected. The roadmap stop-rule and the ruff-03 reflow note are amended to match (task 3).

### F2 — Reachability: the lookup grows **no** import closure

`LeanFmt/CompilerPlugin.lean` imports `LeanFmt.ArtifactModel`, which does `import Lean`
(`ArtifactModel.lean:4`). The whole of `Lean` core — including `Lean.Parser.*` and
`Lean.PrettyPrinter.*` — is therefore **already** in the plugin's transitive closure. The boundary the
roadmap feared is narrower than "any new Lean API": `tests/boundary/run.sh` pins that the plugin does
not `import`/glob `LeanFmt.Rules` (or `Application`/`Cache`/`Cli`/`Config`/`Edit`/`Project`/`Semantic`/
`Service`) — i.e. lean-fmt's **own volatile modules**, whose *content* changes and would churn every
integrated project's Lake trace (`ruff-05` `notes/01-rule-facts.md` §3). Lean core is fixed by the
toolchain; using a larger subset of an already-imported `Lean` does not change the plugin's own source
and so cannot churn a downstream trace. **Reading the formatter/parser tables is closure-legal.**

### F3 — There are **two** producers; only one is demand-gated

| Producer | Where | When it runs | Has live `Environment`? |
| --- | --- | --- | --- |
| `CompilerPlugin.produceArtifact` | `CompilerPlugin.lean:26-39` | **always-on** — every module of every integrated build; artifact embedded in the `.olean` | yes (`getEnv`, line 27) |
| `analyzeExact` | `Analysis.lean:53-87` | **on-demand** — only when lean-fmt itself runs (`format`/`check`) | yes (`waitForFinalCmdState?`, line 77 — the final command state, currently discarded) |

This split is the whole demand-gating story (F4). The `analyzeExact` frontend already reaches the
final command state at `Analysis.lean:77` and throws it away; the semantic fact is captured *there*,
on demand, not baked into every integrated `.olean` by the always-on plugin.

### F4 — Honest demand-gating falls out of the producer split

- The **always-on plugin** keeps emitting the source/syntax projection with **no** semantic fact
  (`semantic? = none`). No formatter probe runs in an integrated build, so no build pays for a
  formatting capability it never invoked, and the plugin's own source is unchanged → **no trace
  churn** for integrated projects. This is the "syntax-only fast path" the roadmap promises for a
  project that neither formats nor runs a semantic rule.
- The **on-demand `analyzeExact`** captures the semantic fact (`semantic? = some …`) **only when the
  run needs it**. `format` always needs the notation gap, so a `format` run demands it; a report that
  selects only source/syntax rules does not, and may be served by the cheap cached plugin artifact.
- Consequence for the consumer: a cached plugin artifact has `semantic? = none`, so it **cannot**
  satisfy `format`. `format` therefore triggers a fresh `analyzeExact` (a frontend re-run it already
  performs when no valid cached artifact exists) whose recorded cost is one frontend process plus the
  per-kind formatter probe. This is the "recorded, not hidden" cost the roadmap names. RSF-FINAL
  measures it against the syntax-only baseline.

## 2. Fixture characterization — what the fact must carry per case

Declared spacings pinned first-hand (`evidence/01-declared-spacing.txt`). `Gap` classifies a declared
side: **`tight`** (no declared space; `pushToken` may still insert a discretionary space by the
adjacency check, `Formatter.lean:385-399`), **`space`** (one declared space → a breakable
`Format.line`, `Formatter.lean:412-414`).

| Fixture | Declaration (source) | Atom(s) | Declared gaps (before, after) | What it proves |
| --- | --- | --- | --- | --- |
| Core infix `_ + _` | `infixl:65 " + "` (`Init/Notation.lean:284`) | `+` | (space, space) | the common symmetric case; `a+b → a + b` |
| Prefix `-_` | `prefix:75 "-"` (`Init/Notation.lean:293`) | `-` | (tight, tight) | asymmetric/none — leading atom, no declared gap; must **not** invent one |
| Postfix `_⁻¹` | `postfix:max "⁻¹"` (`Init/Notation.lean:295`) | `⁻¹` | (tight, tight) | trailing atom, no gap; keying by bare token would be wrong (see below) |
| Multi-atom notation (e.g. `«term_≃[_]_»`, corpus-declared) | `notation:… " ≃[" … "] " …` | `≃[`, `]` | per-position: `≃[` (space, tight), `]` (tight, space) | **the open set**: a corpus notation the code being formatted declares; different atoms in one kind carry different gaps |

The multi-atom row is load-bearing for the representation choice: the token `[` appears with a
*trailing* gap here but with no gap in `List` indexing notation elsewhere — **the gap is a property of
(syntax-kind, atom position), not of the bare token string.** Any representation keyed on the token
alone is rejected on this fixture.

## 3. Design it twice — how the resolved fact is stored in the artifact

Both designs obtain the same underlying data (F1: per-kind declared `sym`s via the registered
formatter). The design-twice is about the **storage shape in the `v4` artifact** and the consumer's
mapping cost — not about the capture mechanism, which is shared.

### Design A — per-node inline spacing

Every atom occurrence in the `LosslessSource` projection carries its resolved `(before, after)` gaps.

- **Artifact size:** poor. A mathlib module has thousands of `+`, `,`, `:=`, `→` occurrences; each
  stores redundant gap data identical to every other occurrence of the same kind/position. Size grows
  linearly with token count — the projection is already the artifact's bulk.
- **Cache identity / digest:** neutral (the fact enters the digest either way).
- **Staleness across a toolchain bump:** fine — recomputed every analysis; a changed declaration yields
  changed per-node gaps.
- **Open-set expressibility:** fine — any node, core or corpus, gets its own gaps.
- **Consumer cost:** O(1) per node, but the data was expensive to *store*, and the printer must thread
  gaps through the same projection it walks for text.

### Design B — module-level per-kind spacing template  *(chosen)*

One entry per distinct `SyntaxNodeKind` present in the module: the **ordered** declared gaps of that
kind's atoms (an atom-position template). The printer maps a node → its kind → the template → applies
each atom's gap by position.

- **Artifact size:** good. One template per *distinct kind* (dozens per module), not per occurrence
  (thousands). The bulk projection is untouched; the fact is a small side table.
- **Cache identity / digest:** clean. The table is a pure function of (the set of kinds the module
  uses × the toolchain's declarations); it enters the digest once, as a compact map.
- **Staleness across a toolchain bump:** fine, and *localized* — a redeclared operator changes exactly
  one template entry.
- **Open-set expressibility:** good and decisive. A corpus-declared notation appears in the module as a
  kind and gets exactly one ordered template; the multi-atom `«term_≃[_]_»` fixture is expressed
  directly (per-position gaps), which the rejected *per-token* sub-variant of B could not do.
- **Consumer cost:** O(1) kind lookup + positional atom index. The printer already walks the tree by
  node kind, so the mapping rides an index it already has.

### Verdict — B (per-kind ordered template), with per-token keying explicitly rejected

B wins on size and cache locality without losing the open set, and the multi-atom fixture kills the
tempting per-token shortcut: **the key is the syntax-kind, and gaps are ordered by atom position.**
A is rejected as redundant bulk. The stored fact is, per present kind, an ordered list of atom gaps;
`none` for an atom whose declaration the probe could not resolve, which the printer degrades to the
conservative **source bytes** (roadmap stop-rule), never to invented spacing.

## 4. Specification for RSF-IMPL

### `Tier.semantic`

Add `| semantic` to `Tier` (today `source | syntax`, `ruff-05` state). The lattice extends
`source ≤ syntax ≤ semantic`; `Tier.max` already folds and gains the new top. `RulePlan.requiredTier`
folds over the registry unchanged and now *can* reach `semantic`. The formatter is not a rule, so its
demand is expressed outside the rule fold: **`format` requires the artifact to carry the semantic
projection** (equivalently, requires `requiredTier ⊔ formatterTier = semantic`). Selection stays a
pure projection over facts and still never selects worker/artifact/cache/scheduling
(`ruff-05` invariant).

### Schema `v3 → v4`

`ModuleArtifact` gains an **optional** field beside the unchanged lossless `source`:

```
structure ModuleArtifact where
  schema   : String
  source   : LosslessSource
  semantic : Option SemanticProjection := none   -- new in v4
```

`artifactSchema := "lean-fmt.module-artifact.v4"`. `SemanticProjection` carries the per-kind
notation-spacing template (Design B). Optional because the two producers differ (F4): the plugin emits
`none`, `analyzeExact` emits `some` under demand. `v4` decode is total (a `v3` payload **misses**, does
not silently decode — matching the `artifactSchema` doc's stale-payload rule, `ArtifactModel.lean:108`).
Additive: the `source` projection is byte-for-byte unchanged, so a `v4/semantic=none` artifact is the
`v3` content under a new version tag.

### Digest / cache identity

The schema string is part of artifact identity; bumping to `v4` invalidates `v3` payloads exactly
once (correct — the shape changed). A `v4/semantic=none` artifact and a `v4/semantic=some` artifact for
the same module are *distinct* identities: the semantic table is part of the digest, so a `format` run
cannot mistake a syntax-only cache for a semantic one. This is what makes demand-gating sound rather
than a silent under-serve.

### Demand-gating cost model (F4, restated as the implementable contract)

1. Plugin producer: `semantic = none`, always. Zero probe cost in integrated builds; no trace churn.
2. `analyzeExact`: computes `semantic = some` **iff** the invoking run's required tier reaches
   `semantic` (always for `format`; never for a source/syntax-only report).
3. Consumer: a `format` run rejects a `semantic = none` cache and drives a fresh `analyzeExact`; its
   cost = one frontend process + one formatter probe per *distinct* present kind (deduped by B).
   Recorded in RSF-FINAL against the syntax-only baseline on the frozen sample.

## 5. Remaining uncertainty (carried into RSF-IMPL)

- **Exact capture API.** The fact is closure-sourced (F1), so RSF-IMPL captures it via the registered
  formatter, e.g. running the kind's `combinator_formatter` (looked up through
  `Lean.PrettyPrinter.formatterAttribute` / `Lean.PrettyPrinter.format`) on trivia-stripped node
  instances and reading the `sym`s it emits at `pushToken`. The precise attribute/entry-point names
  must be pinned first-hand in RSF-IMPL. **Preferred alternative to investigate first:** a data-only
  atom store (does notation elaboration persist the untrimmed atoms anywhere queryable, avoiding a
  formatter run?). If one exists it is cheaper and less volatile; if not, the formatter probe is the
  authoritative fallback and is comment-safe because the probe runs on trivia-stripped nodes while our
  `Doc` engine owns real trivia.
- **Probe cost.** Running a per-kind formatter probe inside `analyzeExact` adds work proportional to
  the number of *distinct* kinds, not tokens; expected small but unmeasured until RSF-FINAL. If it
  proves heavy, the demand-gating already confines it to formatting runs.
- **`unicodeSymbol` / ASCII duals.** `unicodeSymbolNoAntiquot.formatter (sym asciiSym) preserveForPP`
  (`Formatter.lean:459-474`) picks unicode vs ASCII by `pp.unicode` and `preserveForPP`. The template
  must record which spelling the source used (the projection already has the atom text) and its gap;
  RSF-IMPL confirms the gap is spelling-independent (it is declared once per side).
- **Non-symbol atoms.** `visitAtom`/raw atoms (`Formatter.lean:496-503`) and `ident` spacing
  (`Formatter.lean:476-485`, adjacency-only) are outside the declared-gap fact; they degrade to source
  bytes, which is the conservative default and correct for RLF-NOTATION's `a+b → a + b` scope.
