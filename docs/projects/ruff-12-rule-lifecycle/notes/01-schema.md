# RRL-SPEC — Rule lifecycle, selector semantics, `explain`, and generated docs

This note **freezes the interface** ruff-12 implements. It is the design; `RRL-IMPL`
(`02-generation`) wires it and `RRL-FINAL` (`03-acceptance`) audits it. Where a decision changes
today's observable behavior, that is called out explicitly and the owning characterization test named,
so `RRL-IMPL` changes exactly what the freeze says and nothing else.

Everything here is read off live code, cited by file:line, and the current catalog is captured verbatim
in `evidence/01-schema-catalog.md`.

## 1. Scope, and what this stack does **not** own

ruff-12 owns: **lifecycle states** (stable / preview / deprecated / retired), the **selector algebra**
(`all`/`default`/category/code, the preview gate, deterministic precedence), **fixability
configuration** (`fixable`/`extend-fixable`/`unfixable`) beside the existing applicability overrides,
the **`explain RULE`** command, **generated rule documentation**, and the **build/test-time metadata
invariants**.

It does **not** own, and this note must not design:

- Hierarchical config discovery, Git-ignore awareness, or `[format]`/`[lint]` config sections — those
  are `ruff-13-config-discovery` (`ruff-class-roadmap.md:43`). ruff-12 stays on the **single-file
  `lean-fmt.toml`** model that `Config.lean` already parses; it only adds keys to it.
- Output/report *formats* (concise, GitHub, SARIF, JUnit) — those are `ruff-15-reporting`
  (`ruff-class-roadmap.md:45`). ruff-12 adds the `explain` and `rules --docs` *surfaces*, not new
  report encodings for `check`/`fix`.
- Any execution-strategy, worker, cache-identity, or superset-parsing change (roadmap stop rules).

The load-bearing architectural fact this stack must not break: **`LeanFmt.Rules` is not in the compiler
plugin's link closure** (`docs/adding-a-rule.md` "Rules do not run in the compiler";
`tests/boundary/run.sh`). Every field this note adds to `RuleInfo` — `explanation`, `examples`,
`lifecycle` — lives in `Rules.lean` and is read only by the reporting process, never by
`CompilerPlugin.lean`. Adding them cannot enlarge the closure, and the boundary test must still pass
after `RRL-IMPL`.

## 2. The current catalog, mapped (baseline → lifecycle)

Read from `LeanFmt/Rules.lean:617-849` and `lean-fmt rules` (evidence file). Every code the product
knows today, with the lifecycle state this note assigns it:

| Code | Category | Tier | Fixable | Default | **Lifecycle** | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| FMT003 | security | source | no | on | **stable** | control bytes |
| FMT004 | security | source | no | on | **stable** | bidi marks |
| FMT005 | imports | source¹ | yes | on | **stable** | duplicate import |
| FMT006 | imports | source¹ | no | on | **stable** | redundant import |
| FMT007 | imports | source¹ | no | on | **stable** | import order |
| FMT008 | docs | syntax | no | off | **preview** | module docstring |
| FMT009 | structure | syntax | no | off | **preview** | unclosed scope |
| FMT010 | redundancy | syntax | yes | off | **preview** | duplicate attribute |
| FMT011 | redundancy | syntax | yes | off | **preview** | duplicate deriving |
| FMT012 | debug | syntax | no | off | **preview** | dev `set_option` |
| FMT013 | redundancy | syntax | yes | off | **preview** | nested parens |
| FMT014 | deprecation | semantic | yes | off | **preview** | deprecated use |
| FMT015 | unused | semantic | no | off | **preview** | unused variable |
| FMT016 | unused | semantic | no | off | **preview** | unused section var |
| FMT017 | naming | semantic | no | off | **preview** | constructor-name var |

¹ `input` on the wire is `source` for the import family; its per-file read is the surface header, a
source-level fact (`Rules.lean:834-849`). It is not part of the `RuleImpl` linear-tier engine.

