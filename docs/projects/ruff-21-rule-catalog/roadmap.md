---
kind: roadmap
topic: "Audit-driven rule catalog expansion"
main_results: [RCT-FINAL]
prereq_stacks: [ruff-05-rule-engine, ruff-05b-semantic-facts, ruff-06-fix-safety, ruff-12b-rule-graduation, ruff-20-acceptance]
blueprint_tracked: false
---

# Audit-driven rule catalog expansion

## Goal

Grow the rule catalog by roughly eight to ten rules that a Lean author would actually want, chosen
from measured evidence of what real code does wrong rather than from a wishlist of what a linter
could check.

## The gap this stack closes

The family's coverage contract promises "a useful rule catalog", and stacks 08–11 delivered the
machinery for one: three tiers, a fix-safety model, suppressions, a lifecycle, and a documented
contribution path (`docs/adding-a-rule.md`). What it delivered *in* the catalog is fifteen rules
across nine categories — enough to prove every tier works, not enough to be the reason anyone adopts
the tool.

**No stack in the family owns adding more.** Stacks 08, 09, 10, and 11 are closed; `ruff-12b`
decides the fate of what already exists; `ruff-20` audits and accepts. So the catalog's size is
currently an accident of what each machinery stack needed to demonstrate itself, and this stack is
the first to treat it as a product question.

## Why it runs after `ruff-20-acceptance`

`ruff-20` performs the fresh product audit and holds the family's only licence to run the complete
8,795-file mathlib corpus. That run is the best available evidence about what Lean code in the wild
actually contains, and this stack should be reading it rather than guessing ahead of it. Authoring
rules first and validating them against the audit afterwards would invert the dependency and produce
rules chosen for being easy to write.

## What "audit-driven" has to mean, or it means nothing

Every rule in this stack earns its place with a count before a line of it is written. The selection
prompt produces a ranked candidate list where each entry carries:

- **Frequency.** How often the idiom appears in the corpus, measured, with the query recorded.
- **Tier.** Which of source, syntax, or semantic can decide it — this sets the cost, and the cheapest
  tier that can answer the question is the tier the rule belongs in.
- **False-positive risk.** What legitimate code looks like the violation, and whether the rule can
  tell them apart at its tier. A rule that cannot is a rule that does not get written here.
- **Fix availability.** Whether a safe, idempotent fix exists under `ruff-06`'s model, or whether it
  is report-only.
- **Prior art.** What ruff, clippy, or an existing Lean tool does with the equivalent, and why this
  one differs if it does.

A candidate that cannot be given all five is not ranked; it is recorded as unrankable and why. **A
rule with a high count and no way to separate it from legitimate code is the most dangerous kind of
candidate**, because the count makes it look justified — the ranking must be able to reject it.

## Completion contract

- The candidate list is measured, ranked, and recorded before any rule is authored, and the authored
  set is drawn from it. A rule authored outside the list must amend the list first, with its count.
- Every new rule states its tier as its `RuleImpl` constructor, never as a declared field
  (`CLAUDE.md`), and sits in the cheapest tier that can decide it.
- Every new rule ships with focused fixtures covering positive, negative, boundary, Unicode, and
  custom-syntax cases, and with corpus evidence of its firing behaviour.
- Every new rule enters at the lifecycle stage its evidence supports, judged against
  `ruff-12b`'s frozen criteria (`ruff-12b-rule-graduation/results/01-criteria.md`) — this stack does
  not invent a second standard, and a rule good enough to be default on day one is allowed to be.
- Fixes are safe and idempotent under `ruff-06`, or the rule is report-only. There is no third option.
- The default-path cost of the shipped catalog is measured on `ordinary-built` and
  `formatter-integrated-built`, and `ruff-19`'s gates pass or are re-derived with the derivation
  recorded.
- `docs/adding-a-rule.md` is checked against what authoring these rules actually required, and
  corrected where it was wrong or thin. Ten consecutive rule authorings are the best test that
  document will ever get.
- The catalog, `lean-fmt rules`, `lean-fmt explain`, the generated docs, and every rule count quoted
  in repository prose agree.

## Work order

1. **RCT-SPEC — Mine the audit and rank the candidates.** Read `ruff-20-acceptance`'s audit and
   corpus evidence, measure candidate idioms over the corpus, and produce the ranked list with all
   five fields per entry. Select the target set and record what was rejected and why.
2. **RCT-SOURCE — Author the source-tier rules.** The cheapest tier: no artifact, no frontend, runs
   on the default path for free. Anything the selection put here is written, fixtured, and evidenced.
3. **RCT-SYNTAX — Author the syntax-tier rules.** These need the compiler artifact or the exact
   frontend, so each one's cost is measured on both build states as it lands, not at the end.
4. **RCT-SEMANTIC — Author the semantic-tier rules.** These need `Environment` capture through
   `ruff-05b`'s fact tier. Most expensive, so the selection must have justified each one explicitly.
5. **RCT-FINAL — Accept the expanded catalog.** Lifecycle placement against `ruff-12b`'s criteria,
   corpus acceptance, cost measurement, documentation, and the corrections to `docs/adding-a-rule.md`.

A tier prompt whose selection contains no rules records that and closes; an empty tier is a finding
about where Lean's real defects live, not a gap to be filled by inventing work for it.

## Evidence and verification

Every prompt writes a `results/` note with commands, raw measurements or evidence locators, changed
design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative mathlib
sample, and named stress files for development. `ruff-20`'s recorded complete-corpus evidence may be
*read* freely; re-running the complete corpus requires that stack's authorization and is not
development evidence here.

Run the affected Lean build/tests, `tests/boundary/run.sh`, `tests/performance/run.sh`, this stack's
structural checker, generated-next check, and `git diff --check`.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Do not author a rule that is not on the ranked list. Amend the list, with its count, or do not
  write it.
- Do not write a rule in a more expensive tier than the question requires. The cheapest tier that can
  decide it is the tier it belongs in, and "semantic is easier to write" is not a reason.
- Do not ship a fix that is not safe and idempotent. Report-only is always available.
- Do not relax a `ruff-19` gate to accommodate a new rule; re-derive it with a recorded derivation
  and re-prove it discriminates, or reconsider the rule.
- No public `-j`, pinning, or strategy flag; `ruff-19` rejected private concurrency on measurement.
- No runtime third-party plugin ABI. The family's coverage contract deliberately does not promise
  one, and ten new first-party rules are not the measured use case that would justify it.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation
  identity, private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
