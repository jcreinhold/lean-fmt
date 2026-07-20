---
kind: result
claim_id: RCI-SPEC
status: verified
---

# RCI-SPEC — Cache identity, entry currency, and the stale-hit differential

Raw measurements, trace diffs, and command lines: `evidence/01-invalidation-and-traces.md`.

## Summary

Four things happened, in order of how much they change the stack.

1. **The `ruff-16` record is corrected.** There is no in-process cache-reuse defect. The real defect
   is process-independent whole-project cache-key invalidation, reproduced at entry granularity.
2. **The roadmap's own reading of Lake's traces is refuted by measurement.** `roadmap.md` and
   `notes/01-what-is-provable.md` §6 both proposed comparing `B`'s recorded
   `["A transitive imports (all)", h]` against `A`'s current value. That key excludes `A` itself, so
   the comparison would have passed on precisely the grammar change this stack exists to catch. The
   key that carries `A`'s content is the sibling `["A:importAllArts", h]`.
3. **A sound, exactly-recomputable currency check is frozen**, consuming only what Lake already
   records, with the undeterminable case degrading to a miss.
4. **The differential test is specified**, including why an ordinary definition change in `A` is an
   insufficient test and how the mutation check is performed.

No production Lean interface, config key, or CLI surface ships, per the `*-SPEC` convention. What
does ship: one characterization test, one diagnostic counter on the existing profile channel, and the
amendments to `ruff-16`, `ruff-17`, and `ruff-19`.

## 1. The `ruff-16` record, corrected

`ruff-16-watch-incremental/results/02-implementation.md` decision 3 attributed a ~70 s watch
generation to `execute` failing to reuse the result cache within one process, and adopted
per-generation re-exec on that basis.

There is no mechanism for that. `execute` opens the cache inside its own body, per call
(`Application.lean:1298`), and `open?` allocates `loadedEntries ← IO.mkRef none` on every
construction (`Cache.lean:267`). Nothing outlives a call. The two numbers compared were different
workloads: generation 2 ran **after an edit**, every fast row ran on an **unchanged tree**.

Amended in place, marked as amendments rather than rewritten, per the prompt's stop rule:

| File | Change |
| --- | --- |
| `ruff-16/results/02-implementation.md` | amendment block above decision 3 and above "A defect this prompt found and did not fix" |
| `ruff-16/results/03-acceptance.md` | the remaining-uncertainty entry struck through and annotated |
| `ruff-17-lsp/state/current.md` | `[DISPUTED]` block upgraded to `[REFUTED]` with the confirmed mechanism |
| `ruff-19-performance/state/current.md` | same |
| `ruff-19-performance/roadmap.md` | completion-contract bullet replaced by a `[REMOVED]` stub; the work-order citation of it corrected |

The shipped re-exec behavior is untouched. It was adopted for a reason that did not hold, but it is
not thereby wrong — `RCI-FINAL` still owns that decision, and still owes it a measurement, because
re-exec independently buys the flat retention `ruff-16` measured.

**What the misreading cost, kept as evidence.** A 135× wall-time gap was attributed to the wrong
layer, routed around rather than fixed, and handed to two downstream stacks as an inherited
constraint. Nothing in the measurement was false; the comparison was between workloads that differed
in more than the variable under test. This is the concrete reason the roadmap now requires
entry-level hit/miss counts for any invalidation claim.

## 2. The defect, reproduced at entry granularity

Full table in `evidence/01-invalidation-and-traces.md` §1. The decisive row: after appending one
comment to one of 112 files, `cache.index_hits = 0` — **not 111**. The edit did not invalidate the
edited file's entry, it invalidated the *name of the index*, so no entry was reachable at all. A
second index file appeared and the first was never collected. Reverting the comment restored the
original index file name and served all 112 entries again, which independently confirms the naming is
a content digest over the whole project source set.

To get these counts, this prompt added `cache.targets` / `cache.index_hits` / `cache.served` to the
**existing** `LEAN_FMT_PROFILE_PHASES=1` stderr channel. This is a diagnostic gate alongside
`phase.*`, not a reporting surface: nothing enters `RunReport`, no CLI flag or config key is added.
`index_hits` and `served` are reported separately because they differ exactly when a stored result
cannot answer this run's mode, which separates "the entry was invalidated" from "the entry was
inadequate".

## 3. What Lake's traces guarantee — and the refutation

The roadmap flagged its own reading as sampled rather than verified. Verifying it changed the design.

Characterized shape is in `evidence/…` §3. Three findings matter:

