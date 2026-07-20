---
claim_id: RCI-IMPL
kind: result
---

# RCI-IMPL — rekey entries on the import closure

Prompt `03-implementation.md`. Its **Target** section names `results/02-implementation.md`; that slot
is taken by `RCI-MODEL`'s `results/02-model.md`, and prompt 01 wrote `results/01-contract.md` matching
its own number. Written here under the prompt's own number instead. Scaffold typo, recorded rather
than silently followed.

## 1. What shipped

`CacheIdentity` gains one field, `closure`, and `environmentDigest?` loses the whole-project source
walk that used to stand in for it.

| Before | After |
| --- | --- |
| `sourceRootParts?` digested every non-`.lake` `.lean` file under every source root into `environment` | deleted |
| `environment` → `baseDigest` → **index filename**, so any edit renamed the index | `environment` covers toolchain, search-path order, dependency roots, shared libraries |
| currency of a module's imports: unchecked | `CacheIdentity.closure`, per entry |

The closure digest is Lake's own `importAllArts`, recomputed from each closure member's trace
`outputs` — the `o` array, then `rs`, then `r`, folded from `Hash.nil` with `Hash.mix`, in
`computeExportInfo`'s order. `LeanFmt.Project` supplies the closure from the one shared no-build graph
(`importClosures?`); `Cache` resolves no imports of its own.

Files changed: `LeanFmt/Cache.lean`, `LeanFmt/Project.lean` (`importClosures?`, `moduleTracePath?`),
`LeanFmtTest.lean` (`testLakeTraceCharacterization`), `tests/cache/` (new), `tests/check/run.sh`,
`tests/scale/run.sh`, `.gitignore`.

## 2. Measurement — this repository

`LEAN_FMT_PROFILE_PHASES=1 lean-fmt check`, 119 targets, at the tree state of this commit.

| Run | `index_hits` | Wall | Indexes on disk |
| --- | --- | --- | --- |
| cold | 0 / 119 | 65.56 s | 1 |
| unchanged re-run | **119 / 119** | **0.52 s** | 1 |

Against the `RCI-SPEC` baseline (112 targets, `60e5da5`): unchanged was 112/112 at 0.58 s, and *one
appended comment* took it to **0/112 at 59.10 s with a second index file**. That row is what this
stack removed; there is no longer an edit shape that produces it.

The closure machinery is not the cost. Instrumented once and then removed:

```
DEBUGTIME standalone=13ms
DEBUGTIME closures=9ms n=37
```

22 ms for the whole batch — one no-build graph fetch plus 37 trace reads.

## 3. Measurement — focused fixture

`tests/cache/project`, a self-contained package built for this. Measuring edit shapes on *this*
repository is confounded: editing any `LeanFmt/*.lean` rebuilds the `lean-fmt` binary, which moves
`formatter`, which feeds `baseDigest`, which names the index — so a self-hosted edit invalidates
everything for a reason unrelated to the property under test. A separate package holds the formatter
fixed.

Import graph, 6 targets (5 modules + `lakefile.lean`):

```
Notation  (declares `notation:65 a " <+> " b`)
   ^
   |
 User  --->  Wide  <---  Other          Leaf   (nothing imports it)
```

`lakefile.lean` is not a workspace module, so it is keyed by the conservative whole-workspace artifact
digest and misses on any rebuild. It is included in every count below.

| Edit | Served | Invalidated | Verdict |
| --- | --- | --- | --- |
| none (warm) | 6 / 6 | — | |
| comment appended to `Leaf` (no dependents) | 4 / 6 | `Leaf`, `lakefile` | entry granularity |
| comment appended to `Wide` (2 dependents) | 4 / 6 | `Wide`, `lakefile` | **dependents keep hitting** |
| `wideValue := 2` → `42` in `Wide` | 2 / 6 | `Wide`, `User`, `Other`, `lakefile` | dependents invalidated |
| `Notation`'s notation `a + b` → `a * b` | 3 / 6 | `Notation`, `User`, `lakefile` | **grammar hazard caught** |
| — after 5 rebuild/check cycles | | | **1 index file** |

Two rows carry the argument.

**The notation row is the reason `closure` exists.** `User`'s bytes are byte-identical across the edit
(`md5 34b23cfc3799372eea19b2e218261aef` before and after) and it was still re-analyzed, because the
grammar it parses under changed. `Other` and `Leaf` kept hitting: catching the hazard did not mean
invalidating the world.

**The comment-only row is a precision property, not a leak.** Lake's outputs are content-addressed, so
a comment does not move `importAllArts` and the dependents' grammar is provably unchanged. An
mtime-based key could not distinguish this from the semantic edit below it.

## 4. Mutation check

Prompt step 3 requires the differential to be observed failing. `closureDigest?` was edited to return
a constant, `lean-fmt` rebuilt, the fixture re-warmed, and §5 re-run:

```
=== MUTANT: warm baseline ===        === FIXED: warm baseline ===
cache.served=6                       cache.served=6
=== MUTANT: edit notation only ===   === FIXED: edit notation only ===
cache.served=4                       cache.served=3
```

Four served instead of three. Every other target behaves identically in both runs, so the extra entry
is `User` — a stale hit on byte-identical source under a changed grammar, which is exactly the defect.
Mutation reverted; `grep -c MUTANT LeanFmt/Cache.lean` → `0`.

The check is now `tests/cache/run.sh` §5, with the mutant's number recorded in a comment beside it.

## 5. Decisions changed during execution

**Undeterminable currency became a conservative fallback, not a permanent miss.** `RCI-SPEC` froze
"currency that cannot be determined degrades to a miss." Implemented literally, that produced two
regressions, measured in order:

