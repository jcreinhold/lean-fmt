---
kind: roadmap
topic: "Result-cache identity and incremental invalidation"
main_results: [RCI-FINAL]
prereq_stacks: [ruff-16-watch-incremental]
blueprint_tracked: false
---

# Result-cache identity and incremental invalidation

## Goal

Make the aggregate result cache invalidate the modules an edit can actually affect, instead of the whole
project, without ever converting a miss into a stale hit.

## The defect

`Cache.environmentDigest?` folds the content of **every** project source into `environment`
(`sourceRootParts?` walks `workspace.augmentedLeanSrcPath` and digests each `.lean` file's bytes).
`environment` feeds `baseDigest`, and `baseDigest` *names the index file* (`indexPath`). So editing any
one source changes the index filename, orphaning the previous index and invalidating every entry in it.

Measured on this repository at commit `442478c`, 112 files:

| Run | Wall time |
| --- | --- |
| cold | 64.3 s |
| unchanged re-run | 0.63 s |
| **after appending one comment to one file** | **61.6 s** |

A second index file appears in `.lean-fmt-cache/results/` after the edit, which is the direct
observable. The practical consequence is that the persistent cache helps only when nothing changed —
precisely the case where the user is least likely to be waiting on it.

**This supersedes `ruff-16`'s recorded diagnosis.** `ruff-16-watch-incremental/results/02-implementation.md`
decision 3 attributed the same ~70 s to `execute` failing to reuse the cache *within one process* and
routed around it by re-execing each watch generation. That is wrong: `execute` opens a fresh
`ResultCache` per call (`Application.lean:1298`) and there is no retained in-process state to go stale.
The two numbers being compared were different workloads — cold-after-edit against an unchanged tree.
`RCI-SPEC` owns correcting that record.

## The hard part

The whole-project digest is coarse but it is **not gratuitous**, and the naive fix is unsafe — for a
reason that is easy to get wrong, so it is stated carefully here.

It is **not** that rules read across modules. They provably cannot: `Rules.lean:17` records that a rule
"cannot reach a workspace, a cache, an `Environment`, or `IO` — not by convention but because `run`'s
argument type is a fact view", and the one cross-module family (`FMT005`/`FMT006`/`FMT007`, where
`FMT006` reads the Lake graph) is computed fresh before any cache path (`Application.lean:1286`)
precisely because it "is not cacheable under a file's own digest".

It is that **the fact view itself is import-derived**. Lean's grammar is open: a `notation`, `macro`, or
`syntax` declaration in `A` changes how `B`'s *unchanged bytes* parse. The projection a rule reads comes
from `B`'s artifact, produced when `B` was compiled under `A`'s grammar. So if `A` changes and `B` is not
rebuilt, `B`'s cached analysis describes a parse that no longer corresponds to the module — and
rendering canonical text from it can change what the code means, which is the one thing a formatter must
never do.

Two mechanisms should have caught that and neither does:

- `validateOleanTrace?` parses only `schemaVersion` and `outputs` (`Cache.lean:14-17`) and verifies
  output file hashes. That proves the artifact is **intact**, never that it is **current**.
- Nothing else checks currency, so the whole-project source walk is the crude stand-in: invalidate
  everything whenever anything changes.

Lake already computes the missing answer. A module's `.trace` records, under `inputs`, a `deps.imports`
entry of the form `["LeanFmt.Service transitive imports (all)", <hash>]` per import, its own source path
and hash, and a combined `depHash`. **Do not reimplement transitive-closure tracking**; the work is to
consume what the build system already stores.

The design is not obvious and this roadmap deliberately does not fix it:

- A module's stored `depHash` records what it *was built against*, not whether that is still true. Read
  alone, it **falsely hits** in exactly the stale case that matters.
- Comparing each module's trace-recorded own-source hash against disk cheaply identifies which modules
  are stale — but staleness must then propagate to dependents, which is a walk over the trace graph.
  **Attempting to state this design's theorem refuted it** (`notes/01-what-is-provable.md` §6): edit `A`,
  `lake build` rebuilds `A` but `B` *fails to build*, and now `A` matches its fresh trace while `B`
  matches its own stale one — no staleness is detected anywhere, yet `B`'s artifact encodes old-`A`
  grammar. Per-module self-consistency is insufficient; the check must be graph consistency, comparing
  `B`'s recorded import hash against `A`'s current recorded value.
- Tier may change the answer. A `.source` entry is source rules over raw bytes with no projection and
  may need no import coverage at all; a `.syntax` entry, and any entry carrying `canonical?`, certainly
  does.

