---
kind: result
claim_id: RCI-MODEL
status: verified
---

# RCI-MODEL — The currency decision, modelled and proved sound and complete

Module: `LeanFmt/Cache/Spec.lean`. Target: `lean_lib LeanFmtCacheSpec`, `@[default_target]`, globbed
alone.

## Summary

The decision `RCI-SPEC` froze is now a pure function over an explicit observation, with a correctness
specification stated independently of it, and both directions proved under four named hypotheses. No
`axiom`, no `sorry`, no `native_decide`; every theorem depends on `propext` and nothing else.

Two things were added beyond the prompt's list because without them the result would have been
weaker than it reads:

- **`stale_grammar_refused` / `stale_source_refused`** — the completion contract's first bullet stated
  directly, rather than left as a contrapositive a reader has to derive from `grammar_current`.
- **A joint-satisfiability witness** in a model with two distinct grammars. Completeness rules out
  the constant-`false` decision, but nothing in the prompt's list rules out `serves_sound`'s
  *hypotheses* being contradictory — and a theorem with contradictory hypotheses is true for reasons
  that have nothing to do with caches.

## 1. Commands

```sh
LEAN_NUM_THREADS=1 lake build          # 50 jobs; the proof library is a default target
tests/boundary/run.sh
tests/check/run.sh
tests/watch/run.sh
lake exe lean-fmt-tests
```

## 2. The model

| Model object | Meaning |
| --- | --- |
| `World` | what the world actually is at decision time — not observable; what the observation is *about* |
| `Obs` | what the cache can observe **without running the frontend**: schema, per-module source digest, per-module closure digest |
| `Entry` | one cached entry: module, schema, tier, the two digests it was built under, and the analysis it will serve |
| `serves : Entry → Obs → Tier → Bool` | the decision, pure |
| `Valid` | the specification: `e.analysis = analyze (w.grammar e.mod) (w.source e.mod) ∧ tier adequate` |
| `BuiltFrom` | what it means for an entry to be a faithful record of *some* past world |
| `Faithful` | A2: the observation reflects the world |

`Tier` is **imported from `LeanFmt.Rules`**, not restated, so `tier_adequate` is about the real
production tier chain and `Tier.satisfies` is the real function. Everything else is a type variable.

### Why `analyze` is a parameter

The note's §2 trap is that defining "what a run should compute" as "whatever the cache returns" makes
every theorem vacuous. This module avoids it **structurally**: `analyze` is universally quantified in
every theorem. A definition could be written to match the implementation; a bound variable cannot.

That quantification is also how **A4 (analysis purity) is discharged** — by modelling analysis as a
function of `(Grammar, Source)` alone, purity is assumed, not proved. The justification is external
and type-level: `Rules.lean` records that a rule "cannot reach a workspace, a cache, an `Environment`,
or `IO` — not by convention but because `run`'s argument type is a fact view".

## 3. The theorems as they landed

```lean
theorem schema_current (hobs : Faithful sd gd o w) (h : serves e o demanded = true) :
    e.schema = w.schema

theorem source_current (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : serves e o demanded = true) :
    s = w.source e.mod

theorem grammar_current (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : serves e o demanded = true) :
    g = w.grammar e.mod

theorem tier_adequate (h : serves e o demanded = true) : e.tier.satisfies demanded = true

theorem serves_sound (hsd : Function.Injective sd) (hgd : Function.Injective gd)
    (hobs : Faithful sd gd o w) (hbuilt : BuiltFrom analyze sd gd e g s)
    (h : serves e o demanded = true) :
    Valid analyze e w demanded

theorem serves_complete (hobs : Faithful sd gd o w) (hschema : e.schema = w.schema)
    (hbuilt : BuiltFrom analyze sd gd e (w.grammar e.mod) (w.source e.mod))
    (htier : e.tier.satisfies demanded = true) :
    serves e o demanded = true

theorem stale_grammar_refused (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : g ≠ w.grammar e.mod) :
    serves e o demanded = false

theorem stale_source_refused (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : s ≠ w.source e.mod) :
    serves e o demanded = false
```

### Hypothesis usage, per theorem

| Theorem | A1 (`hsd`) | A1/A3 (`hgd`) | A2 (`hobs`) | A4 | Notes |
| --- | --- | --- | --- | --- | --- |
| `schema_current` | — | — | ✓ | — | |
| `source_current` | ✓ | — | ✓ | — | |
| `grammar_current` | — | ✓ | ✓ | — | the lemma the stack turns on |
| `tier_adequate` | — | — | — | — | **free**; a projection of the decision |
| `serves_sound` | ✓ | ✓ | ✓ | ✓ | A4 via `analyze`'s type |
| `serves_complete` | — | — | ✓ | ✓ | **no injectivity needed** |
| `stale_grammar_refused` | — | ✓ | ✓ | — | |
| `stale_source_refused` | ✓ | — | ✓ | — | |

Two rows are worth reading twice.

