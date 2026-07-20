module

import all LeanFmt.Rules

/-!
# The result cache's currency decision, as a pure model

This module is `RCI-MODEL`. It exists because the informal claim "the cache is always valid" is not a
Lean theorem, and the shape that *is* a theorem needs stating before anyone writes tactics.

## What is and is not claimed

The intended claim quantifies over the filesystem, the Lean frontend, and Lake — that is, over `IO`.
Lean models `IO` as `EStateM` over an opaque `RealWorld` token whose primitives are `@[extern]`;
nothing in the logic constrains what `IO.FS.readFile` returns. The direct statement is not hard to
prove, it is **not statable**.

What is statable, and what this module does: make the currency decision a pure function of an explicit
observation, specify what a correct answer is *independently* of that function, and prove both
directions **under hypotheses that name every unprovable step**.

The value is not the QED. It is that A1-A4 below must be enumerated, so "we think the cache is safe"
becomes "the cache is safe exactly if A1-A4 hold", and each can then be argued, tested, or rejected
on its own. A2 is *false in general* and is being accepted as a bounded race; that is precisely the
kind of fact this exercise is for.

## Why `analyze` is a parameter, not a definition

`notes/01-what-is-provable.md` §2 records the trap: if the specification of "what a run should
compute" is defined as "whatever the cache returns", every theorem below is vacuous.

This module avoids that structurally rather than by discipline. `analyze` is **universally
quantified** in every theorem. A definition could be written to match the implementation; a bound
variable cannot. The theorems hold for *every* function of `(Grammar, Source)`, so nothing about the
cache's own behavior can leak into the specification.

That quantification is also how **A4 (analysis purity)** is discharged: by modelling analysis as a
function of `(Grammar, Source)` alone, purity is assumed rather than proved. The justification is
external and type-level, not a proof — `Rules.lean` records that a rule "cannot reach a workspace, a
cache, an `Environment`, or `IO` — not by convention but because `run`'s argument type is a fact
view". A4 is the one assumption the repository's own types nearly enforce.

## Why both directions

`serves := fun _ _ _ => false` satisfies soundness perfectly: a cache that never hits never serves a
stale result. "Prove the cache is valid" is discharged by disabling the cache. So soundness alone is
worthless, and `serves_complete` is not a bonus theorem — it is half the content.
`serves_hits_somewhere` below is the blunt version of the same check.

## Correspondence to the shipped decision

The model is deliberately generic: `Mod`, `Source`, `Grammar`, `Analysis` and the digest types are
type variables, and the shipped cache is one instantiation. `Tier` is the **real** production type,
imported rather than restated, so `tier_adequate` is about the actual tier chain.

Everything else is a correspondence claim that is *reviewed*, not typechecked: no one has proved that
`LeanFmt.Cache` instantiates this model. `results/02-model.md` §6 records that review, and it is the
stack's largest remaining gap. A closed goal shows a term typechecks; it does not show the
specification says the right thing.
-/

namespace LeanFmt.Internal.Cache.Spec

/-! ## Objects