**(a) `deps.imports` is polymorphic.** An array of pairs when the module has in-workspace imports; the
scalar nil hash when it has none. Both occur in this repository. Toolchain imports never appear —
they are covered by the separate `["Lean <version>, commit …", h]` input.

**(b) `"X transitive imports (all)"` excludes `X`.** Measured: adding a real declaration to
`ArtifactModel.lean` changed `ArtifactModel:importAllArts` in both direct dependents and left every
`"ArtifactModel transitive imports (all)"` entry untouched. The key hashes the closure of `X`'s
*imports*. **The design the roadmap and the note proposed would have silently passed the stale case.**

**(c) `"X:importAllArts"` is exactly recomputable from `X`'s own trace.** From Lake's
`computeExportInfo`, it is `Hash.nil` mixed with the content hashes of `X`'s own olean, olean.server,
olean.private, ir.sig, and ir — which are the leading 16 hex digits of `X`'s own `outputs` entries.
Confirmed numerically to the digit (`3c33016ab510a8b4`), and pinned across every (importer, importee)
pair in the built tree by `testLakeTraceCharacterization`, mutation-checked.

(c) is what makes this stack tractable: the answer is *read*, never *derived*. No import resolution
and no transitive-closure tracking is reimplemented, which is the stop rule that would otherwise bite.

## 4. Design comparison, and the frozen check

Both designs the roadmap named were evaluated. Both were then re-evaluated against the corrected
trace semantics, which is where the first one died.

### Design A — per-module staleness, propagated over the trace graph

Compare each module's own-source hash against its trace, mark stale, propagate to dependents.

**Rejected.** `notes/01-what-is-provable.md` §6 already refuted it on a constructed counterexample
(edit `A`; `A` rebuilds; `B` fails to build; both are self-consistent and nothing is detected). The
measurement adds a second, independent reason: the note's proposed *repair* — graph consistency via
`"A transitive imports (all)"` — reads a key that does not contain `A`. Design A is unrecoverable in
the form it was proposed.

### Design B — fold a trace-derived closure digest into per-entry `CacheIdentity`

**Chosen.** For a module `M` with trace `T(M)`:

- `arts(X)` := `Hash.nil` mixed with the content hashes in `T(X).outputs`, in Lake's order
  (`o…`, then `rs`, then `r`). This is Lake's `X:importAllArts`, recomputed from `X`'s own trace.
- `imports(M)` := the set of `X` for which `T(M).deps.imports` records `["X:importAllArts", h]`.
- `closure(M)` := the digest of the ordered sequence of `(X, arts(X))` over the transitive closure of
  `M` under `imports`, together with each recorded expectation `h` paired with the recomputed
  `arts(X)`.

An entry for `M` is current when, in addition to the existing identity components:

1. `M`'s source bytes on disk hash to `T(M)`'s recorded own-source hash — `M` was actually built from
   the bytes being analyzed; and
2. for every `X ∈ imports(M)`, the recorded expectation equals `arts(X)`; and
3. (2) holds recursively for every module in the closure.

`closure(M)` is a new `CacheIdentity` field. Correspondingly, **`sourceRootParts?` comes out of
`environmentDigest?`** — the whole-project source walk that names the index file.

| | Design A | Design B |
| --- | --- | --- |
| Caller knowledge | callers must understand staleness propagation | none; identity stays opaque |
| Invariants hidden | partially — staleness is a second, visible concept | fully — currency is one more identity component |
| Error surface | a propagation pass that can be wrong in either direction | recompute-or-`none`, per target |
| Exactness | unsound as proposed (§6, and (b) above) | sound; see the case table below |
| Cost, warm tree | full source walk still needed for `environment` | ~112 trace reads, replacing 112 **file-content** digests |
| Cost, cold tree | same | same |
| Index churn | index still renamed per edit | **index name stops depending on project sources**: one index |
| `A` changes, no rebuild | **false hit** | miss — `arts(A)` on disk no longer matches `M`'s expectation |

The last row is the one the roadmap called decisive. Under Design B the stale case is caught because
`M`'s recorded expectation is compared against `A`'s *current* artifacts, and neither value is `M`'s
own stored `depHash` — which, read alone, is exactly the trap the roadmap warned about.

### Why it is neither too coarse nor too fine

