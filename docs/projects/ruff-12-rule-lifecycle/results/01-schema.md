---
kind: result
claim_id: RRL-SPEC
status: verified
---

# RRL-SPEC — lifecycle, selector, `explain`, and generated-doc interface, frozen

The rule catalog's lifecycle model, selector algebra, fixability configuration, `explain` surface,
generated-doc layout, and build/test-time invariants are specified precisely enough for `RRL-IMPL`,
and every current code is mapped into the model without breaking FMT001/FMT002. The design is
`notes/01-schema.md`; the verbatim baseline it maps is `evidence/01-schema-catalog.md`. As with the
prior `*-SPEC` prompts (`ruff-11` RMR-SPEC), **no production Lean interface, rule, or config key ships
in this prompt** — the freeze is the note plus the mapping; `RRL-IMPL` wires it.

## What was decided

- **Lifecycle splits the overloaded `defaultEnabled` field into two axes.** Today "preview" is spelled
  `defaultEnabled := false` and that field's only job is the `all`/`default` split
  (`Config.lean:191-206`). The freeze introduces `Lifecycle = stable | preview | deprecated` on
  `RuleInfo`, orthogonal to `defaultEnabled`, plus `retired` as a reserved-table state (not an enum
  value — a retired code has no `RuleImpl`). The four states partition every non-meta code.
- **Current mapping (honest, evidence-driven).** FMT003–FMT007 → **stable** (shipped, default-on,
  meaning frozen since ruff-08/09). FMT008–FMT017 → **preview** (all default-off; none has had the
  frozen-sample precision review `RRL-FINAL` requires before default-on). FMT001/FMT002 → **retired**
  (folded into canonical formatting). FMT900/901 → **meta** self-diagnostics, reserved, not selectable.
  No preview rule is promoted here: stability is `RRL-FINAL`'s call on evidence.
- **Preview gates selection (design B, chosen over advisory-only).** `all`/`default`/category expand to
  stable rules only unless preview mode (`--preview` / `preview = true`) is on; an explicit
  preview-code selection without the gate is a *specific* error, never a silent drop. The gate is a
  projection over selection in `RulePlan`, never touching `runRules`, the cache key, or fact
  acquisition — the same discipline that already keeps a rule from reading its own enablement. Design A
  (advisory label, selection unchanged) was rejected: it cannot satisfy the contract's "experimental
  rules require preview" (`notes/01-schema.md` §3).
- **Deterministic precedence = ruff's specificity model.** exact code > category > `all`/`default`;
  tie → ignore wins. `select`/`extend-select`/`ignore` layered across config/CLI (§5.4). Verified by
  hand that every `testConfig` assertion survives (the pinned cases have no differing-specificity
  same-rule conflict); the one changed shape (`--select FMT010 --ignore redundancy`) has no current
  test and is called out for `RRL-IMPL`.
- **Fixability configuration is a third axis.** `fixable`/`unfixable`/`extend-fixable` select which
  rules `fix` applies, beside rule-selection and the existing safe/unsafe applicability overrides. A
  selected-but-unfixable rule is still reported; only its fix is withheld (today's `withheldUnsafe`
  treatment). Also a `RulePlan` projection (§6).
- **"Without breaking FMT001/FMT002" = graceful degradation, specified as a floor.** A reserved/retired
  code is an accepted selector token that resolves to no rule and emits a deterministic retirement
  notice (today it is a hard `unknown rule selector` error — a break); a suppression naming only
  reserved codes is inert, not FMT900-flagged (today it would nag as "unused") (§7).
- **`explain`, generated docs, and JSON schema derive from one metadata source.** `RuleInfo` gains
  `explanation` and executable `examples` (bad→good); `explain RULE`, `docs/rules/{index,FMT###}.md`,
  and the `lean-fmt.toml` schema fragments are all projections over `allRuleInfos` + the reserved
  table, with a deterministic drift check that is simultaneously the undocumented-rule and
  documentation-link invariant (§8–§10).
- **The build/test invariants** (unique/shaped codes, namespace disjointness, lifecycle/default
  coherence, documented, valid executable examples, no doc drift, reserved integrity) are enumerated as
  a `testCatalogInvariants` spec, with the note that semantic-rule examples (FMT014–017) must run
  through the real-frontend `tests/semantic/run.sh` harness, not a faked projection (§10).

## Scope boundaries honored

- Hierarchical config, Git ignores, and `[format]`/`[lint]` sections stay `ruff-13` — the freeze adds
  keys to the existing single-file `lean-fmt.toml`, nothing more.
- Report formats (concise/GitHub/SARIF/JUnit) stay `ruff-15` — the freeze adds `explain` and
  `rules --docs` surfaces, not new `check`/`fix` encodings.
- `LeanFmt.Rules` stays out of the compiler-plugin closure — every new `RuleInfo` field is read only by
  the reporting process (`docs/adding-a-rule.md`; `tests/boundary/run.sh`).

## Commands and raw evidence

Toolchain `leanprover/lean4:v4.32.0`; lean-fmt `bef35fe` (pre-change HEAD); `Darwin arm64`.

- Baseline build (clean): `LEAN_NUM_THREADS=1 lake build` → exit 0.
- Catalog captured verbatim: `lean-fmt rules` and `rules --json` → `evidence/01-schema-catalog.md`
  (15 live rules; FMT001/FMT002 confirmed absent from the listing; FMT900/901 grepped from
  `Suppression.lean`).
- Naming clash scan: `grep -rInE 'Lifecycle|Stability|RuleExample|explanation|extend-select|Catalog|
  generate-docs|--preview' LeanFmt/` → no existing type, field, key, or flag by any proposed name
  (only the CLAUDE.md prose "hide lifecycle"). The proposed identifiers are clash-free.
- Structural checks: KanProofs structural checker `--structural` and `write_next.py --check` for this
  stack — run below and recorded in `state/current.md`; `git diff --check` clean (docs only).

No `lake build` change was needed because this prompt ships no `.lean` edit — the SPEC deliverable is
the note, the mapping, and the evidence, per the `*-SPEC` convention.

## Remaining uncertainty

Carried into `RRL-IMPL` (`notes/01-schema.md` §13): the precedence-change blast radius beyond
`testConfig`; whether `rules --json` inlines `explanation`/`examples` (verbose) or keeps them to
`explain`/docs; the fixture cost of semantic-rule executable examples; and whether to add an optional
distinct advisory for a retired-only suppression on top of the frozen inert floor.