Reserved / terminal codes — **not** live rules, but part of the catalog namespace:

| Code | State | Disposition |
| --- | --- | --- |
| FMT001 | **retired** | line-boundary rule; folded into canonical formatting (`ruff-11c` RDF-LAYOUT; `Suppression.lean:192`, `Printer.lean:220,253,1903`). |
| FMT002 | **retired** | trailing-newline/eof rule; folded into canonical formatting. |
| FMT900 | **meta** | suppression self-diagnostic: *unused directive* (`Suppression.lean:327,335`). Always active, not selectable, not in `allRuleInfos`. |
| FMT901 | **meta** | suppression self-diagnostic: *malformed directive* (`Suppression.lean:199,263`). |

**Observation that drives the whole design:** today "preview" is not a state — it is spelled
`defaultEnabled := false`, and the `all`/`default` split is the *only* thing that field does
(`Config.lean:191-206`). Every default-off rule (FMT008–FMT017) is genuinely experimental: none has had
the frozen-sample precision review that `RRL-FINAL`'s prompt requires before a rule is enabled by
default. So the mapping is honest — the default-on rules are exactly the stable ones, and lifecycle
*splits the overloaded `defaultEnabled` field into two orthogonal axes* (§4).

## 3. One metadata source of truth

The completion contract requires that `rules`, `explain RULE`, config validation, JSON-schema
fragments, and human docs all derive from **one** description. That description is `RuleInfo`
(`Rules.lean:146-159`) plus the import-family `RuleInfo`s (`Rules.lean:802-824`), unioned in
`allRuleInfos` (`Rules.lean:829`). `RRL-IMPL` extends `RuleInfo` with:

```
structure RuleInfo where
  code           : String
  category       : String
  summary        : String          -- one imperative line (unchanged)
  fixable        : Bool
  defaultEnabled : Bool
  lifecycle      : Lifecycle       -- NEW: .stable | .preview | .deprecated  (§4)
  explanation    : String          -- NEW: long-form, ≥1 paragraph; drives `explain` + docs (§8,§9)
  examples       : Array RuleExample -- NEW: ≥1 executable bad→good pair (§8, §10 invariant 6)
  replacement?   : Option String := none  -- NEW: successor code, required iff .deprecated (§4)
  needsOccurrences : Bool := false -- unchanged (capture cost only)
```

with

```
inductive Lifecycle where | stable | preview | deprecated
  deriving …, ToJson, FromJson   -- wire spellings "stable"/"preview"/"deprecated"

structure RuleExample where
  bad   : String          -- source that must produce the rule's finding
  good? : Option String   -- post-fix source for a fixable rule; `none` for report-only
```

`retired` is deliberately **not** a `Lifecycle` constructor: a retired code has no `RuleImpl` and no
`RuleInfo`, so it cannot be an enum value on a live rule. Retirement is represented in a separate
reserved-code table (§7), which is what lets FMT001/FMT002 exist in the namespace without being live
rules. The four states of the catalog are therefore `{stable, preview, deprecated}` on live rules plus
`retired` as a reserved-table entry — a total, non-overlapping partition of every non-meta code.

### Interface design, considered twice

The abstraction this stack introduces is *the lifecycle field on `RuleInfo`*. Two shapes were weighed:

- **A — lifecycle as advisory metadata; selection unchanged.** `lifecycle` labels `rules`/`explain`/docs
  and drives invariants, but `all`/`default`/category/code selection stays exactly as
  `Config.lean:198-206` is today (`all` = every code, default-off rules freely selectable by code or
  category). Caller knowledge: minimal. Error surface: none new. But it **fails the completion
  contract** — "experimental rules require preview" — because a bare `--select FMT013` still silently
  activates an unstable rule, and `--select all` still rakes in every preview rule. The stability
  promise ("stable codes never silently change meaning") is unbacked: nothing stops a user from
  building CI on a preview rule and being surprised when its meaning shifts.

