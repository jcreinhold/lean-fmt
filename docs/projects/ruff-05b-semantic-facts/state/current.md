---
kind: state
first_unresolved: none
---

# Current state

**Foundation stack COMPLETE — RSF-SPEC, RSF-IMPL, RSF-FINAL all verified** (2026-07-17). It exists because `ruff-03`'s reflowing
formatter and `ruff-11`'s compiler-backed rules both need the same missing infrastructure — a
semantic fact tier — and neither should own infrastructure the other depends on. `ruff-05` shipped
`Tier` with `source` and `syntax` only, deliberately, and named the semantic tier as future work
(`ruff-05` state: "a tier nothing can produce is a tier nothing tests"). This stack builds it.

The first fact is declared notation/atom spacing, captured where the frontend `Environment` is live
from the notation's **registered formatter** (RSF-SPEC F1 corrected the earlier "token table" premise:
the parser trims the symbol, so only the formatter's untrimmed `sym` carries the gap), and carried as
an immutable projection in a bumped `ModuleArtifact` (`v3` → `v4`). It unblocks operator
canonicalization and margin line-breaking in `ruff-03` reflow; the same tier later carries `ruff-11`'s
elaboration facts.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-spec | RSF-SPEC | verified | — |
| 02-impl | RSF-IMPL | verified (re-implemented) | RSF-SPEC |
| 03-final | RSF-FINAL | verified | RSF-IMPL |

## Repair (2026-07-17, prompt-repair) — capture mechanism was module-broken, now fixed

The RSF-FINAL audit found RSF-IMPL's notation-spacing capture empty on `module`-mode files (~99% of
mathlib: 60/62 sample, 8194/8264 of `Mathlib/`). Cause: it read the notation decl's **kernel value**
(`env.find? kind >>= (·.value?)`, an `Expr`), which the module system strips for imported constants
(even under `import all`). RSF-SPEC never chose this; it named the registered formatter as authoritative
and (`notes/01-semantic-facts.md` §5) "a data-only atom store, if one exists" as preferred. That store
exists and is module-safe — **`evalConst Lean.ParserDescr kind`** (compiled meta IR, retained in module
mode; the route the parser and pretty printer already use).

**Re-implemented and re-verified (2026-07-17).** `LeanFmt/Analysis.lean` now reads each present kind's
descriptor via `env.evalConst Lean.ParserDescr options kind` (type-guarded to
`ParserDescr`/`TrailingParserDescr` exactly as `Lean/PrettyPrinter/Basic.lean` `runForNodeKind`), with
a `ParserDescr` walker (`descrAtoms`) replacing the old `Expr` walker; `captureNotationSpacing` is now
`unsafe` (its caller already is). A **module-mode acceptance test** was added in two places: a
`LeanFmtTest.lean` `run_cmd` asserting core `«term_+_»`/`«term_*_»`/`«term-_»` have `value? = none` yet
capture `" + "`/`" * "`/`"-"`; and `tests/semantic/Notation.lean` converted to `module` mode so the
end-to-end `__analyze-exact` harness proves non-empty capture for imported operators on production
code. All suites (build, tests, boundary, modes, check, compiler, semantic, structural) pass. RSF-IMPL
is verified; RSF-SPEC stayed verified throughout.

**RSF-FINAL re-audited and verified (2026-07-17).** The differential (`tests/semantic/run.sh`) is green
on the module-mode fixture — core `+`/`*` (imported, value-stripped) and corpus `⊕corpus` all predict
Lean's own `ppTerm` emission byte for byte, non-vacuously. The cost envelope was re-measured on the
fixed capture: on the frozen 62-file module-mode sample the semantic pass captured **2999** notations
(baseline 0), vs. the prior near-no-op of 68, at peak RSS ~2.10 GiB (Δ +1.8 MiB, wall within noise),
well within the 8 GiB / 256 MiB ceiling. Evidence: `evidence/03-cost-envelope.txt`,
`results/03-final.md`. **The stack is complete.**

## RSF-SPEC — what it settled (`notes/01-semantic-facts.md`, `results/01-spec.md`)

- **F1 — declared spacing is a formatter pp-hint, not a token-table entry.** The parser trims the
  symbol (`Lean/Parser/Basic.lean:1114`; `Token := String`, `Types.lean:37,39`); only the formatter's
  untrimmed `sym` (`Formatter.lean:442-446`) carries the gap, which `pushToken` turns into a breakable
  `Format.line` (`Formatter.lean:412-414`). The compiler documents it as a pp-hint
  (`Init/Prelude.lean:5389`). Evidence: `evidence/01-declared-spacing.txt`. The roadmap stop-rule and
  the ruff-03 reflow note were corrected from "parser/token table" to "registered formatter."
- **F2 — no import-closure growth.** `import Lean` is already in the plugin closure
  (`ArtifactModel.lean:4`); `tests/boundary/run.sh` bans only lean-fmt's own volatile modules
  (`LeanFmt.Rules`/app), not Lean core. Reading the formatter tables is closure-legal.
