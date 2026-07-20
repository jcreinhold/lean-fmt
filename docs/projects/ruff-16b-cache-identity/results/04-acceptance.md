---
claim_id: RCI-FINAL
kind: result
---

# RCI-FINAL — acceptance: adversarial shapes, scale, collection, and the watch decision

Prompt `04-acceptance.md`. Its **Target** section names `results/03-acceptance.md`; that slot is taken
by `RCI-IMPL`. Written under the prompt's own number, as `RCI-IMPL` did for the same reason.

## Summary

Five things, in order of how much they change the stack.

1. **No stale hit under any exercised shape.** Nine adversarial edit and graph shapes, each checked
   against the `--no-cache` answer under the same build state, not merely counted (§1).
2. **A defect the fixture could not see: on mathlib the cache never wrote a single entry.** One
   absent search-path directory disabled it for the whole project, silently. Found by running the
   frozen sample, fixed, and now a permanent fixture shape (§2).
3. **Index accumulation is bounded** at the live index plus three, and epoch changes still invalidate
   everything (§3).
4. **Watch's re-exec stays, on measurement.** Spawning costs 24 ms against a 490 ms generation and
   parent RSS is flat across 15 generations. `ruff-16`'s stated *reason* was already corrected; the
   behavior is now justified by its own number (§4).
5. **The correspondence gap `RCI-MODEL` called the stack's largest is closed**, in a stronger form
   than that note proposed: the proved decision *is* the shipped one (§5).

## 1. Adversarial shapes

`tests/cache/run.sh` §7, on `tests/cache/project`. Eight targets: seven modules plus `lakefile.lean`,
which is not a workspace module and so takes the conservative whole-workspace key and misses on any
rebuild. It is included in every count.

Every row runs through `probe`, which compares the cached report against a `--no-cache` report under
the same build state, byte for byte. That is the direct stale-hit oracle: a count alone cannot tell a
correct hit from a hit that served the wrong answer.

| Shape | Served | What must not happen |
| --- | ---: | --- |
| module added mid-closure | 7 / 8 | the new module served from nothing |
| module deleted mid-closure | 5 / 8 | a dependent served a result computed under the vanished module |
| import edge added | 6 / 8 | the importer served its pre-edge parse |
| module renamed | 6 / 8 | the old entry served under the new name |
| CRLF-only change | 7 / 8 | a hit whose publish would rewrite line endings |
| unrelated edit, `choice`-node and `#exit` modules in the closure | 6 / 8 | those two quietly recomputing every run |
| comment-only edit to a widely-imported module | 6 / 8 | over-invalidation (the precision direction) |
| semantic edit to a widely-imported module | 4 / 8 | a dependent served under the old body |
| `notation`-only edit | 5 / 8 | **a dependent whose bytes never changed served under the old grammar** |

Two deserve their reasoning stated rather than their number.

**The CRLF row misses, and that is correct rather than conservative-by-accident.** Every
compiler-produced offset indexes `raw.crlfToLf`, so the *analysis* is unchanged. But `format` and
`fix` denormalize back to the file's own line endings when they publish, so the raw bytes are part of
what an entry promises. Missing costs one recomputation; hitting would let a publish rewrite line
endings the user never touched.

**The `notation` row is why `closure` exists**, and it is the one shape a plausible implementation
gets wrong. It is mutation-checked: with `closureDigest?` stubbed to a constant the fixture serves 4
where the fixed build serves 3, and the extra entry is the module whose bytes are byte-identical
across the edit (`RCI-IMPL` §4). The mutant's number is recorded in a comment beside the assertion.

## 2. Scale, and the defect it exposed

### The defect

Running the frozen sample was supposed to be a measurement. It was a bug report.

```
cd ~/Code/mathlib4
lean-fmt check Archive/Arithcc.lean      # twice
cache.index_hits=0                       # both times
ls .lean-fmt-cache                       # No such file or directory
```