- **B — lifecycle gates selection (chosen).** `all`/`default`/category expand to **stable rules only**
  unless preview mode is on; a preview rule is reachable only under `--preview` / `preview = true`
  (§5). Caller knowledge: a run now carries one boolean (`preview`), threaded through `rulePlan`
  exactly where `cliSelect`/`cliIgnore` already thread. Invariants hidden below the caller: the whole
  preview/stable partition and the "explicit preview selection without the gate is a *specific* error,
  never a silent drop" rule. Exactness/cache identity: **unchanged** — the gate is a *projection over
  selection*, resolved in `RulePlan` like `RulePlan.findings` and `effectiveApplicability` already are
  (`Config.lean:249-273`); it never touches `runRules`, the result cache key, or which facts a run
  obtains. A rule still cannot read its own enablement. Memory/critical path: no new work; the gate is a
  set filter. This is the ruff model (`--preview`) and the one the roadmap asks for.

B wins because A cannot satisfy the contract. The cost of B is a **deliberate behavior change** (§5.4),
contained to selection resolution and covered by `testConfig`.

## 4. Lifecycle states and transitions

Two orthogonal axes, which today's single `defaultEnabled` field conflates:

- **Lifecycle** — the *stability promise*: `stable` (meaning frozen; a meaning change requires a new
  code), `preview` (experimental; meaning/behavior may change without a new code; gated), `deprecated`
  (superseded; still resolves for back-compat, warns on selection, carries a `replacement?`).
- **`defaultEnabled`** — whether an *active-eligible* rule is in the `default` set. A stable rule may be
  default-on (FMT003–007) or default-off (a stable opt-in rule — the cell is empty today but the model
  admits it, e.g. a strict style rule that is frozen but off by policy).

Transition graph (the only legal edges):

```
   (new rule)
       │
       ▼
    preview ──────────► stable ──────────► deprecated ──────────► retired
       │  (freeze meaning,   │ (superseded by     │ (grace period    (reserved
       │   review precision   │  another rule or    │  elapsed)         table §7)
       │   — RRL-FINAL gate)  │  by canonical fmt)  │
       └──────────────────────┴─────────────────────┴──► removed/retired
          (a preview rule may be dropped outright — it carries no promise)
```

Rules for each edge:

- **new → preview.** Every rule is born `preview`. A rule is never born `stable`: stability is earned
  with frozen-sample precision evidence, which is `RRL-FINAL`'s job (its prompt: "Every
  enabled-by-default rule must have reviewed frozen-sample precision"). This note therefore does **not**
  promote any of FMT008–FMT017 to stable — that is `RRL-FINAL`'s decision on evidence, not a design-time
  assumption.
- **preview → stable.** Allowed only with a recorded precision review. Promotion sets nothing else by
  itself; `defaultEnabled` is a separate, later choice.
- **stable → deprecated.** When a rule is superseded (by another rule, or — as FMT001/FMT002 were — by
  canonical formatting). Sets `replacement?`. A deprecated rule MUST be `defaultEnabled := false`.
- **deprecated → retired.** After a deprecation period; the code leaves `allRuleInfos` and enters the
  reserved table (§7). FMT001/FMT002 have already completed this path.
- **preview → removed.** A preview rule may be deleted outright (no stability promise); its code still
  enters the reserved table so it is never silently reused.

Coherence invariants enforced at test time (§10): `preview ⇒ ¬defaultEnabled`; `deprecated ⇒
¬defaultEnabled`; `deprecated ⇒ replacement?.isSome` and the replacement names a live-or-reserved code.

## 5. Selector algebra

### 5.1 Selector kinds

A selector token is exactly one of:

1. `all` — every **stable** rule (plus preview rules iff preview mode; never deprecated, never retired).
2. `default` — every stable rule with `defaultEnabled` (the plain-run set). Never preview/deprecated.
3. a **category** name (`security`, `imports`, `redundancy`, …) — derived from the registry, never a
   fixed list (`Config.lean:92-99`). Expands to that category's stable rules (plus its preview rules iff
   preview mode).