- **F3/F4 — two producers, one demand-gated.** Always-on plugin
  (`CompilerPlugin.lean:26-39`) emits `semantic = none`; on-demand `analyzeExact`
  (`Analysis.lean:53-87`, final command state at line 77, currently discarded) emits `semantic = some`
  only when the run's required tier reaches `semantic`. `format` always does, so it drives a fresh
  `analyzeExact` and pays a recorded cost. This is honest demand-gating, not an always-on tax.
- **Representation chosen: Design B — per-kind ordered spacing template.** One entry per distinct
  `SyntaxNodeKind` present (atoms ordered by position), over Design A (per-node inline gaps). The
  multi-atom `«term_≃[_]_»` fixture rejects per-*token* keying: the key is (syntax-kind, atom position).
- **Specified for RSF-IMPL:** `Tier.semantic` (lattice `source ≤ syntax ≤ semantic`; formatter demand
  outside the rule fold); `ModuleArtifact.semantic : Option SemanticProjection := none` at schema
  `lean-fmt.module-artifact.v4` (additive; `v3` misses); demand-gating cost model (plugin `none`,
  `analyzeExact` `some` on demand; the semantic table is part of the digest).

## RSF-IMPL — what it delivered (`results/02-impl.md`)

- **`Tier.semantic` in the engine** (`Rules.lean`): lattice `source ≤ syntax ≤ semantic`, with
  `Tier.satisfies` extended over all nine cases. **No `Facts.semantic`/`RuleImpl.semantic` case** — the
  notation fact's consumer is the formatter, not a rule; `ruff-11` adds semantic *rules*. So the tier
  has a real producer + consumer + test, not the empty tier `RuleInfo.input` rotted into.
- **`ModuleArtifact` at schema `v4`** (`ArtifactModel.lean`): additive optional
  `semantic : Option SemanticProjection := none`; `SemanticProjection`/`NotationSpacing` follow Design
  B (one entry per distinct `SyntaxNodeKind`, atoms by position, keyed by kind). `v3` is a clean miss;
  a fieldless payload decodes total-ly to `none` then misses on the schema guard.
- **Capture in `analyzeExact`** (`Analysis.lean`): reads each present kind's untrimmed atom strings
  (`ParserDescr.symbol`/`.nonReservedSymbol`/`.unicodeSymbol`) as pure data — no formatter run, no
  `Environment` escaping; `sepBy` separators and non-notation kinds degrade to source bytes. The
  descriptor is read via **`evalConst Lean.ParserDescr kind`** (module-safe compiled meta IR),
  type-guarded to `ParserDescr`/`TrailingParserDescr`. (The first pass read the kernel decl *value*
  via `value?`, which the module system strips → empty capture on module-mode files; that defect was
  caught by the RSF-FINAL audit and fixed here — see Repair above.)
- **Demand-gating** (`Config.lean` `RulePlan.demandedTier`, `Application.lean`): a canonical-rendering
  run demands `.semantic`; the plugin artifact (always `none`) is then not fetched, so `format` re-runs
  `analyzeExact` with `captureSemantic := true` — the recorded cost, and the rejection of the fact-free
  artifact. `captureSemantic` is a trailing optional subprocess arg, so the syntax-only path and every
  existing harness are byte-unchanged.
- **Plugin untouched.** `CompilerPlugin.lean` still passes no `semantic` (emits `none`); its import
  closure and Lake glob did not grow (`tests/boundary/run.sh` passed).
- Checks: full build, in-process suite, boundary, modes, check, compiler suites, structural checker,
  `git diff --check` — all green.

## Design commitments (from the roadmap, verified in RSF-IMPL execution unless noted)

- **Facts are immutable data, never a live `Environment`.** Capture happens at the on-demand
  `analyzeExact` producer (RSF-SPEC F3/F4; not the always-on plugin) and crosses the boundary as
  serializable spacing, matching `ruff-11`'s standing contract. ✓ built.
- **`Tier.semantic` is added to the engine**, folded through `requiredTier` and mixed-tier planning;
  selection stays a projection over facts.
- **Schema bumps `v3` → `v4`, additively.** The lossless `source` projection is unchanged; the
  semantic fact sits beside it and enters the digest.
- **Demand-gating is honest.** No semantic capture when nothing needs it; `format` always needs the
  notation fact, so it demands the semantic artifact — a recorded cost, not a hidden one.
- **The plugin's import closure must not grow** (`tests/boundary/run.sh` pins it): the plugin is linked
  into every target build, so the spacing lookup must use modules already in closure or the change
  stops and is recorded.

## Blockers and prerequisites

- Prerequisite stacks `ruff-01-lossless-source` and `ruff-05-rule-engine` are verified.
- If live code contradicts a prerequisite's results, reopen the owning prerequisite rather than
  patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