**`tier_adequate` is free.** It needs no assumption because it is entirely within this repository's
control — unlike the other three obstacles, nothing about Lake, the filesystem, or cryptography enters
it. That is a fact about which risks are ours and which are inherited.

**`serves_complete` needs no injectivity.** Soundness needs digests to *separate* distinct values;
completeness needs only that they are *functions*. So A1 and A3 are load-bearing for "never serve a
stale result" and irrelevant to "do not needlessly miss". This is the right shape: a digest collision
causes a wrong answer, never a spurious recomputation. Had the dependency come out the other way, it
would have been a sign the model was wrong.

## 4. Anti-vacuity

Three independent guards, because this is the failure mode the prompt names twice.

1. **`serves_complete`.** `serves := fun _ _ _ => false` satisfies soundness perfectly — a cache that
   never hits never serves a stale result. Completeness is not a bonus theorem; it is half the
   content.
2. **`serves_hits_somewhere`.** The same fact with nothing to follow: an entry exists that is served.
3. **The joint-satisfiability witness.** A concrete model with `Grammar := Bool` — "before and after
   the `notation` edit", the least degenerate case that can still exhibit the hazard — where `sd` and
   `gd` are `id` (so A1/A3 hold on the nose) and every hypothesis of `serves_sound` holds at once.
   `witness_sound_is_inhabited` derives a real `Valid`; `witness_stale_is_refused` then shows the
   entry built under the *old* grammar is refused **in the same fixture**, so soundness and the
   refusal theorem are not agreeing by accident.

Guard 3 was not on the prompt's list. Without it, `serves_sound` could have been true because its
hypotheses cannot be jointly satisfied, and every check the prompt does name would still pass.

## 5. Axiom audit

> **Amended under `RCI-FINAL`.** This section originally reported the audit as eleven `#print axioms`
> statements left **inside** `Spec.lean`, running on every ordinary `lake build`. Those statements were
> removed on instruction: build-time `info:` output is not something to commit. The audit is now a
> manual step, and its recorded output below is a snapshot rather than a continuously enforced
> invariant. That is a real loss — an assumption introduced later will not announce itself in the build
> that introduced it — and it is recorded here rather than glossed. Re-run `#print axioms` before
> marking any claim about these theorems verified. The reading below was re-taken under `RCI-FINAL`
> against the *current* `Spec.lean` — the one that proves about `LeanFmt.Cache.Decision` — by adding
> the statements, building, and reverting. `tier_adequate` appears as `demand_met`: the theorem was
> renamed when the demand grew the `caps` and `renderCanonical` fields the shipped gate already
> required.

`LeanFmtCacheSpec` is a `@[default_target]`, so every `lake build` still *compiles* the proofs; a proof
that stops typechecking fails the build that broke it. What is no longer automatic is the axiom
reading. Verbatim, at the line numbers the statements temporarily occupied:

```
info: LeanFmt/Cache/Spec.lean:324:0: '….schema_current' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:325:0: '….source_current' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:326:0: '….grammar_current' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:327:0: '….demand_met' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:328:0: '….serves_sound' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:329:0: '….serves_complete' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:330:0: '….stale_grammar_refused' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:331:0: '….stale_source_refused' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:332:0: '….serves_hits_somewhere' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:333:0: '….witness_sound_is_inhabited' depends on axioms: [propext]
info: LeanFmt/Cache/Spec.lean:334:0: '….witness_stale_is_refused' depends on axioms: [propext]
```

(Names elided at `…` are `_private.LeanFmt.Cache.Spec.0.LeanFmt.Internal.Cache.Spec.<name>`; the
module is private-by-default, so nothing here is reachable from outside it.)

**`propext` only** — not even `Classical.choice` or `Quot.sound`, which the prompt allowed for. In
particular `sorryAx` would mean a hole and `Lean.ofReduceBool` would mean `native_decide`; neither
appears.

## 6. Specification review (the deliverable a closed goal does not provide)

A closed goal shows the term typechecks. It does not show `Valid` says what `lean-fmt` should do.
That review, by reading:

**What corresponds exactly.** `Tier` and `Tier.satisfies` are the production declarations. `Valid`'s
tier conjunct is precisely the demotion `Application.lean` performs on every lookup via
`cacheHitServes` — an entry that cannot answer this run's mode is a miss, decided once, so every path
below treats it as one.

**What corresponds by construction.** `BuiltFrom` is not an assumption about the world: `writeAll`
writes exactly `(identity, analysisDigest analysis, analysis)`, so every entry the cache itself wrote
satisfies it. The model's `e.analysis = analyze g s` is the shipped invariant that an entry stores the
analysis produced for the target it was keyed on.

**What corresponds only under `RCI-IMPL`.** `Obs.closureDigest` has no counterpart in
`CacheIdentity` yet — it is the field `RCI-IMPL` adds, and `Obs.sourceDigest` corresponds to the
existing `CacheIdentity.source := Digest.ofString target.source`. The model's `schema` conflates
`resultCacheSchema` and `semanticResultSchema`, which the implementation keeps as two fields; that is
a simplification, not a discrepancy, since both are compared for equality and neither is otherwise
used.

