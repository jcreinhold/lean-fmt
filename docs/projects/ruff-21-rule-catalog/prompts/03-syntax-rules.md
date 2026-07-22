---
claim_id: RCT-SYNTAX
status: planned
depends_on: [RCT-SOURCE]
---

# Author the syntax-tier rules

## Task

Deliver **RCT-SYNTAX**: Write, fixture, and evidence every syntax-tier rule in `results/01-gaps.md`'s
selection, measuring each one's cost on both build states as it lands.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- **This tier costs real money and the bill depends on the user's build.** `ruff-19` measured one
  syntax-tier rule over four modules at **3,283 ms in four frontend children** on an `ordinary-built`
  project against **105 ms in one facet fetch, frontend never running**, when the project is
  plugin-integrated (`ruff-19-performance/results/02-optimize.md`). Measure each rule's cost on both
  states as it lands, not in a batch at the end — a per-rule number is the only thing that can tell a
  later reader which rule to reconsider.
- **A `Syntax` leaf walk is not a linear cover of the source** (`CLAUDE.md`). A `choice` node holds
  several parses of one byte range, so only one alternative spells those bytes; walking all of them
  reads tokens out of order. Terminal commands (`eoi`, `#exit`) never appear in the command stream.
  Both hit ordinary files, not edge cases — `choice` appeared in 1 of 5 sampled mathlib modules and
  `#exit` in every file containing it. A rule that assumes a flat token stream will be wrong on real
  input and right on every fixture you would think to write.
- The module artifact holds **facts, never findings** (`CLAUDE.md`). Rules run outside the compiler,
  from those facts, in the process that reports them. `LeanFmt.Rules` is absent from both
  `LeanFmt/CompilerPlugin.lean`'s imports and `lean_lib LeanFmtCompilerPlugin`'s globs, and both
  absences matter: Lake links every module a library globs, imported or not. When the rules were
  reachable, editing one rule's message string invalidated every integrated module's Lake trace.
  Nothing in this prompt may make `LeanFmt.Rules` reachable from the plugin.
- The existing syntax-tier rules (`FMT008`–`FMT013`) are the shape to follow, and `ruff-10`'s results
  are the stack that built them. If a rule carries a fix, `ruff-10b`'s composition machinery and
  whatever `ruff-12b` decided about Design B govern it.
- A rule's tier is its `RuleImpl` constructor and never a declared field (`CLAUDE.md`). A declared
  tier field goes unenforced and rots.
- Every rule ships with focused fixtures covering positive, negative, boundary, Unicode, and
  custom-syntax cases, and with recorded corpus firing behaviour.
- Fixes are safe and idempotent under `ruff-06`'s model, or the rule is report-only. There is no
  third option, and "probably safe" is report-only.
- Lifecycle placement is judged against `ruff-12b`'s frozen criteria
  (`ruff-12b-rule-graduation/results/01-criteria.md`). This stack does not invent a second standard.
  A rule whose evidence supports shipping default on day one may do so.
- Record, as you go, anything `docs/adding-a-rule.md` got wrong or left thin. `RCT-FINAL` collects
  those corrections, and they are only accurate if written while the authoring is fresh.

- Write `results/03-syntax-rules.md` with exact commands, raw outputs or evidence locators,
  measurements, decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Reproduce and characterize the current boundary relevant to this claim.
2. Design the interface twice when the prompt introduces a new abstraction; compare caller knowledge,
   invariants hidden, error surface, exactness, cache identity, critical path, and memory enforceability.
3. Implement the smallest deep capability satisfying the roadmap contract and remove superseded production
   paths rather than retaining parallel architectures.
4. Exercise positive, negative, malformed, stale, custom-syntax, Unicode, and resource cases appropriate to
   the feature.
5. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- Do not author a rule that is not in `results/01-gaps.md`'s selection.
- If the selection contains no syntax-tier rules, record that and close the prompt.
- Do not make `LeanFmt.Rules` reachable from `LeanFmtCompilerPlugin`, by import or by glob.
- Do not relax a `ruff-19` gate to accommodate a rule; re-derive it with a recorded derivation and
  re-prove it discriminates via `tests/performance/negative.sh`, or reconsider the rule.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Run `tests/syntax/run.sh`, `tests/compiler/run.sh`, `tests/catalog/run.sh`, and the suites covering
  the new rules.
- Run `tests/performance/run.sh` and `tests/performance/negative.sh`.
- Use the frozen sample or synthetic saved reports for scale; re-running complete mathlib needs
  `ruff-20`'s authorization.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-21-rule-catalog`.
- Run `git diff --check` and read all output before marking RCT-SYNTAX verified.
