---
kind: roadmap
topic: "Ruff-class lean-fmt product family"
main_results: [RCP-ACCEPT]
prereq_stacks: [execution-core-v2]
blueprint_tracked: false
---

# Ruff-class lean-fmt project family

## Goal

Turn the exact, memory-safe native Lean execution core into a full Lean formatter and high-value
linter with the workflow quality users expect from Ruff. This is a family index, not an executable
stack: each row below names an independently resumable prompt stack with its own roadmap and state.

The product remains pure Lean unless a later stack records a named missing Lean capability and a
measured end-to-end reason for a smaller foreign component. Exact ordered imports, search-path
precedence, file-local syntax, toolchain identity, atomic publication, and the 8 GiB aggregate
envelope remain non-negotiable.

## Dependency order

| Order | Stack | Product capability | Prerequisites |
| --- | --- | --- | --- |
| 1 | `ruff-01-lossless-source` | Lossless tokens, trivia, comments, and compiler artifact | execution core |
| 2 | `ruff-02-layout-core` | Deep document/layout engine and comment attachment | 01 |
| 3 | `ruff-03-language-formatting` | Complete Lean command, term, tactic, and macro formatting (phase 1 conservative, verified; phase 2 reflow) | 02; phase-2 reflow also 05b |
| 4 | `ruff-04-formatter-product` | Stable formatter policy and batch product semantics | 03 |
| 5 | `ruff-05-rule-engine` | Source/syntax rule capabilities and contribution API | 01 |
| 5b | `ruff-05b-semantic-facts` | Semantic fact tier: `Tier.semantic`, `Environment` capture, artifact `v4`, notation-spacing fact | 01, 05 |
| 6 | `ruff-06-fix-safety` | Safe/unsafe/display-only fixes and atomic fix-all | 04, 05 |
| 7 | `ruff-07-suppressions` | Inline/file suppressions and unused-suppression diagnostics | 05 |
| 8 | `ruff-08-source-rules` | High-confidence raw-source rules | 05, 06 |
| 9 | `ruff-09-import-rules` | Duplicate, ordering, grouping, and redundant-import analysis | 01, 05, 06 |
| 10 | `ruff-10-syntax-rules` | High-value exact-syntax lint rules | 01, 05, 06 |
| 10b | `ruff-10b-syntax-fix-composition` | Canonical-coordinate syntax-tier fix composition (`fix` applies syntax `.safe` fixes via re-projection) | 04, 06, 10 |
| 11 | `ruff-11-semantic-rules` | Compiler/elaboration-backed lint rules (consume 05b's semantic tier) | 05, 05b, 06 |
| 11b | `ruff-11b-owned-semantic-fix` | Owned, fixable deprecation rule (`fix` applies FMT014's unsafe rename via info-tree occurrence capture) and the semantic capability split | 06, 10b, 11 |
| 11c | `ruff-11c-decouple-fix-format` | Decouple lint-fix from formatting: `format`/`diff` reflow only, `fix`/`check --fix` apply fixes at original coordinates (retires the canonical-coordinate fix composition) | 06, 09, 10b, 11b |
| 11d | `ruff-11d-format-in-place` | `format` writes canonical layout in place by default (like `ruff format`) via the `ruff-06` guarded publish; `format --check` is the non-writing CI preview | 04, 06, 11c |
| 12 | `ruff-12-rule-lifecycle` | Stable/preview/deprecated rules, explain, generated docs | 07–11 |
| 13 | `ruff-13-config-discovery` | Hierarchical config, Git ignores, formatter/linter sections | 04, 11d, 12 |
| 14 | `ruff-14-stream-range` | stdin/stdout and range formatting | 04, 11d, 13 |
| 15 | `ruff-15-reporting` | Concise, GitHub, SARIF, and JUnit reporting | 12, 13 |
| 16 | `ruff-16-watch-incremental` | Watch and changed-files workflows | 13, 15 |
| 17 | `ruff-17-lsp` | Native LSP diagnostics, formatting, and code actions | 06, 07, 13, 14 |
| 18 | `ruff-18-integrations` | Shell completions, pre-commit, CI and editor setup | 15–17 |
| 19 | `ruff-19-performance` | Regression budgets and measured private concurrency decision (also owns the `ruff-01` artifact-granularity and `ruff-10b` re-projection-cost revisits) | 01, 04, 10b, 12, 17 |
| 20 | `ruff-20-acceptance` | Fresh Ruff-class product, architecture, and mathlib audit | 18, 19 |

## Coverage contract

Together the stacks cover every gap identified in the July 2026 product inventory: a canonical
whole-language formatter; a useful rule catalog; import organization; fix applicability;
suppressions; rule explanations and lifecycle; stdin and range operation; hierarchical and
Git-aware configuration; watch and changed-file operation; CI formats; native LSP; editor and
pre-commit integration; stable formatting policy; and end-to-end performance evidence.

The family does not copy Python-specific Ruff features such as notebook formatting or Python target
versions. Exact Lean toolchain selection already owns the corresponding compatibility boundary.
Runtime third-party rule plugins are deliberately not promised: Stack 05 instead builds a shallow
contribution path for first-party compiled rules, matching Ruff's built-in-rule model. A public
plugin ABI requires a later measured use case and design audit.

## Evidence policy

Every prompt writes `results/<prompt>.md` with commands, measurements, changed decisions, and
remaining uncertainty. Focused fixtures, the frozen representative mathlib sample, and named stress
files are development evidence. Only `ruff-20-acceptance` may schedule a complete 8,795-file mathlib
run, and only after the candidate is plausible; completed evidence is reused by executable digest.

## Product references

- Ruff formatter behavior and deliberately small style surface: <https://docs.astral.sh/ruff/formatter/>.
- Ruff lint rules, applicability, selection, and suppressions: <https://docs.astral.sh/ruff/linter/>
  and <https://docs.astral.sh/ruff/rules/>.
- Ruff configuration discovery and file selection: <https://docs.astral.sh/ruff/configuration/>.
- Ruff native LSP and editor capabilities: <https://docs.astral.sh/ruff/editors/>.
- The live Lean 4.32 compiler and Lake sources selected by the target toolchain remain authoritative
  for parser, syntax, environment, plugin, artifact, and build semantics.

## Blueprint

This family changes repository tooling and contains no mathematical theorem claims. Each executable
roadmap therefore marks itself `blueprint_tracked: false`; no prompt carries that field.