| Edit | `CacheIdentity.source` | `closure(M)` | Result for `M` | Correct? |
| --- | --- | --- | --- | --- |
| unrelated module `U` edited (`U ∉ closure(M)`) | unchanged | unchanged | **hit** | yes — the measured defect is gone |
| `M`'s own bytes edited | changed | — | miss | yes |
| `A ∈ closure(M)` edited, `.olean` changes, rebuilt | unchanged | changed | miss | yes — the grammar `M` parsed under moved |
| `A ∈ closure(M)` comment-only edit, rebuilt | unchanged | **unchanged** | **hit** | yes — Lake's downstream keys are over artifact content, and a comment cannot change how `M`'s bytes parse |
| `A` edited, `A` rebuilds, `M` fails to build | unchanged | changed | **miss** | yes — this is the §6 counterexample, now caught |
| `A` edited, nothing rebuilt | unchanged | changed | miss | yes — conservative; `M`'s artifact predates the edit |

Row 4 is the "not too fine" case and row 5 is the "not too coarse" case; they are the two the
completion contract asks to be shown separately.

### Preserved

`ResultCache` stays private and constructed only through `open?`. `open?` keeps refusing to
manufacture a partial epoch. Atomic index writes, corrupt-index-is-empty-cache, and
cache-failure-never-changes-results are untouched. Non-source environment inputs — toolchain, search
paths, dependency oleans, shared libraries — keep exactly the coverage they have; this narrows
**project-source** coverage only, which is what the completion contract scopes.

## 5. Tier: decided, and it does not change the answer

A `.source` entry runs source rules over raw bytes with no projection, so on the letter of it, it
needs no import coverage; a `.syntax` entry and anything carrying `canonical?` certainly does.

**Frozen: `closure` is included unconditionally, for every tier.** Two reasons, and the second is the
governing one.

- The cost of over-covering is a miss. The cost of under-covering is a stale hit — a wrong answer,
  and under `format`/`fix` a wrong answer that gets *written to the user's source*. The roadmap says
  it directly: getting this wrong in the permissive direction is a stale hit.
- A tier-conditional identity field would have to be computed identically at write and at read, from
  two call sites, with the tier resolved the same way in both. That is a correctness-critical
  invariant maintained by convention, and this repository's stated preference is against exactly
  that. `CLAUDE.md` already records the general form of this failure: "a rule's tier is its
  `RuleImpl` constructor, never a field; a declared tier field goes unenforced and rots."

Measured cost of the unconditional choice: `closure` reads and parses module trace files, where the
walk it replaces read and SHA-256'd every project **source file**. On this repository the replaced
walk is 112 file-content digests inside a 0.58 s warm run; the replacement is bounded by the same
number of smaller reads. `RCI-IMPL` measures it rather than assuming it, but there is no plausible
world in which trace reads are the expensive half.

## 6. Undeterminable currency degrades to a miss

**Frozen.** `closure(M)` is an `Option`. It is `none` when `T(M)` is absent, unparseable, or of an
unrecognized `schemaVersion`; when `deps.imports` has a shape not covered by §3(a); when any `X ∈
imports(M)` has no readable trace; or when any `outputs` entry cannot be read as a content hash.

`none` makes **that target** a miss. It does not disable the cache and it does not fall back to any
coarser key.

This is deliberately *finer* than the existing convention: `environmentDigest?` returning `none`
disables the whole cache, because it is a property of the epoch. Currency is a property of one entry,
so it degrades one entry. Both share the invariant that matters — the failure direction is always
toward recomputation, never toward serving.

An entry whose currency cannot be established must also not be **written** with a placeholder
`closure` value, which would make it indistinguishable from a genuinely current entry on the next
run. `RCI-IMPL` skips the write for such a target, exactly as `writeAll` already skips a target whose
analysis fails `validAnalysis`.

## 7. The differential test, specified

Fixture: a two-module Lake project under `tests/cache/fixture/`.

- `A.lean` declares a `notation`.
- `B.lean` imports `A` and **uses that notation**. `B` must contain a syntactic construct whose
  parse depends on the notation — not merely a mention of a name from `A`.
- The selected rule set must reach a syntax-tier rule, so that `B`'s entry actually carries a
  projection. A `.source`-only selection would not exercise the thing under test.

Sequence, each step recording `cache.targets` / `cache.index_hits` / `cache.served`:

| Step | Action | Assertion |
| --- | --- | --- |
| 1 | `lake build`; `lean-fmt check`, cold | `served = 0` |
| 2 | `lean-fmt check` again | `served = 2` |
| 3 | Edit **`A`'s notation only** — change its expansion or precedence. Leave `B` **byte-identical**. `lake build`. | — |
| 4 | `lean-fmt check` | **`B` is a miss.** `served = 0` (`A` misses on its own source; `B` misses on `closure`) |