The cache had never written an entry, and would never write one, on a project with 8,276 built
modules. Not a stale hit — the opposite, and invisible, because a disabled cache is a supported
outcome that reports nothing.

`environmentDigest?` calls `IO.FS.realPath` on every entry of the workspace's `LEAN_PATH`.
`mathlib`'s path contains `.lake/packages/Cli/.lake/build/lib/lean`, which does not exist: `Cli` is
required by mathlib's lakefile and imported by no module, so Lake never builds its library. `realPath`
throws on an absent path, the exception escaped into `ResultCache.open?`'s catch-all, and `open?`
returned `none` for the whole project.

The fix is `realPathIfDir?`: a root that is not an existing directory contributes a
`lean-path-absent\0<path>` part instead of throwing. Absence is *recorded* rather than skipped, so a
root later appearing with artifacts still moves `environment`.

This does not weaken `open?`'s refusal to manufacture a partial epoch, which is a stop rule. A
directory that does not exist holds no artifacts to be partial about. A root that exists but whose
artifacts do not validate still returns `none` for the entire cache, unchanged.

**It is now a permanent fixture shape, not a one-off check.** `tests/cache/dep` is a package the
fixture requires and nothing imports, so Lake never builds its library and its lib directory never
exists. Every section of `tests/cache/run.sh` therefore runs with an absent search-path root, and a
regression fails the whole file. A precondition guard fails if that directory ever appears, because
otherwise the coverage would evaporate silently — the same failure mode that let §5's mutation check
pass falsely once during `RCI-IMPL`.

The general lesson is worth keeping: **a self-contained fixture cannot find a defect whose cause is a
shape only real projects have.** Nothing about the fixture's five-module graph could produce an
unbuilt required package.

### The measurement

`experiments/workloads/mathlib-v4.32.0-sample.txt`, 62 files, `LEAN_NUM_THREADS=1`,
`LEAN_FMT_PROFILE_PHASES=1`, ordinary artifacts built.

Revision drift, recorded rather than glossed: the checkout is now
`8c79cb4f540eeb519b1a2187009a1916521fd168` on `leanprover/lean4:v4.33.0-rc1`, not the
`783ccda4…`/`v4.32.0` pair the sample was frozen against. The toolchain matches this repository's, the
sample's 62 paths all still exist, and rebuilding mathlib at the old revision is not a cost this
prompt justifies. Treat the numbers as same-shape, not same-run, comparable to
`execution-core-v2`'s.

| Run | `index_hits` | Wall | Indexes |
| --- | ---: | ---: | ---: |
| cold | 0 / 62 | 14.36 s | 1 |
| warm | **62 / 62** | 6.34 s | 1 |
| one comment appended to `Mathlib/Algebra/Algebra/Rat.lean`, **not rebuilt** | **61 / 62** | 12.80 s | 1 |
| reverted | 62 / 62 | 6.52 s | 1 |

The third row is the whole stack in one line. Before `RCI-IMPL` it would have read **0 / 62**: the
edit renamed the index. It now costs exactly the file that was edited. The wall time doubles anyway,
because that one miss is a mathlib module and an exact-frontend analysis of one of those is most of a
six-second run — which is precisely why counts and not wall time are the unit of claim here.

Every dependent of the edited module keeps hitting, and that is correct rather than lenient:
`lean-fmt` fetches its Lake graph with `noBuild := true`, so an uncached run sees the same on-disk
artifacts. Editing a source without rebuilding does not change the grammar anything parses under, so
the cached and uncached answers agree. A grammar change that *has* been built is caught by
`tests/cache/run.sh` §5.

**Warm is 2.3×, not the fixture's 100×, and the reason is worth stating.** Fixed per-run cost —
discovery over 8,795 files, workspace load, epoch computation, and closure digests for 62 modules
whose closures run to thousands of members — does not shrink when entries hit. Two fixes came out of
measuring it, both in this prompt:

| | Before | After |
| --- | ---: | ---: |
| warm wall | 15.9 s | 6.3 s |
| `cache_lookup` phase | 14.2 s | ~3.6 s |

- **The conservative whole-workspace fallback was computed eagerly**, on every run, by
  `closureDigests`. It digests every artifact in the build directory — ~10 s on mathlib — and on a
  project where every target is a workspace module whose closure resolves, *nothing reads it*. It is
  now computed on demand; `workspaceArtifactsDigest` still memoizes, so it stays at most one walk.
- **`importAllArts` was recomputed per (module, closure member) pair.** Closures overlap almost
  completely, so the same trace file was read and JSON-parsed once for every module that transitively
  imports it. Memoized per module name (`artifactHashByModule`): 4,125 distinct traces read instead of
  ~124,000.

Wall time on this workload is unusually page-cache sensitive — the first warm run after a rebuild
measured 10.9 s in `closureDigests` where the steady-state run measures 3.6 s, reading the same 4,125
trace files. The `index_hits` counts do not move. This is the same confound that produced the original
`ruff-16` misreading, showing up again in the measurement that closes the stack.

## 3. Index accumulation and collection

`RCI-IMPL` §7 left this open: a stable index name makes accumulation moot for *project edits*, but the
name still moves when the epoch does — a toolchain change, a dependency rebuild, a new `lean-fmt`
binary. Nothing collected those.

Collection is now added and bounded. `writeAll` calls `collectStaleIndexes`, which keeps the
`indexRetention = 3` most recently modified indexes besides the live one and removes the rest.
`tests/cache/run.sh` §8 drives seven epoch changes and asserts four files survive; before this change
three simulated rebuilds left four and it kept climbing.

Three, not zero, because an epoch change is often temporary — switching branches, rebuilding a
dependency and reverting, or alternating toolchains — and the recovered index is worth more than the
disk. Removal is best-effort (`removeQuietly`) and the whole collection is inside a `catch`: failing
to delete a stale index must never fail the run that computed a correct answer.

Epoch changes still invalidate everything, which is the property collection must not quietly break.
§8 asserts a formatter rebuild takes the fixture from 8 served to 0, and that a toolchain mismatch is
a hard error rather than a silent re-key.

## 4. The watch re-exec decision — keep it

`ruff-16` adopted per-generation re-exec because it believed `execute` could not reuse the result
cache within one process. `RCI-SPEC` refuted that reason. The prompt's stop rule is explicit that a
wrong reason is not grounds for removal, so this owes a measurement.

| | Value |
| --- | --- |
| spawn cost per generation | 24 ms |
| warm generation, end to end | 490 ms |
| spawn as a fraction | ~5% |
| parent RSS, 15 generations | 51,488 KiB, flat |

**Re-exec stays.** The ~400 ms fixed cost `ruff-16` attributed to re-exec is workspace load,
discovery, and epoch computation — which an in-process generation pays too, *unless* it retains the
workspace across generations. Retention is the whole prize, and it is exactly the thing not to buy:
deciding a generation against build state observed before the edit is the staleness class this stack
exists to remove, and capturing it would require weakening `open?`'s refusal to manufacture a partial
epoch. Paying 5% to make every generation observe the world fresh is the trade this stack was opened
to make.

The retention claim is now measured rather than assumed: parent RSS does not move across 15
generations. `LeanFmt/Cli.lean`'s comment block carries these numbers at the call site; it previously
asserted the refuted diagnosis.

## 5. The `ruff-16` record, and the correspondence gap

