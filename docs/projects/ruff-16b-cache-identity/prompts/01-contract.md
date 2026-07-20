---
claim_id: RCI-SPEC
status: verified
depends_on: []
---

# Freeze cache identity and the stale-hit differential

## Task

Deliver **RCI-SPEC**: Correct the `ruff-16` record, establish the whole-project-invalidation
reproduction as evidence, and freeze what an entry's import closure is, where it is computed, what
happens when it cannot be determined, and the differential test that separates a correct fix from a
naive one.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Add or update focused fixtures and persistent regression tests at the owning layer.
- Write `results/01-contract.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. **Correct the `ruff-16` record first.** `ruff-16-watch-incremental/results/02-implementation.md`
   decision 3, its `results/03-acceptance.md` remaining-uncertainty entry, and the inherited notes in
   `ruff-17-lsp` / `ruff-19-performance` `state/current.md` all assert an in-process cache-reuse defect
   that does not exist. Amend each in place, marked as an amendment rather than rewritten silently, and
   remove the superseded bullet from `ruff-19-performance/roadmap.md`.
2. Reproduce the defect as evidence: cold, unchanged re-run, and one-file-edit timings, plus the index
   files in `.lean-fmt-cache/results/` before and after. Record entry-level hit/miss counts, not only
   wall time — instrument if nothing currently reports them.
3. Characterize what Lake's module traces actually guarantee, from the Lake sources and from real
   `.trace` files — the `deps.imports` per-import transitive hashes, the recorded own-source path and
   hash, `depHash`, when each is written, and whether any is absent for a module the cache would serve.
   The roadmap's reading of these is from sampled files and is itself a claim to verify.
4. Design the currency check twice and compare, at minimum: recomputing each module's own-source hash
   against its trace and propagating staleness to dependents over the trace graph, against folding a
   trace-derived value into per-entry `CacheIdentity`. Compare caller knowledge, invariants hidden,
   error surface, exactness, cost on a cold and a warm tree, index-file churn, and — decisively — what
   each does when `A` changes with no rebuild. A design that reads a module's stored `depHash` alone
   falsely hits in that case; show the chosen design does not.
5. Decide whether tier changes the answer. A `.source` entry is source rules over raw bytes with no
   projection and may need no import coverage; a `.syntax` entry, and any entry carrying `canonical?`,
   is import-derived. Getting this wrong in the permissive direction is a stale hit.
6. Freeze the undeterminable-currency answer explicitly. Currency that cannot be established must
   degrade to a miss, never to a hit.
7. Specify the differential test precisely enough that `RCI-IMPL` cannot satisfy it accidentally: `A`
   declares a `notation`, `B` uses it, `A`'s notation changes and `B`'s bytes do not, and `B` must be
   re-analyzed. State which module is edited, which is asserted re-analyzed, how the mutation check is
   performed, and why an ordinary definition change in `A` would be an insufficient test.

## Stop

- No production Lean interface, config key, or CLI surface ships from this prompt, per the `*-SPEC`
  convention followed by `RWI-SPEC`, `RRF-SPEC`, `RSF-SPEC`, `RCD-SPEC`, `RRL-SPEC`, and `RMR-SPEC`.
- Do not freeze an identity whose stale-hit behavior under an unknown closure is left unstated.
- Do not correct the `ruff-16` record by deletion; an amended wrong finding is evidence about how the
  measurement misled, and the roadmap's evidence rule exists because of it.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and the focused unit/integration suites named by touched modules.
- Run `tests/boundary/run.sh` and inspect every changed module boundary manually.
- Use focused fixtures or the frozen sample for scale; complete mathlib is forbidden in this stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-16b-cache-identity`.
- Run `git diff --check` and read all output before marking RCI-SPEC verified.