**What the model does not cover, deliberately.** `toolchain`, `formatter`, `configuration`, and
`validationLevel` are `CacheIdentity` components the model omits. The completion contract scopes this
stack to **project-source coverage only** — those four keep whatever coverage they have. Folding them
into the model would have implied claims about them that this stack did not measure.

**Where `Valid` could still be wrong.** It says an entry is correct when its analysis equals what
analysis of the current grammar and source produces. It says nothing about whether `analyze` is the
right analysis, nor about the *rendering* of canonical text from that analysis. The formatter's actual
safety property — "the rendered text means what the source meant" — is strictly stronger and is not
modelled here. `Valid` is a necessary condition, not the whole of correctness, and it should not be
cited as though it were.

## 7. Boundary

`LeanFmt.Cache.Spec` must not reach the shipped binary or the compiler plugin: `CLAUDE.md` records
that Lake links every module a library globs, imported or not, and that when the rules were reachable,
editing one rule's message string invalidated every integrated module's Lake trace. A proof about the
cache must not be able to rebuild an integrating project.

Verified by symbol count rather than by assertion, and added to `tests/boundary/run.sh`:

| Image | `LeanFmt_*Cache_Spec` symbols | control: `LeanFmt_Digest` |
| --- | --- | --- |
| `.lake/build/bin/lean-fmt` | **0** | 190 |
| `liblean_x2dfmt_LeanFmtCompilerPlugin.dylib` | **0** | — |

The positive control is part of the check: a zero count for `LeanFmt_Digest` would mean the probe had
stopped looking at anything rather than that the boundary held. Mutation-checked — pointing the probe
at `LeanFmt_Digest` makes it report `proof library entered the link closure of
.lake/build/bin/lean-fmt` and exit 1.

An earlier version of this check reported 134 apparent matches in the binary. They were Lean's own
specialization symbols (`…Lean_Meta_cache_spec__0…`, `…Lake_importModulesUsingCache_spec…`) matching a
too-loose `Cache_Spec` pattern. The shipped probe anchors on `LeanFmt_`.

## 8. Decisions changed during execution

- **The proof library became a `@[default_target]`.** It was not one initially, and `lake build` did
  not build it — which would have made the module's own claim that the audit "runs with every
  ordinary build" false. Being a default target does not put it in any link closure; that follows the
  executable's import graph.
- **`Function.Injective` is used directly** rather than a bespoke predicate. It is in core; no Mathlib
  dependency is introduced.
- **`Tier` is imported rather than modelled.** The first draft restated it. Importing it makes
  `tier_adequate` a claim about production rather than about a lookalike, at no cost — the proof
  library may depend on production, only the reverse is forbidden.

## 9. Remaining uncertainty

- **No one has proved `LeanFmt.Cache` instantiates this model.** ~~This is the largest gap in the
  stack~~ — **closed under `RCI-FINAL`, in the stronger direction than the one proposed here.** This
  bullet asked for a thin `IO` wrapper around a pure function "with this model's shape". What shipped
  instead is `LeanFmt.Cache.Decision`: the model's `Obs`, `Entry`, `identityCurrent` and `serves` moved
  *out* of `Spec.lean` into a production module that `LeanFmt.Cache` and `LeanFmt.Application` call and
  `Spec.lean` imports. There is no lookalike left to drift, so §6's review-by-reading is no longer what
  carries the correspondence for the decision itself. Two residues remain: the theorems still quantify
  over abstract digest types, so A1 is still a hypothesis, and `Provided.meets` runs in `Application`
  while `identityCurrent` runs in `Cache`, so *that* the two halves are both applied is checked by
  `tests/cache/run.sh`, not by a type. Also note the drift this closure exposed: the model as written
  here checked schema, source, closure and tier, while the shipped gate additionally required canonical
  text and semantic caps — so the completeness theorem had been about a strictly more permissive
  decision than the one running. `Demand`/`Provided` in `Decision.lean` carry those fields now.
- **A2 is false in general and unmitigated.** The filesystem can change between observing a trace and
  serving the entry. Nothing here narrows that window; it is accepted as a bounded TOCTOU race, and it
  is a hypothesis rather than an `axiom` so that it appears in the type of everything downstream.
- **A3 is a claim about Lake's implementation.** It was read from `computeExportInfo`, confirmed
  numerically, and pinned by `testLakeTraceCharacterization`. That is as strong as a claim about
  another program gets, and it is still not a theorem.
- **`Valid` is necessary, not sufficient, for formatter safety** — §6's last paragraph. The rendering
  step is unmodelled.
- **The witness model is `Grammar := Bool`.** Two grammars suffice to show the hypotheses are jointly
  satisfiable and that a stale entry is refused; it does not exercise a closure of any depth. The
  graph-shaped cases (a module added or deleted mid-closure, a cyclic-looking import graph) are
  `RCI-FINAL`'s, and the model does not currently say anything about them.
