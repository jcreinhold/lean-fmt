---
kind: state
first_unresolved: none
---

# Current state

**RRL-FINAL is verified** (`results/03-acceptance.md`) — the ruff-12 stack is complete. The acceptance
audit ran the metadata invariants, executable examples, the full selector-precedence matrix,
preview/deprecation migrations, suppression interaction, and documentation link checks. It found and
fixed one frozen-spec gap — retired-only suppression inertness (`notes/01-schema.md` §7): a directive
naming only reserved/retired codes is now inert (suppresses nothing, no FMT900), where RRL-IMPL had
shipped only the selector half of §7. On the promotion question the model left open (§4/§12), **no
FMT008–FMT017 preview rule graduates to stable or default-on**: default-on is the frontend-free
security/correctness floor (FMT003–007) and the preview rules are opinionated syntax/semantic-tier
rules whose meanings are not yet frozen; their correctness was reviewed on the frozen sample by ruff-10/
ruff-11, and a fresh re-run was blocked by local mathlib4 toolchain drift (v4.33.0-rc1 vs this build's
v4.32.0), not run against the maintainer's working tree.

**RRL-IMPL is verified** (`results/02-generation.md`; design `notes/01-schema.md` §12). The registry now
carries `lifecycle`/`explanation`/`examples`/`replacement?` on every `RuleInfo` plus the FMT001/FMT002
reserved table; the preview gate and ruff specificity precedence resolve in the `RulePlan` projection
(never the cache key or fact acquisition); the fixability axis (`fixable`/`unfixable`/`extend-fixable`)
gates which selected rules' fixes `fix` applies; `explain` presents one rule (live/retired/unknown), and
`docs` generates `index.md` + `schema.json` + one page per rule (YAML frontmatter + body), drift-checked.
One metadata source projects to `rules`, `explain`, `docs/rules/*`, and the `lean-fmt.toml` schema.
`testCatalogInvariants` and `tests/catalog/run.sh` (executable examples through the exact frontend)
enforce it; the executable harness caught and corrected two false examples (FMT014 rename form, FMT016
section-var trigger). All affected suites pass under the new preview gate.

No FMT008–FMT017 rule is promoted; stability/default-on is `RRL-FINAL`'s decision on reviewed
frozen-sample precision.

**RRL-SPEC is verified** (`results/01-schema.md`; design `notes/01-schema.md`; baseline
`evidence/01-schema-catalog.md`). The lifecycle model, selector algebra, fixability configuration,
`explain` surface, generated-doc layout, and build/test-time invariants are frozen precisely enough for
`RRL-IMPL`, and every current code is mapped without breaking FMT001/FMT002. Following the `*-SPEC`
convention (`ruff-11` RMR-SPEC), no production Lean interface, rule, or config key shipped in that prompt.

Key frozen decisions:

- `Lifecycle = stable | preview | deprecated` on `RuleInfo`, orthogonal to `defaultEnabled`, with
  `retired` as a reserved-table state (FMT001/FMT002). Current mapping: FMT003–007 stable/default-on;
  FMT008–017 preview/default-off (no promotion — `RRL-FINAL` decides stability on frozen-sample
  precision); FMT900/901 meta self-diagnostics.
- Preview **gates** selection (design B): `all`/`default`/category expand to stable rules only unless
  `--preview`/`preview = true`; explicit preview-code selection without the gate is a specific error.
  The gate is a `RulePlan` projection — never `runRules`, the cache key, or fact acquisition.
- Deterministic precedence = ruff specificity (exact > category > `all`/`default`; tie → ignore).
  `select`/`extend-select`/`ignore` layered across config/CLI. Every `testConfig` assertion verified to
  survive; the one changed shape (`--select FMT010 --ignore redundancy`) is untested today and flagged
  for `RRL-IMPL`.
- Fixability config (`fixable`/`unfixable`/`extend-fixable`) is a third `RulePlan` axis beside selection
  and the safe/unsafe applicability overrides.
- FMT001/FMT002 degrade gracefully: accepted-with-notice as selectors, inert (not FMT900) as
  suppressions — the non-breaking floor.
- One metadata source (`RuleInfo` + reserved table) generates `rules`, `explain`, `docs/rules/*`, and
  `lean-fmt.toml` schema fragments, with a deterministic drift check.

Prerequisite stacks `ruff-07`…`ruff-11` are verified; their live code was re-read for this spec
(`Rules.lean`, `Config.lean`, `Cli.lean`, `Suppression.lean`, `Application.lean`). If live code
contradicts a prerequisite result, reopen the owning prerequisite rather than patching around it. Full
mathlib is not development evidence.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-schema | RRL-SPEC | verified | — |
| 02-generation | RRL-IMPL | verified | RRL-SPEC |
| 03-acceptance | RRL-FINAL | verified | RRL-IMPL |

## Blockers and prerequisites

- No blocker recorded. `RRL-IMPL` implements `notes/01-schema.md` §12; open questions are in §13.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