`Source` is normalized module text (`raw.crlfToLf`, the repository's one coordinate system).
`Grammar` is the syntax environment a module is parsed under — abstract, and the whole reason this
stack exists: Lean's grammar is open, so a `notation` in `A` changes how `B`'s *unchanged bytes*
parse. `Analysis` stands for `SemanticAnalysis`; comparison is `=` on it, because it is data with no
quotient and no chosen representative, so `≃` would be affectation. -/

section

variable {Mod Grammar Source Analysis SDigest GDigest Schema : Type}

/-- What the world actually is at decision time. Not observable; it is what the observation is
*about*. -/
structure World (Mod Grammar Source Schema : Type) where
  schema : Schema
  grammar : Mod → Grammar
  source : Mod → Source

/-- What the cache can observe **without running the frontend**: the deserializer's own schema, and,
per module, a source digest and a closure digest recomputed from Lake's recorded traces.

`closureDigest` is where `RCI-SPEC`'s correction lives. It is derived from each import's
`X:importAllArts`, recomputed from `X`'s own trace outputs — *not* from `X transitive imports (all)`,
which excludes `X` itself and would have made the whole exercise pass on the stale case it exists to
catch. -/
structure Obs (Mod SDigest GDigest Schema : Type) where
  schema : Schema
  sourceDigest : Mod → SDigest
  closureDigest : Mod → GDigest

/-- One cached entry: what it is for, what it was built under, and what it will serve. -/
structure Entry (Mod Analysis SDigest GDigest Schema : Type) where
  mod : Mod
  schema : Schema
  tier : Tier
  sourceDigest : SDigest
  closureDigest : GDigest
  analysis : Analysis

variable [DecidableEq SDigest] [DecidableEq GDigest] [DecidableEq Schema]

/-! ## The decision -/

/-- The currency decision, pure. This is `RCI-SPEC` §4 Design B: an entry serves when the schema is
this binary's, the module's own bytes are unchanged, the grammar it was parsed under is unchanged,
and its tier answers what the run demands.

Note what is **absent**: the entry's own stored `depHash`. Read alone that records what the module was
*built against*, not whether that is still true, and it falsely hits in exactly the stale case that
matters. Currency here compares the entry's recorded expectation against the **currently observed**
value. -/
def serves (e : Entry Mod Analysis SDigest GDigest Schema)
    (o : Obs Mod SDigest GDigest Schema) (demanded : Tier) : Bool :=
  decide (e.schema = o.schema) &&
  decide (e.sourceDigest = o.sourceDigest e.mod) &&
  decide (e.closureDigest = o.closureDigest e.mod) &&
  e.tier.satisfies demanded

/-! ## The specification, stated independently of the decision -/

/-- What it means for an entry to be a correct answer for this world and this demand.

This mentions `serves` nowhere. That is the point: it is the standard the decision is judged against,
not a restatement of it. -/
def Valid (analyze : Grammar → Source → Analysis)
    (e : Entry Mod Analysis SDigest GDigest Schema)
    (w : World Mod Grammar Source Schema) (demanded : Tier) : Prop :=
  e.analysis = analyze (w.grammar e.mod) (w.source e.mod) ∧ e.tier.satisfies demanded = true

/-- What it means for an entry to be a faithful record of *some* past world: its digests are the
digests of the grammar and source it was built under, and its analysis is what analysis of those
produces. Any entry the cache itself wrote satisfies this by construction. -/
def BuiltFrom (analyze : Grammar → Source → Analysis)
    (sd : Source → SDigest) (gd : Grammar → GDigest)
    (e : Entry Mod Analysis SDigest GDigest Schema) (g : Grammar) (s : Source) : Prop :=
  e.sourceDigest = sd s ∧ e.closureDigest = gd g ∧ e.analysis = analyze g s

/-! ## A2 — observation faithfulness

**This is the weakest link and it is false in general.** The filesystem can change between the moment
the cache reads a trace and the moment it serves the entry; nothing in the model, and nothing in the
implementation, closes that window. It is carried as a hypothesis rather than an `axiom` precisely so
it appears in the type of everything that depends on it. -/
def Faithful (sd : Source → SDigest) (gd : Grammar → GDigest)
    (o : Obs Mod SDigest GDigest Schema) (w : World Mod Grammar Source Schema) : Prop :=
  o.schema = w.schema ∧
  (∀ m, o.sourceDigest m = sd (w.source m)) ∧
  (∀ m, o.closureDigest m = gd (w.grammar m))

/-! ## The four obstacles, one lemma each

Each is stated for its caller — "what does the decision entitle me to conclude" — rather than for the
tactic that closes it. They are independent: any one can fail while the others hold. -/

variable {analyze : Grammar → Source → Analysis} {sd : Source → SDigest} {gd : Grammar → GDigest}
  {e : Entry Mod Analysis SDigest GDigest Schema} {o : Obs Mod SDigest GDigest Schema}
  {w : World Mod Grammar Source Schema} {demanded : Tier} {g : Grammar} {s : Source}

private theorem serves_conjuncts (h : serves e o demanded = true) :
    e.schema = o.schema ∧ e.sourceDigest = o.sourceDigest e.mod ∧
      e.closureDigest = o.closureDigest e.mod ∧ e.tier.satisfies demanded = true := by
  simp only [serves, Bool.and_eq_true, decide_eq_true_eq] at h
  exact ⟨h.1.1.1, h.1.1.2, h.1.2, h.2⟩

/-- **`schema_current`** — the entry's on-disk shape is the one this binary deserializes.

Not new work: this formalizes the versioning discipline `Semantic.lean` already documents at `v2`-`v5`,
where each bump exists because a defaulted field would have read as a false fact. -/
theorem schema_current (hobs : Faithful sd gd o w) (h : serves e o demanded = true) :
    e.schema = w.schema :=
  (serves_conjuncts h).1.trans hobs.1

/-- **`source_current`** — the entry's source digest identifies the current source.

Uses **A1** (digest injectivity on the values compared) and **A2**. A1 is cryptographic — SHA-256
collision freedom — not provable in Lean and standard to assume; it is stated once, here, as an
injectivity hypothesis on `sd`. -/
theorem source_current (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : serves e o demanded = true) :
    s = w.source e.mod := by
  have hdig : sd s = sd (w.source e.mod) := by
    rw [← hbuilt.1, (serves_conjuncts h).2.1, hobs.2.1 e.mod]
  exact hsd hdig

/-- **`grammar_current`** — the entry's artifact was built under `g`; establish `g` is the grammar the
module is under *now*.

This is the lemma the whole stack turns on, and stating it has already refuted two designs. It refuted
per-module self-consistency (`notes/01-what-is-provable.md` §6: edit `A`, `A` rebuilds, `B` fails to
build, and nothing is detected anywhere). Then `RCI-SPEC` refuted that note's proposed repair by
measurement — `X transitive imports (all)` excludes `X`, so comparing it would have passed on the
stale grammar case.

Uses **A1/A3** as injectivity of `gd`. That injectivity is doing heavy lifting and deserves its name:
it says a change in the grammar a module was parsed under always changes the closure digest derived
from Lake's traces. It is a claim about *Lake's implementation*, verified by reading
`computeExportInfo`, confirmed numerically, and pinned by `testLakeTraceCharacterization` — but still
a hypothesis, not a theorem. -/
theorem grammar_current (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : serves e o demanded = true) :
    g = w.grammar e.mod := by
  have hdig : gd g = gd (w.grammar e.mod) := by
    rw [← hbuilt.2.1, (serves_conjuncts h).2.2.1, hobs.2.2 e.mod]
  exact hgd hdig

/-- **`tier_adequate`** — a `.source` entry never serves a selection requiring a syntax rule.

Needs no assumption at all: it is a projection of the decision. That it is free is worth noticing,
because it is the one of the four obstacles that is entirely within this repository's control. -/
theorem tier_adequate (h : serves e o demanded = true) : e.tier.satisfies demanded = true :=
  (serves_conjuncts h).2.2.2

/-! ## Soundness -/

/-- **If the cache serves an entry, that entry is what a fresh analysis would produce.**

Assembly, and deliberately so: `analyze` is a function, so equal `(grammar, source)` gives equal
analyses. All the content is in the three lemmas above and the hypotheses they carry.

Depends on **A1** (`hsd`, `hgd`), **A2** (`hobs`), **A3** (folded into `hgd`), and **A4** (discharged
by `analyze`'s type). `hbuilt` is not an assumption about the world — every entry the cache wrote
satisfies it by construction. -/
theorem serves_sound (hsd : Function.Injective sd) (hgd : Function.Injective gd)
    (hobs : Faithful sd gd o w) (hbuilt : BuiltFrom analyze sd gd e g s)
    (h : serves e o demanded = true) :
    Valid analyze e w demanded := by
  refine ⟨?_, tier_adequate h⟩
  rw [hbuilt.2.2, source_current hsd hobs hbuilt h, grammar_current hgd hobs hbuilt h]

/-! ## Completeness

Without this, `serves := fun _ _ _ => false` would satisfy everything above. -/

/-- **An entry genuinely built from the current world is served.**

Note the asymmetry with soundness: this needs **no injectivity**. Soundness needs digests to separate
distinct values; completeness needs only that they are *functions*. So A1 and A3 are load-bearing for
"never serve a stale result" and irrelevant to "do not needlessly miss" — which is the right shape,
since a digest collision causes a wrong answer and never a spurious recomputation. -/
theorem serves_complete (hobs : Faithful sd gd o w)
    (hschema : e.schema = w.schema)
    (hbuilt : BuiltFrom analyze sd gd e (w.grammar e.mod) (w.source e.mod))
    (htier : e.tier.satisfies demanded = true) :
    serves e o demanded = true := by
  simp only [serves, Bool.and_eq_true, decide_eq_true_eq]
  refine ⟨⟨⟨hschema.trans hobs.1.symm, ?_⟩, ?_⟩, htier⟩
  · rw [hbuilt.1, hobs.2.1 e.mod]
  · rw [hbuilt.2.1, hobs.2.2 e.mod]

/-! ## What the stack exists to prevent, stated directly

`grammar_current` and `source_current` are the lemmas the assembly needs. These two are the same facts
turned around to say what a reviewer actually wants checked, and they are worth naming because they
are the completion contract's first bullet rather than a proof step. -/

/-- **An entry built under a grammar that is no longer current is never served.**

This is the stale-parse hazard in one line. Lean's grammar is open: a `notation` in `A` changes how
`B`'s *unchanged bytes* parse, so `B`'s cached projection describes a tree those bytes no longer
denote — and canonical text rendered from it can change what the code means. -/
theorem stale_grammar_refused (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : g ≠ w.grammar e.mod) :
    serves e o demanded = false := by
  cases h : serves e o demanded with
  | false => rfl
  | true => exact absurd (grammar_current hgd hobs hbuilt h) hstale

/-- **An entry built from bytes that are no longer on disk is never served.** -/
theorem stale_source_refused (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : s ≠ w.source e.mod) :
    serves e o demanded = false := by
  cases h : serves e o demanded with
  | false => rfl
  | true => exact absurd (source_current hsd hobs hbuilt h) hstale

/-! ## Anti-vacuity

`serves_complete` already rules out the constant-`false` decision, but only by an argument a reader
has to follow. This is the same fact with nothing to follow: an entry exists that is served. -/

/-- The decision is not identically `false`. -/
theorem serves_hits_somewhere
    (o : Obs Mod SDigest GDigest Schema) (m : Mod) (a : Analysis) :
    serves ⟨m, o.schema, .semantic, o.sourceDigest m, o.closureDigest m, a⟩ o .source = true := by
  simp [serves, Tier.satisfies]

end

/-! ## Joint satisfiability of the hypotheses

`serves_hits_somewhere` shows the decision is not constantly `false`. It does not show that
`serves_sound`'s *hypotheses* can all hold at once — and a theorem whose hypotheses are contradictory
is true for a reason that has nothing to do with caches.

So here is a witness, in a model with **two distinct grammars**, which is the least degenerate case
that can still exhibit the hazard. `Grammar := Bool` stands for "before and after the `notation`
edit"; `sd` and `gd` are `id`, which is injective, so A1/A3 hold on the nose. The same fixture then
shows the stale entry being refused, so the two theorems are not agreeing by accident. -/

private abbrev W : World Unit Bool Bool Unit := ⟨(), fun _ => true, fun _ => true⟩
private abbrev O : Obs Unit Bool Bool Unit := ⟨(), fun _ => true, fun _ => true⟩
private abbrev A : Bool → Bool → Bool × Bool := fun g s => (g, s)

/-- An entry built under the *current* grammar (`true`). -/
private abbrev Fresh : Entry Unit (Bool × Bool) Bool Bool Unit :=
  ⟨(), (), .semantic, true, true, (true, true)⟩

/-- The same entry built under the *old* grammar (`false`) — the stale-parse case. Note its analysis
differs, which is exactly why serving it would be wrong. -/
private abbrev Stale : Entry Unit (Bool × Bool) Bool Bool Unit :=
  ⟨(), (), .semantic, true, false, (false, true)⟩

private theorem witness_faithful : Faithful id id O W := ⟨rfl, fun _ => rfl, fun _ => rfl⟩

private theorem witness_fresh_built : BuiltFrom A id id Fresh true true := ⟨rfl, rfl, rfl⟩

private theorem witness_stale_built : BuiltFrom A id id Stale false true := ⟨rfl, rfl, rfl⟩

/-- Every hypothesis of `serves_sound` holds here, and the conclusion is non-trivial. -/
theorem witness_sound_is_inhabited :
    Valid A Fresh W .source := by
  refine serves_sound (fun _ _ h => h) (fun _ _ h => h) witness_faithful witness_fresh_built ?_
  decide

/-- ...and in the same fixture, the stale entry is refused rather than served. -/
theorem witness_stale_is_refused : serves Stale O .source = false := by
  refine stale_grammar_refused (fun _ _ h => h) witness_faithful witness_stale_built ?_
  decide

/-! ## Axiom audit

These are left in the module rather than run once and pasted into a result note. The prompt's stop
rule is "no `axiom` declarations, no `sorry`, no `native_decide`", and a check that runs only when
someone remembers to run it does not enforce that. Here, the audit is part of building the module, so
a later edit that introduces an assumption shows up in the build output of the change that introduced
it.

The expected output is Lean's own three — `propext`, `Classical.choice`, `Quot.sound` — and nothing
else. In particular `Lean.ofReduceBool` would mean `native_decide` had appeared, and `sorryAx` would
mean a hole. -/

#print axioms schema_current
#print axioms source_current
#print axioms grammar_current
#print axioms tier_adequate
#print axioms serves_sound
#print axioms serves_complete
#print axioms stale_grammar_refused
#print axioms stale_source_refused
#print axioms serves_hits_somewhere
#print axioms witness_sound_is_inhabited
#print axioms witness_stale_is_refused

end LeanFmt.Internal.Cache.Spec