4. an exact **code** (`FMT###`).

**No numeric code-prefix selection** (`FMT01…`). This is the stop rule "a category prefix must be
unambiguous," resolved by construction: lean-fmt has a single code family (`FMT`), so a numeric prefix
buys nothing over `all`, and `FMT01` straddling FMT010–013 (and the retired FMT001) is exactly the
ambiguity to forbid. The **category** is lean-fmt's grouping selector, and it is unambiguous because
codes and category names occupy disjoint namespaces (invariant §10.3). The bare family prefix `FMT` is
**not** a selector (use `all`).

### 5.2 Namespace disjointness (the unambiguity invariant)

For selection to be decidable, the tokens must not collide. Enforced at test time (§10.3):

- Every code matches `FMT\d{3}` (also the suppression code shape, `Suppression.lean:94`).
- No category name matches `FMT\d{3}`, and no category equals a reserved word `{all, default, preview}`.
- The reserved word set `{all, default}` and (new) mode word `preview` never name a rule or category.

So resolving a token is total: try reserved words, then category membership, then exact code, then the
reserved/retired table (§7), else error.

### 5.3 The preview gate

Preview mode is off by default. It is turned on by a new `--preview` CLI flag or a `preview = true`
config key (single-file `lean-fmt.toml`; hierarchical discovery stays `ruff-13`). With preview off:

- `all`, `default`, and category selectors expand to **stable rules only**.
- An exact preview-code selector (`--select FMT013`) is a **specific error**, not a silent drop and not
  the generic "unknown rule selector": `rule FMT013 is in preview; enable preview mode (--preview) to
  select it`. Discoverable, deterministic, and it never silently reports nothing.

With preview on, preview rules join `all`/category expansions and exact preview-code selection
succeeds. Preview mode never enables a rule by itself — it only makes preview rules *reachable* by an
otherwise-normal selection. `default` is unaffected by preview mode (a preview rule is never
default-on, invariant §10.4).

### 5.4 Deterministic precedence (select / extend-select / ignore)

Adopt ruff's **specificity-ranked** resolution, which is deterministic and matches the reference
product. Specificity, high → low: **exact code > category > `all`/`default`**. For each candidate rule,
the highest-specificity selector that names it, across the enabling set (`select` ∪ `extend-select`)
and the disabling set (`ignore`), decides. On a tie at equal specificity, **`ignore` wins** (ruff's
rule). Layering of the three verbs across config and CLI:

- **select**: CLI `--select` replaces config `select`; absent both, the base is `default`.
- **extend-select**: config `extend-select` and CLI `--extend-select` both *add* to the selected set;
  neither replaces.
- **ignore**: config `ignore` and CLI `--ignore` both *apply*; they remove.

This generalizes today's flat rule (`Config.lean:216-237`, "ignores win over selects within that
layer") into the specificity model. **Existing behavior is preserved on every case `testConfig` pins**,
because those cases have no same-rule select/ignore conflict at differing specificity:

- `select=[security] ignore=[FMT004]` → active `{FMT003}`: exact-ignore `FMT004` beats category-select
  `security` → FMT004 off. Same result as today (`testConfig:441`).
- `--select FMT004 --ignore FMT003` → `{FMT004}`: disjoint codes. Same (`testConfig:447-451`).
- `--select security` → `{FMT003,FMT004}`. Same (`testConfig:456-459`).

The one case that *changes* is a same-rule conflict at differing specificity, e.g. `--select FMT010
--ignore redundancy`: today's flat "ignore wins" drops FMT010; the specificity model keeps it
(exact-select beats category-ignore). No current test asserts that case; `RRL-IMPL` adds one and the
note records the change here.

`extend-select` is new configuration and CLI surface. It exists so a project can add rules on top of
`default` without restating the default set (the ruff idiom). Precedence identical to `select` for
specificity; it only differs in that it never *replaces*.