| Implementation | `index_hits` | Wall |
| --- | --- | --- |
| closure threaded, `none` for non-modules | 31 / 113 | 49.53 s |
| `+` whole-workspace digest for non-modules | 107 / 113 | 6.57 s |
| `+` same fallback wherever the closure does not resolve | **113 / 113** | **0.51 s** |

The first row: ~82 targets (`experiments/`, test fixtures) are not globbed into any library, so
`module? = none`, so they were permanently uncacheable. The second row's residue was six named
targets — `Main`, `LeanFmtTest`, `LeanFmtArtifactExtract` (executable roots, which
`Lake.Workspace.findModule?` does not return because it searches libraries only), and
`MalformedHeader`, `UnresolvedImport`, `Broken` (fixtures that deliberately do not compile, so their
closure members have no artifacts).

The fallback is the digest of every artifact in the workspace's build directory. It is sound because
it **dominates** every per-module closure digest: a workspace module whose compiled output could
contribute grammar has that output in the directory, and a module with no compiled output contributes
no grammar. It is coarse — any rebuild invalidates every entry keyed this way — but that is the blast
radius these files already had, now confined to a per-entry key instead of the index *filename*.

This does not weaken `RCI-SPEC`. `none` still means miss, and is still never written; the set of
targets reaching `none` shrank to those where even the fallback is unavailable.

**Keying on the full `importAllArts` rather than the public `.olean` alone.** Changing `wideValue`'s
body moved `outputs.o[1]` (`.olean.server`), `o[2]` (`.olean.private`) and `r` (`.ir`), while `o[0]`
(the public `.olean`) and `rs` (`.ir.sig`) were **unchanged** — the module system splits public
interface from private body. Keying on `o[0]` alone would have looked like the minimal
grammar-relevant choice and would have under-invalidated relative to Lake's own dependency key.

**`environmentDigest?` had a second whole-project invalidator.** `rootTraceParts?` folds every
`.olean`'s trace contents into `environment`, so rebuilding any one module renamed the index even
after the source walk was gone. Fixed by skipping `workspace.root.leanLibDir` there. Dependency
package roots keep exactly the coverage they had.

## 6. Test contract reversals

Three assertions encoded the defect and now encode the fix. Each is annotated in place with what it
used to say and why it changed.

| Test | Was | Now |
| --- | --- | --- |
| `tests/check` `cache-dependency-source-*` | editing `LeanFmt/Cli.lean` forces a miss on `Findings.lean` | it **hits**, and equals the `--no-cache` result under the same build state |
| `tests/check` `cache-trace-*` | appending `\n` to a `.trace` forces a miss | whitespace **hits**; a mutated recorded output hash forces the miss |
| `tests/scale` stale row | editing `Demo.lean` fails `Demo.lean` **and** `scripts/Standalone.lean` | fails `Demo.lean` only |

The fidelity target these settle on is worth stating, because it is what makes the first row a fix
rather than a weakening: **`lean-fmt` fetches its Lake graph with `noBuild := true` and never builds.**
The grammar available to an *uncached* run is therefore the one in the artifacts on disk. Editing a
source without rebuilding does not change those artifacts, so the cached and uncached answers agree —
and `tests/check` now asserts that equality directly rather than inferring it. The old behavior missed
that target by over-invalidating. A grammar change that has actually been built is caught by
`tests/cache/run.sh` §5.

## 7. Index collection

`state/current.md` left this open. **Collection is not added, and a stable name makes it moot for
project edits.** The fixture ran five rebuild-and-check cycles and finished with one index file (§3);
this repository holds one across cold and warm (§2).

The name still moves when the *epoch* moves — a toolchain change, a dependency rebuild, a new
`lean-fmt` binary. Those are rare and, unlike a keystroke, are not user-facing edit shapes. The two
orphans this repository accumulated during `RCI-SPEC` were removed by hand along with the cache
directory during measurement; nothing collects them automatically. `RCI-FINAL` owns whether that
residual case needs a collection path.

## 8. Checks read

```
LEAN_NUM_THREADS=1 lake build                 Build completed successfully (50 jobs)
lake exe lean-fmt-tests                       lean-fmt module-artifact tests passed
tests/{compiler,check,suppression,lossless,modes,scale,service,boundary,syntax,discovery,stream,reporting,watch,cache}/run.sh
                                              all PASS
```

The proof library's `#print axioms` block reports `propext` alone on all eleven theorems, on every
build, because `LeanFmtCacheSpec` is a `@[default_target]`. `tests/boundary/run.sh` confirms it stays
out of both the binary and the plugin dylib link closures.

## 9. Remaining uncertainty

- **A2 (observation faithfulness) is still false in general.** A rebuild racing a `check` can move an
  artifact between the closure read and the analysis. Bounded, named in `notes/01-what-is-provable.md`,
  unchanged by this prompt. Nothing here narrows it.
- **The fallback's blast radius is untested at scale.** On a project where most files are workspace
  modules it covers almost nothing; this repository is unusually bad for it (`experiments/`, fixtures)
  and still reaches 119/119 warm. A project that is mostly standalone files would see every entry
  invalidated on any rebuild. Not measured.
- **Executable roots take the fallback unnecessarily.** `Main` has a real trace; only
  `Lake.Workspace.findModule?` does not return it. A narrower lookup through the workspace's executable
  targets would give them precise keys. Not attempted — it widens the Lake surface `Project` exposes,
  and the fallback is already correct.
- The frozen mathlib sample was not re-measured here. `RCI-FINAL` owns scale acceptance.