The test asserts `B`'s re-analysis two ways, because the count alone is a weaker claim than the one
being made: the entry-level miss for `B`, **and** that the canonical text `lean-fmt` renders for `B`
matches a fresh no-cache run (`--no-cache`) rather than the pre-edit rendering. The second assertion
is the one that speaks to the actual hazard, which is not a slow run but a rendered output that
changes what the code means.

**Which module is edited: `A`. Which module is asserted re-analyzed: `B`.** They are different
modules, and `B`'s bytes are asserted unchanged (by digest) as part of the test, so a fix that
noticed `B` had been touched cannot pass.

### Mutation check

Remove the `closure` contribution from `CacheIdentity` — the minimal edit is making `closure(M)`
return a constant, which is precisely "the naive fix". Step 4 must then report `B` as **served**,
and the canonical-text assertion must fail against the fresh run. Restore it and both pass. The test
is not accepted until it has been observed to fail in the removed state; a differential test that has
never failed has not been shown to be differential.

### Why an ordinary definition change in `A` is not sufficient

Change a `def` in `A` instead of a `notation`, and `B`'s cached result also becomes wrong — but it
becomes wrong in a way that is *invisible to the projection*. `B`'s tokens, offsets, and node kinds
are unchanged; only elaboration downstream of them differs. A fix that tracked something coarse about
`B`'s dependencies — a modification time, a "did anything I import change" bit, `A`'s source hash —
would pass such a test while still serving a stale **parse** in the notation case.

The notation case is the one where `B`'s cached *syntax projection* is itself false: the same bytes
denote a different tree. Since canonical text is rendered from that projection, serving it can change
what the code means, and that is the one thing the formatter must never do. The test must exercise
the open grammar directly because that is the only failure the correct fix and the naive fix
disagree about.

## 8. Consequences for the rest of the stack

- `RCI-MODEL` should be re-read against §3(b). `notes/01-what-is-provable.md` §6's *counterexample*
  stands; its proposed repair does not. The `grammar_current` lemma's hypothesis A3 — "Lake's
  recorded import hash changes whenever the grammar changes" — should be stated over
  `X:importAllArts`, and its status improves from "testable against Lake's sources" to "read from
  Lake's sources and pinned by a mutation-checked characterization test", which is as strong as a
  claim about another program's implementation gets. The note has been amended to record this.
- `RCI-IMPL` implements §4 and lands §7. The `Project` surface it needs is a way to reach a module's
  trace path and the recorded import names; it must not gain an import resolver.
- `RCI-FINAL` still owns the re-exec decision on measurement, unchanged.

## 9. Checks

| Check | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | 48/48, clean |
| `lake exe lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `testLakeTraceCharacterization` mutation check | fails when the mix order is reversed, passes restored |
| `tests/check/run.sh` | see below |
| `tests/watch/run.sh` | see below |
| `tests/boundary/run.sh` | see below |
| structural checker | see below |
| `write_next.py --check` | see below |
| `git diff --check` | see below |

## 10. Remaining uncertainty

- **The trace characterization is one toolchain and one repository.** Everything in §3 is from
  `v4.33.0-rc1` and this project's own build tree. The nil-`deps.imports` shape, the module-system
  five-artifact mix, and the legacy one-artifact mix are all observed here; a project that is not on
  the module system exercises the legacy branch, and this stack has not run one. The characterization
  test will catch a change rather than prevent one.
- **`closure` cost is argued, not yet measured.** §5's claim that trace reads are cheaper than source
  digests is strongly implied by the workload but `RCI-IMPL` owns the number.
- **Nothing here addresses index collection.** The completion contract requires that stale indices be
  collectable. Design B makes the index name stop depending on project sources, which removes the
  *accumulation*, but the two orphans already on disk in this repository are evidence that no
  collection path exists at all. `RCI-IMPL` or `RCI-FINAL` must state whether one is added or whether
  a stable name makes it moot.
- **A2 remains false in general.** The observation-to-use race in `notes/01-what-is-provable.md` is
  unaffected by anything decided here and is still accepted as a bounded TOCTOU window.
- **Module addition and deletion mid-closure are unexercised.** `RCI-FINAL` owns them. `closure` is
  computed from recorded import *names*, so a deleted module should surface as an unreadable trace
  and degrade to a miss per §6 — but that is a prediction, not a measurement.