**Record correction survived implementation.** Every site `RCI-SPEC` amended still reads as amended,
and no document asserts the in-process defect except under a strike or an amendment block. The five
sites plus the sixth found later (`ruff-19-performance`'s completion contract) are consistent;
`ruff-16-watch-incremental/state/current.md` now forward-references §4 above for the grounds on which
re-exec is retained, and §4 exists.

**The correspondence gap is closed.** `RCI-MODEL` §9 called "no one has proved `LeanFmt.Cache`
instantiates this model" the largest gap in the stack, and proposed narrowing it to one visible
adapter. What shipped is stronger: `LeanFmt/Cache/Decision.lean` holds `Obs`, `Entry`,
`identityCurrent`, `Provided.meets` and `serves` as production definitions that `LeanFmt.Cache` and
`LeanFmt.Application` **call** and `LeanFmt/Cache/Spec.lean` **proves about**. There is no lookalike
left to drift.

Closing it exposed a drift that had already happened: the model checked schema, source, closure and
tier, while the shipped gate additionally required canonical text when the run renders and every
demanded semantic sub-fact. The completeness theorem was about a strictly more permissive decision
than the one running. `Demand` and `Provided` carry those fields now, and `tier_adequate` became
`demand_met`.

Two residues remain, and neither is a type-level guarantee:

- The theorems quantify over abstract digest types, so digest injectivity (A1) is still a hypothesis.
- `identityCurrent` runs in `Cache` (only it can observe digests) and `Provided.meets` in
  `Application` (only it knows the rule plan). *That both halves are applied* is checked by
  `tests/cache/run.sh`, not by a type. `serves` is defined as their conjunction so a caller applying
  only one is visibly not applying `serves`.

`tests/boundary/run.sh` asserts both directions of the link-closure property: `LeanFmt.Cache.Decision`
symbols are present in the binary (production code must link) and `LeanFmt.Cache.Spec` symbols are
absent from both the binary and the plugin dylib (a proof about the cache must not be able to rebuild
an integrating project).

**The `#print axioms` audit is no longer in the module.** Eleven `#print axioms` statements were
removed on instruction — build-time `info:` output should not be committed. The audit is a manual step
whose last reading (`propext` alone, all eleven theorems, taken against the current `Spec.lean`) is in
`results/02-model.md` §5 under an amendment. This is a real reduction in enforcement, stated in three
places rather than glossed: an assumption introduced later will not announce itself in the build that
introduced it. `LeanFmtCacheSpec` remains a `@[default_target]`, so a proof that stops *compiling*
still fails the build that broke it.

## 6. Checks read

```
LEAN_NUM_THREADS=1 lake build                 Build completed successfully (52 jobs)
lake exe lean-fmt-tests                       lean-fmt module-artifact tests passed
tests/{compiler,check,suppression,lossless,modes,scale,service,boundary,syntax,discovery,
       stream,reporting,watch,cache}/run.sh   all PASS
git diff --check                              clean
check_stack.py / write_next.py --check        <!--CHECKS-->
```

## 7. Remaining uncertainty

- **A2 (observation faithfulness) is false in general and unnarrowed.** A rebuild racing a `check` can
  move an artifact between the closure read and the analysis. Bounded TOCTOU, named in
  `notes/01-what-is-provable.md`, carried as a hypothesis rather than an `axiom` so it appears in the
  type of everything downstream. Nothing in this prompt touches it.
- **The adversarial set is a set, not a proof.** Nine shapes found no stale hit. The shapes were
  chosen by reasoning about what the key could miss, and §2 is the standing reminder that a fixture
  only exercises shapes its author imagined.
- **Executable roots still take the conservative fallback** because `Lake.Workspace.findModule?`
  searches libraries and not executables. Correct but coarse; a narrower lookup would widen the Lake
  surface `Project` exposes. Not attempted.
- **The absent-root fix is scoped to search-path roots.** Other `IO.FS.realPath` calls inside `open?`'s
  catch-all can still disable the cache silently. There is no diagnostic that says "the cache is off
  and here is why" — a run with a broken epoch is indistinguishable, from the outside, from a run with
  a cold one. That is the shape of the defect §2 found, and only one instance of it is fixed.
- **Complete mathlib was not run**, per `CLAUDE.md` and this stack's Check section. The 62-file sample
  and the fixture are the evidence.