## 6. Fixability configuration

Today fixability is a single rule property (`RuleInfo.fixable`, `Rules.lean:150`) and the only
fix-related config is applicability reclassification (`extend-safe-fixes`/`extend-unsafe-fixes`,
`Config.lean:145-146`). ruff-12 adds a **fix-selection axis**, orthogonal to rule-selection and to
applicability, mirroring ruff's `fixable`/`unfixable`/`extend-fixable`:

- `fixable` (config selector-list) — the set of rules whose fixes `fix` may apply. Default `all`.
- `unfixable` — removes from that set.
- `extend-fixable` — adds to it.
- Resolution: the **same specificity model** as §5.4, over fix-enable / fix-disable selectors.

Composition — a fix is **applied by `fix`** iff all hold:

1. the rule is **selected** (§5), and
2. the rule is in the **effective-fixable** set (this axis), and
3. the fix's **effective applicability is admitted** under `--unsafe-fixes`
   (`RulePlan.effectiveApplicability` + `Applicability.admitted`, `Config.lean:249-256`).

A rule that is selected but not effective-fixable is still **reported** with its finding; only its fix
is withheld — exactly today's treatment of a withheld unsafe fix (`Cli.lean:186-187`,
`report.withheldUnsafe`). This axis is a **projection in `RulePlan`**, resolved beside
`effectiveApplicability`; it never enters `runRules`, the cache key, or fact acquisition, and a rule
never reads it (same discipline as selection). Applicability overrides
(`extend-safe-fixes`/`extend-unsafe-fixes`, `--unsafe-fixes`) are unchanged and remain the *safe/unsafe*
axis; `.displayOnly` stays a floor no configuration lifts (`Config.lean:250-256`).

## 7. Reserved and retired codes — "without breaking FMT001/FMT002"

A **reserved-code table** (new, in `Rules.lean`) maps each non-live code to a disposition:

```
FMT001 → retired "folded into canonical formatting (see `format`)"
FMT002 → retired "folded into canonical formatting (see `format`)"
```

(FMT900/901 are *meta* self-diagnostics, not selectable and not in this table — but §10.1 forbids any
live rule from reusing 900/901.) The table's whole job is **graceful degradation**, because the roadmap
requires mapping current codes "without breaking FMT001/FMT002." A legacy config or suppression that
still names them must keep working, not start erroring:

- **In a selector** (`--select FMT001`, `select = ["FMT001"]`): today this is a hard
  `unknown rule selector` error (`Config.lean:101-105`) — a *break* for any surviving config. New
  behavior: a retired code is an **accepted selector token** that resolves to no live rule and emits a
  one-line, deterministic **retirement notice** to stderr (`rule FMT001 was retired: <disposition>;
  remove it from your selection`). The run proceeds; exit status is unaffected by the notice. This keeps
  historical configs valid while telling the author the code is gone and why.
- **In a suppression** (`-- lean-fmt: ignore[FMT001]`): the code is `isCodeShape`-valid
  (`Suppression.lean:94`), so it parses today, but the directive suppresses nothing and is therefore
  reported **unused (FMT900)** — a misleading nag, since a retired code can never produce a finding to
  suppress. New behavior: a suppression naming **only** reserved/retired codes is **inert** — it
  suppresses nothing and is **not** FMT900-flagged. (A directive mixing a retired code with a live one
  keeps normal per-code unused analysis for the live codes.) An optional, distinct "names a retired
  rule" advisory is left to `RRL-IMPL`/`RRL-FINAL`; the freeze here is only the non-breaking floor:
  retired-only suppressions are silently accepted.

This is the exact reading of the stop rule: FMT001/FMT002 references degrade to *clear, stable,
non-fatal* outcomes rather than confusing generic errors or false "unused" findings.

## 8. `explain RULE`

New subcommand `lean-fmt explain FMT013` (text) / `--json`. It is CLI *presentation* over one
`RuleInfo` (`LeanFmt.Cli`, beside `renderRules`, `Cli.lean:225-232`); all content comes from the
registry. Text layout (deterministic, one rule):