So the work is to make entry currency precise — invalidating a module when its own bytes change **or**
when the grammar it was parsed under changed — and to prove the result is neither too coarse (the
measured defect) nor too fine (stale hits).

## Completion contract

- Editing one module invalidates that module and its dependents, and leaves unrelated modules' entries
  served from cache. Demonstrated as wall-time and as entry-level hit/miss counts, not wall-time alone.
- An entry serves a run only when its artifact is **current**, not merely intact: the module's own bytes
  are unchanged *and* the grammar it was parsed under is unchanged. Currency is derived from Lake's
  recorded trace inputs, not from a reimplemented import walk. Non-source environment inputs — toolchain,
  search paths, dependency oleans, shared libraries — keep whatever coverage they have now; this stack
  narrows project-source coverage only.
- **A differential test that a naive fix fails, exercising the open grammar directly.** `A` declares a
  `notation`; `B` uses it; both are cached. Change `A`'s notation only, leave `B`'s bytes untouched, and
  assert `B` is re-analyzed rather than served. This test must be mutation-checked: with the currency
  contribution removed it fails with a stale hit, restored it passes. A test using an ordinary
  definition change in `A` is **not** sufficient — it can pass under a fix that would still serve a
  stale parse.
- Index files are not orphaned per edit. Whatever keying ships, `.lean-fmt-cache/results/` does not
  accumulate one index per source revision, and stale indices are collectable.
- **Decide whether watch's per-generation re-exec comes out.** `ruff-16` adopted it for a reason that
  did not hold. Removing it is still a measurement, not a consequence: re-exec also buys the flat
  retention `ruff-16` measured (16 KiB over 13 generations) against a ~400 ms child-process fixed cost.
  Measure in-process against re-exec and record the decision either way.
- Cache failure still never changes analysis results, and a corrupt index is still an empty cache.

## Work order

1. **RCI-SPEC — Freeze what makes an entry current, and the stale-hit test.** Correct the `ruff-16`
   record. Establish the reproduction as evidence, and characterize what Lake's module traces actually
   guarantee — `deps.imports`, the recorded own-source hash, `depHash`, and when each is written.
   Choose the currency check from the design space the roadmap names, decide whether tier changes the
   answer, state what happens when currency cannot be determined, and specify the notation-based
   differential test. Ship documentation and one characterization test; no production interface, per the
   `*-SPEC` convention.
2. **RCI-MODEL — Model the decision and prove it sound and complete.** Express the frozen decision as a
   pure function over an explicit observation, specify correctness independently of it, and prove both
   directions under named hypotheses. See `notes/01-what-is-provable.md` for why the direct claim is not
   a Lean theorem and what is provable instead.
3. **RCI-IMPL — Make entry currency precise.** Implement the frozen check in `LeanFmt.Cache`, consuming
   Lake's recorded traces rather than reimplementing import resolution, with whatever `LeanFmt.Project`
   must expose. Land the mutation-checked differential test. Measure one-file-edit invalidation at entry
   granularity.
4. **RCI-FINAL — Audit invalidation and settle the watch workaround.** Adversarial cases: cyclic-looking
   import graphs, a module added or deleted mid-closure, config and toolchain changes, a dependency
   rebuild, index accumulation and collection. Decide re-exec on measurement. Verify no stale hit under
   any exercised edit shape.

## Evidence and verification

Every prompt writes a result note with exact commands, raw outputs or evidence locators, measurements,
decisions changed during execution, and remaining uncertainty. Report cache behavior as entry-level hit
and miss counts wherever a claim is about invalidation; wall time alone cannot distinguish "cache
worked" from "the OS page cache was warm", which is exactly how `ruff-16` misread this.

Run the affected Lean build and tests, `tests/watch/run.sh`, `tests/check/run.sh`, `tests/boundary/run.sh`,
this stack's structural checker, the generated-next check, and `git diff --check`. Use focused fixtures
and the frozen representative mathlib sample; do not run complete mathlib in this stack.

## Blueprint

This is formatter repository maintenance and introduces no mathematical theorem claim. Therefore this
roadmap sets `blueprint_tracked: true`.

## Stop rules

- **A stale hit is a stop, not a bug to file.** If any exercised edit shape serves a cached result that
  disagrees with a fresh analysis, stop and reopen the identity rather than narrowing the test.
- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- **Do not reimplement import resolution or transitive-closure tracking.** Lake records it per module;
  consume the recorded traces. A second import resolver in the cache layer is the "second execution
  engine" this repository's roadmaps consistently refuse.
- Do not widen the cache's public surface; `ResultCache` stays a private capability constructed only
  through `open?`.
- Do not weaken `open?`'s refusal to manufacture a partial epoch in order to make invalidation cheaper.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