```
FMT013  redundant nested parentheses  [preview]
  category: redundancy   tier: syntax   fix: safe   default: off

  <explanation — the RuleInfo.explanation paragraph(s), rewrapped>

  Example
    - bad -
    <examples[0].bad>
    - good -
    <examples[0].good?>            (omitted for a report-only rule)

  Select:    --select FMT013   |   --select redundancy
  Suppress:  -- lean-fmt: ignore[FMT013]
  Docs:      docs/rules/FMT013.md
```

- A **retired** code: `explain FMT001` prints the retirement disposition from the reserved table (§7)
  and exits 0 — `explain` is discovery, so it answers for retired codes too.
- An **unknown** token (neither live, category, nor reserved): a specific error, exit 2, like the
  selector path.
- `--json` emits the full `RuleInfo` (all new fields included) plus `lifecycle`, `tier`, and resolved
  `selectors`/`suppression`/`docsPath` — the same object the doc generator consumes, so `explain --json`
  and the generated page can never disagree.

## 9. Generated documentation

One generator, pure and deterministic, turning `allRuleInfos` (+ reserved table) into markdown. It
lives in a lower layer (a new `LeanFmt.Catalog`, or `Rules.lean` itself) as `Facts → String`-style pure
functions; `LeanFmt.Cli` writes them. Layout under `docs/rules/`:

- `docs/rules/index.md` — a table of every live rule (code, category, lifecycle, default, fix, summary),
  grouped by category, sorted by code within a group; plus a short "retired codes" section from the
  reserved table. Generated, never hand-edited.
- `docs/rules/FMT###.md` — one page per live rule: heading, the `[lifecycle]` badge, the metadata line
  (category/tier/fix/default), the `explanation`, every `example` as a fenced bad/good pair, the
  selectors, the suppression spelling, and — for a `deprecated` rule — the `replacement?` migration
  line.

Determinism and drift: generation sorts by code and takes no ambient input, so the same registry always
yields byte-identical files. A **drift check** (`lean-fmt rules --docs --check`, or a test) re-generates
into memory and diffs against the committed tree; a mismatch fails, which is simultaneously the
"undocumented rule" and "documentation link check" invariant (§10.5/§10.7). The generator is invoked
through the same `rules` command family; it is presentation, not a new report format (so not
`ruff-15`).

## 10. Build/test-time invariants (the "detect" contract)

`RRL-IMPL` adds a `testCatalogInvariants` (owning layer: `LeanFmtTest.lean`, beside `testEngineTiers`
`:633` and `testConfig` `:415`). The completion contract's four detections map to these checks:

1. **Unique / well-shaped codes.** No two live rules share a code; no live code equals a reserved or
   meta (FMT900/901) code; every code matches `FMT\d{3}`.
2. **Category present & shaped.** Every rule has a nonempty category; no category is empty.
3. **Namespace disjointness (§5.2).** No category equals any code or reserved word `{all, default,
   preview}`.
4. **Lifecycle/default coherence (§4).** `preview ⇒ ¬defaultEnabled`; `deprecated ⇒ ¬defaultEnabled`;
   `deprecated ⇒ replacement?` names a live-or-reserved code. (Detects "lifecycle contradictions.")
5. **Documented.** Every live rule has a nonempty `explanation` and ≥1 example. (Detects "undocumented
   rules.")
6. **Valid, executable examples.** For each rule and each example: `bad` run through the rule produces
   ≥1 finding of that code; for a fixable rule, applying the emitted fix to `bad` yields exactly
   `good?`; for a report-only rule, `good? = none` and the finding carries `fix? = none`. (Detects
   "invalid examples." This is the "executable examples sourced from the registry" of `RRL-IMPL`.)
7. **No doc drift (§9).** Regenerated docs equal the committed `docs/rules/` tree.
8. **Reserved integrity (§7).** FMT001/FMT002 are reserved (absent from `allRuleInfos`); a retired-code
   selector is accepted-with-notice and a retired-only suppression is inert.

Checks 1–5 and 8 are pure over the registry (cheap, always run). Check 6 runs each rule on its own tiny
fixtures — source-tier and syntax-tier rules run directly; a **semantic** rule's example (FMT014–017)
needs the exact frontend, so its executable check reuses the `tests/semantic/run.sh` real-frontend
harness rather than the pure in-process path (recorded here so `RRL-IMPL` does not try to fake a
semantic projection).

## 11. Wire and compatibility notes

- `lean-fmt rules --json` gains `lifecycle` on every object and keeps `input`/`fixable`/`defaultEnabled`
  (`Rules.lean:171-179, 840-849`). Additive — existing consumers keep their fields. `explanation`/
  `examples` appear in `explain --json` and the doc generator; whether `rules --json` also carries them
  is `RRL-IMPL`'s call (they are verbose for a catalog listing), but `explain --json` MUST carry them.
- New config keys: `select` (exists), `extend-select` (new), `ignore` (exists), `fixable`/`unfixable`/
  `extend-fixable` (new), `preview` (new), beside the existing `extend-safe-fixes`/`extend-unsafe-fixes`
  and `per-file-ignores`. All validated by `selectorsValid` (`Config.lean:101-105`), which §7 relaxes to
  accept reserved codes with a notice.
- New CLI flags: `--extend-select SELECTOR`, `--fixable`/`--unfixable`/`--extend-fixable SELECTOR`,
  `--preview`. Parsed in `Cli.lean:72-109` beside `--select`/`--ignore`.
- JSON-schema fragments for `lean-fmt.toml` (the completion contract's "JSON schema fragments") are
  generated from the same selector/lifecycle vocabulary — enumerating valid selectors (codes +
  categories + reserved words) and config keys. Owned here as generated output beside the rule docs.

## 12. What each successor prompt does

- **RRL-IMPL (`02-generation`).** Extend `RuleInfo` (§3); populate `lifecycle`/`explanation`/`examples`
  for all 15 live rules and the reserved table (§2, §7); implement the preview gate and specificity
  precedence in `RulePlan` (§5); add the fixability axis (§6); add `explain` (§8); add the doc/schema
  generator + drift check (§9); add `testCatalogInvariants` and the executable-example harness (§10).
  Update `testConfig` for the one changed precedence case (§5.4) and the retired-selector behavior (§7).
- **RRL-FINAL (`03-acceptance`).** Run the invariant suite, the executable examples, a
  select/extend-select/ignore precedence matrix, preview/deprecation migration cases, suppression
  interaction (including retired-only inertness), and doc drift. Decide, on **reviewed frozen-sample
  precision**, whether any FMT008–FMT017 preview rule graduates to stable and/or default-on — a decision
  this note deliberately leaves open (§4).

## 13. Remaining uncertainty

- **Precedence-change blast radius.** The specificity model changes exactly one shape of same-rule
  conflict (§5.4). I have checked every assertion in `testConfig` survives; `RRL-IMPL` must re-run the
  full suite and `tests/boundary`/`tests/modes` to confirm no unlisted caller depends on flat "ignore
  wins."
- **`rules --json` verbosity.** Whether to inline `explanation`/`examples` in the catalog listing or
  keep them to `explain`/docs is left to `RRL-IMPL` on output-size grounds; `explain --json` carries
  them regardless.
- **Semantic examples.** FMT014–017 executable examples need the real frontend (§10 check 6). The
  fixture cost and whether all four get a full bad→good example (FMT015–017 are report-only, so
  `good? = none`) is measured in `RRL-IMPL`, not assumed here.
- **Optional retired-rule advisory.** §7 freezes the non-breaking floor (accept/notice; inert
  suppression). Whether to additionally emit a distinct advisory code for a retired-only suppression is
  left to `RRL-IMPL`/`RRL-FINAL`.
