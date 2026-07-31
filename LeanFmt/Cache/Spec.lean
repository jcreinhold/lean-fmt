/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Cache.Decision

/-!
# The result cache's currency decision, as a pure model

This module exists because the informal claim "the cache is always valid" is not a
Lean theorem, and the shape that *is* a theorem needs stating before anyone writes tactics.

## What is and is not claimed

The intended claim quantifies over the filesystem, the Lean frontend, and Lake — that is, over `IO`.
Lean models `IO` as `EStateM` over an opaque `RealWorld` token whose primitives are `@[extern]`;
nothing in the logic constrains what `IO.FS.readFile` returns. The direct statement is not hard to
prove, it is **not statable**.

What is statable, and what this module does: make the currency decision a pure function of an explicit
observation, specify what a correct answer is *independently* of that function, and prove both
directions **under hypotheses that name every unprovable step**.

The value is not the proof; it is that A1-A4 below must be listed. "We think the cache is safe"
becomes "the cache is safe if and only if A1-A4 hold", and each can then be argued, tested, or
rejected on its own. A2 is *false in general* and is accepted as a bounded race — the kind of fact
this exercise is for.

## Why `analyze` is a parameter, not a definition

Here is the trap: if "what a run should compute" is specified as
"whatever the cache returns", every theorem below is vacuous.

This module avoids that structurally rather than by discipline. `analyze` is **universally
quantified** in every theorem. A definition could be written to match the implementation; a bound
variable cannot. The theorems hold for *every* function of `(Grammar, Source)`, so nothing about the
cache's own behavior can leak into the specification.

That quantification is also how **A4 (analysis purity)** is discharged: modelling analysis as a
function of `(Grammar, Source)` alone assumes purity rather than proving it. The justification is
external and type-level, not a proof — `Rules.lean` records that a rule "cannot reach a workspace, a
cache, an `Environment`, or `IO` — not by convention but because `run`'s argument type is a fact
view". A4 is the one assumption the repository's own types nearly enforce.

## Why both directions

`serves := fun _ _ _ => false` satisfies soundness perfectly: a cache that never hits never serves a
stale result, so "prove the cache is valid" is discharged by disabling the cache. Soundness alone is
worthless, and `serves_complete` is not a bonus theorem — it is half the content.
`serves_hits_somewhere` below is the blunt version of the same check.

## Correspondence to the shipped decision

**The decision proved here is the decision that runs.** `serves`, `Entry`, `Obs`, `Demand` and
`Provided` are imported from `LeanFmt.Cache.Decision`, and `LeanFmt.Cache.readAll` and
`LeanFmt.Application` call those same definitions. There is no second copy to drift.

This shipped without that, and the gap was recorded: the model defined its
own `serves`, the production path re-implemented the idea across two modules, and nothing forced them
to agree. They had already diverged — the model checked schema, source, closure and tier, while the
shipped gate also required canonical text when the run renders it and demanded semantic sub-facts. So
`serves_complete` was proved about a decision more permissive than the one running, which is the
direction that makes a completeness theorem worthless. This was closed by moving the decision
into a module both sides import.

What remains reviewed rather than typechecked is narrower and named: that the *instantiation* is
right — that `Cache.readAll` builds its `Obs` from digests that really do observe the current world.
The four hypotheses below are exactly where that is carried, and A2 is the one known to be false in
general.

The model stays generic in `Mod`, `Source`, `Grammar`, `Analysis` and the digest types because the
proofs quantify over them. `Tier` and `SemanticCaps` are the **real** production types.
-/

namespace LeanFmt.Internal.Cache.Spec

open LeanFmt.Internal.Cache.Decision

/-! ## Objects

`Source` is normalized module text (`raw.crlfToLf`, the repository's one coordinate system).
`Grammar` is the syntax environment a module is parsed under — abstract, and why this stack exists:
Lean's grammar is open, so a `notation` in `A` changes how `B`'s *unchanged bytes* parse. `Analysis`
stands for `SemanticAnalysis`; comparison is `=` on it, because it is data with no quotient and no
chosen representative. -/

section

variable {Mod Grammar Source Analysis SDigest GDigest Schema : Type}

/-- What the world actually is at decision time. Not observable; it is what the observation is
*about*. -/
structure World (Mod Grammar Source Schema : Type) where
  schema : Schema
  grammar : Mod → Grammar
  source : Mod → Source

variable [DecidableEq SDigest] [DecidableEq GDigest] [DecidableEq Schema]

/-! ## The specification, stated independently of the decision

`Entry`, `Obs`, `Demand`, `Provided` and `serves` are **not** defined here. They are
`LeanFmt.Cache.Decision`'s, the ones the shipped cache calls. -/

/-- What it means for an entry to be a correct answer for this world and this demand.

This mentions `serves` nowhere. That is the point: it is the standard the decision is judged against,
not a restatement of it. -/
def Valid (analyze : Grammar → Source → Analysis)
    (e : Entry Mod Analysis SDigest GDigest Schema)
    (w : World Mod Grammar Source Schema) (demand : Demand) : Prop :=
  e.analysis = analyze (w.grammar e.mod) (w.source e.mod) ∧ e.provided.meets demand = true

/-- What it means for an entry to be a faithful record of *some* past world: its digests are the
digests of the grammar and source it was built under, and its analysis is what analysis of those
produces. Any entry the cache itself wrote satisfies this. -/
def BuiltFrom (analyze : Grammar → Source → Analysis)
    (sd : Source → SDigest) (gd : Grammar → GDigest)
    (e : Entry Mod Analysis SDigest GDigest Schema) (g : Grammar) (s : Source) : Prop :=
  e.sourceDigest = sd s ∧ e.closureDigest = gd g ∧ e.analysis = analyze g s

/-! ## A2 — observation faithfulness

**This is the weakest link and it is false in general.** The filesystem can change between the moment
the cache reads a trace and the moment it serves the entry; nothing in the model, and nothing in the
implementation, closes that window. It is a hypothesis rather than an `axiom` so that it appears in
the type of everything that depends on it. -/
def Faithful (sd : Source → SDigest) (gd : Grammar → GDigest)
    (o : Obs Mod SDigest GDigest Schema) (w : World Mod Grammar Source Schema) : Prop :=
  o.schema = w.schema ∧
  (∀ m, o.sourceDigest m = sd (w.source m)) ∧
  (∀ m, o.closureDigest m = gd (w.grammar m))

/-! ## The observation's granularity: artifacts (default) vs interface (opt-in)

The theorems quantify over `gd`, so they are indifferent to how the shipped closure digest
observes grammar currency — but the *fidelity* of that observation is where the two shipped
modes differ, and the difference belongs in this file's ledger.

The default instantiates the observation with Lake's `importAllArts`: any rebuild moves it,
whether or not the elaboration-visible environment moved. That over-observes — proof-only edits
invalidate dependents — and the cost is measured in the plan
(`plans/persistent-result-cache.md`), but it can never stale-hit.

`[cache] closure = "interface"` observes each closure member by the interface hash its
`leanFmtArtifact` sidecar records (falling back per member to `importAllArts` when no current
sidecar exists — dependencies never build the facet, and a sidecar older than its `.olean` is
treated as absent). That observation is *weaker* than grammar currency in two named ways:
kernel `isDefEq` can unfold any definition, so a theorem's proof-term change is
downstream-visible in pathological cases; and attribute deltas on imported declarations live in
environment extensions, outside the hash. Neither gap is modeled above: `Faithful` still must
hold, but the instantiation it quantifies over now approximates `Grammar` rather than
dominating it. The mode is opt-in for exactly this reason, and the kill switch is the default. -/

/-! ## The four obstacles, one lemma each

Each is stated for its caller — "what does the decision entitle me to conclude" — rather than for the
tactic that closes it. They are independent: any one can fail while the others hold. -/

variable {analyze : Grammar → Source → Analysis} {sd : Source → SDigest} {gd : Grammar → GDigest}
  {e : Entry Mod Analysis SDigest GDigest Schema} {o : Obs Mod SDigest GDigest Schema}
  {w : World Mod Grammar Source Schema} {demand : Demand} {g : Grammar} {s : Source}

private theorem identity_conjuncts (h : Entry.identityCurrent e o = true) :
    e.schema = o.schema ∧ e.sourceDigest = o.sourceDigest e.mod ∧
      e.closureDigest = o.closureDigest e.mod := by
  simp only [Entry.identityCurrent, Bool.and_eq_true, decide_eq_true_eq] at h
  exact ⟨h.1.1, h.1.2, h.2⟩

private theorem serves_conjuncts (h : serves e o demand = true) :
    e.schema = o.schema ∧ e.sourceDigest = o.sourceDigest e.mod ∧
      e.closureDigest = o.closureDigest e.mod ∧ e.provided.meets demand = true := by
  simp only [serves, Bool.and_eq_true] at h
  let ⟨a, b, c⟩ := identity_conjuncts h.1
  exact ⟨a, b, c, h.2⟩

/-- **`schema_current`** — the entry's on-disk shape is the one this binary deserializes.

Not new work: this formalizes the versioning discipline `Semantic.lean` already documents at `v2`-`v5`,
where each bump exists because a defaulted field would have read as a false fact. -/
theorem schema_current (hobs : Faithful sd gd o w) (h : serves e o demand = true) :
    e.schema = w.schema :=
  (serves_conjuncts h).1.trans hobs.1

/-- **`source_current`** — the entry's source digest identifies the current source.

Stated over the currency half (`Entry.identityCurrent`) rather than `serves`, so both decisions —
the lint serve and the elaboration verdict — share the one proof. Uses **A1** (digest injectivity
on the values compared) and **A2**. A1 is cryptographic — SHA-256 collision freedom — not provable
in Lean and standard to assume; it is stated once, here, as an injectivity hypothesis on `sd`. -/
theorem source_current (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : Entry.identityCurrent e o = true) :
    s = w.source e.mod := by
  have hdig : sd s = sd (w.source e.mod) := by
    rw [← hbuilt.1, (identity_conjuncts h).2.1, hobs.2.1 e.mod]
  exact hsd hdig

/-- **`grammar_current`** — the entry's artifact was built under `g`; establish `g` is the grammar the
module is under *now*.

This is the lemma the stack depends on, and stating it has already refuted two designs: per-module
self-consistency (edit `A`, `A` rebuilds, `B` fails to build, and
nothing is detected anywhere), then the proposed repair, which was refuted by
measurement — `X transitive imports (all)` excludes `X`, so comparing it would have passed on the
stale grammar case.

Uses **A1/A3** as injectivity of `gd`. That injectivity is a strong assumption: a change in the
grammar a module was parsed under must always change the closure digest derived from Lake's traces.
It is a claim about *Lake's implementation*, checked by reading `computeExportInfo`, confirmed by
measurement, and pinned by `testLakeTraceCharacterization` — but still a hypothesis, not a
theorem. -/
theorem grammar_current (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (h : Entry.identityCurrent e o = true) :
    g = w.grammar e.mod := by
  have hdig : gd g = gd (w.grammar e.mod) := by
    rw [← hbuilt.2.1, (identity_conjuncts h).2.2, hobs.2.2 e.mod]
  exact hgd hdig

/-- **`demand_met`** — a served entry answered what the run actually asked.

Covers all three of the shipped gate's clauses at once, because `Provided.meets` is the shipped gate:
a `.source` entry never serves a selection requiring a syntax rule, an entry that computed no
canonical text never serves a run that renders it, and an entry that captured fewer semantic sub-facts
than the run demanded never serves it.

Needs no assumption at all: it is a projection of the decision, and comes free because it is the one
of the four obstacles wholly within this repository's control. -/
theorem demand_met (h : serves e o demand = true) : e.provided.meets demand = true :=
  (serves_conjuncts h).2.2.2

/-! ## Soundness -/

/-- **If the cache serves an entry, that entry is what a fresh analysis would produce.**

Assembly, deliberately: `analyze` is a function, so equal `(grammar, source)` gives equal analyses.
All the content is in the three lemmas above and the hypotheses they carry.

Depends on **A1** (`hsd`, `hgd`), **A2** (`hobs`), **A3** (folded into `hgd`), and **A4** (discharged
by `analyze`'s type). `hbuilt` is not an assumption about the world — every entry the cache wrote
satisfies it. -/
theorem serves_sound (hsd : Function.Injective sd) (hgd : Function.Injective gd)
    (hobs : Faithful sd gd o w) (hbuilt : BuiltFrom analyze sd gd e g s)
    (h : serves e o demand = true) :
    Valid analyze e w demand := by
  refine ⟨?_, demand_met h⟩
  have hid : Entry.identityCurrent e o = true := by
    simp only [serves, Bool.and_eq_true] at h
    exact h.1
  rw [hbuilt.2.2, source_current hsd hobs hbuilt hid, grammar_current hgd hobs hbuilt hid]

/-! ## Completeness

Without this, `serves := fun _ _ _ => false` would satisfy everything above. -/

/-- **An entry genuinely built from the current world is served.**

Note the difference from soundness: this needs **no injectivity**. Soundness needs digests to separate
distinct values; completeness needs only that they are *functions*. So A1 and A3 matter for "never
serve a stale result" and not at all for "do not needlessly miss" — rightly: a digest collision causes
a wrong answer, never a spurious recomputation. -/
theorem serves_complete (hobs : Faithful sd gd o w)
    (hschema : e.schema = w.schema)
    (hbuilt : BuiltFrom analyze sd gd e (w.grammar e.mod) (w.source e.mod))
    (hmeets : e.provided.meets demand = true) :
    serves e o demand = true := by
  simp only [serves, Entry.identityCurrent, Bool.and_eq_true, decide_eq_true_eq]
  refine ⟨⟨⟨hschema.trans hobs.1.symm, ?_⟩, ?_⟩, hmeets⟩
  · rw [hbuilt.1, hobs.2.1 e.mod]
  · rw [hbuilt.2.1, hobs.2.2 e.mod]

/-! ## What the stack exists to prevent, stated directly

`grammar_current` and `source_current` are the lemmas the assembly needs. These two state the same
facts the other way round, as a reviewer wants them checked. They are named because they are the
completion contract's first bullet rather than a proof step. -/

/-- **An entry built under a grammar that is no longer current is never served.**

The stale-parse hazard in one line. Lean's grammar is open: a `notation` in `A` changes how `B`'s
*unchanged bytes* parse, so `B`'s cached projection describes a tree those bytes no longer denote —
and canonical text rendered from it can change what the code means. -/
theorem stale_grammar_refused (hgd : Function.Injective gd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : g ≠ w.grammar e.mod) :
    serves e o demand = false := by
  cases h : serves e o demand with
  | false => rfl
  | true =>
    have hid : Entry.identityCurrent e o = true := by
      simp only [serves, Bool.and_eq_true] at h
      exact h.1
    exact absurd (grammar_current hgd hobs hbuilt hid) hstale

/-- **An entry built from bytes that are no longer on disk is never served.** -/
theorem stale_source_refused (hsd : Function.Injective sd) (hobs : Faithful sd gd o w)
    (hbuilt : BuiltFrom analyze sd gd e g s) (hstale : s ≠ w.source e.mod) :
    serves e o demand = false := by
  cases h : serves e o demand with
  | false => rfl
  | true =>
    have hid : Entry.identityCurrent e o = true := by
      simp only [serves, Bool.and_eq_true] at h
      exact h.1
    exact absurd (source_current hsd hobs hbuilt hid) hstale

/-! ## The elaboration verdict

`organize`'s question about a candidate — did these bytes elaborate — is a *different* decision
from `serves`, proved here against the same hypotheses. Its currency half is literally
`Entry.identityCurrent`, so `source_current` and `grammar_current` transfer without a second
proof. -/

/-- **verdict_sound** — a verdict is about the current world and says what it says.

`elaborates` means the recorded analysis of these current bytes succeeded; `rejected` means the
entry is the broken record of these current bytes. That a stored broken record is always a
genuine elaboration failure of the bytes — never an `unbuilt` environment deficiency — is
`writeAll`'s half, outside the model. -/
theorem verdict_sound (hsd : Function.Injective sd) (hgd : Function.Injective gd)
    (hobs : Faithful sd gd o w) (hbuilt : BuiltFrom analyze sd gd e g s) {v : ElabVerdict}
    (h : elaborationVerdict? e o = some v) :
    e.analysis = analyze (w.grammar e.mod) (w.source e.mod) ∧
      (v = .rejected ↔ e.provided = .broken) := by
  have hid : Entry.identityCurrent e o = true := by
    simp only [elaborationVerdict?] at h
    split at h
    next hc => exact hc
    next => contradiction
  refine ⟨by rw [hbuilt.2.2, source_current hsd hobs hbuilt hid,
    grammar_current hgd hobs hbuilt hid], ?_⟩
  simp only [elaborationVerdict?] at h
  split at h
  next =>
    have hv := Option.some.inj h
    cases hp : e.provided with
    | broken =>
      simp only [hp] at hv
      subst hv
      exact iff_of_true rfl rfl
    | success tier caps hasCanonical =>
      simp only [hp] at hv
      subst hv
      exact iff_of_false (by decide) (by simp)
  next => contradiction

/-- **verdict_complete** — an entry genuinely built from the current world answers the verdict.

No injectivity, for the same reason as `serves_complete`: a digest collision causes a wrong
answer, never a spurious revalidation. -/
theorem verdict_complete (hobs : Faithful sd gd o w) (hschema : e.schema = w.schema)
    (hbuilt : BuiltFrom analyze sd gd e (w.grammar e.mod) (w.source e.mod)) :
    elaborationVerdict? e o = some (match e.provided with
      | .broken => .rejected
      | .success .. => .elaborates) := by
  have hid : Entry.identityCurrent e o = true := by
    simp only [Entry.identityCurrent, Bool.and_eq_true, decide_eq_true_eq]
    refine ⟨⟨hschema.trans hobs.1.symm, ?_⟩, ?_⟩
    · rw [hbuilt.1, hobs.2.1 e.mod]
    · rw [hbuilt.2.1, hobs.2.2 e.mod]
  simp only [elaborationVerdict?]
  rw [hid]
  exact if_pos rfl

/-! ## Anti-vacuity

`serves_complete` already rules out the constant-`false` decision, but only by an argument a reader
has to follow. This is the same fact with nothing to follow: an entry exists that is served. -/

/-- The decision is not identically `false`. -/
theorem serves_hits_somewhere
    (o : Obs Mod SDigest GDigest Schema) (m : Mod) (a : Analysis) :
    serves ⟨m, o.schema, o.sourceDigest m, o.closureDigest m,
            .success .semantic ⟨true⟩ true, a⟩ o
      ⟨.source, {}, false⟩ = true := by
  simp [serves, Entry.identityCurrent, Provided.meets, Tier.satisfies, SemanticCaps.subset]

end

/-! ## Joint satisfiability of the hypotheses

`serves_hits_somewhere` shows the decision is not constantly `false`. It does not show that
`serves_sound`'s *hypotheses* can all hold at once — and a theorem whose hypotheses are contradictory
is true for a reason that has nothing to do with caches.

So here is a witness, in a model with **two distinct grammars**, the smallest case that can still show
the hazard. `Grammar := Bool` stands for "before and after the `notation` edit"; `sd` and `gd` are
`id`, which is injective, so A1/A3 hold outright. The same fixture then shows the stale entry being
refused, so the two theorems are not agreeing by accident. -/

private abbrev W : World Unit Bool Bool Unit := ⟨(), fun _ => true, fun _ => true⟩
private abbrev O : Obs Unit Bool Bool Unit := ⟨(), fun _ => true, fun _ => true⟩
private abbrev A : Bool → Bool → Bool × Bool := fun g s => (g, s)

/-- An entry built under the *current* grammar (`true`). -/
private abbrev Provides : Provided := .success .semantic ⟨true⟩ true

private abbrev Asks : Demand := ⟨.source, {}, false⟩

private abbrev Fresh : Entry Unit (Bool × Bool) Bool Bool Unit :=
  ⟨(), (), true, true, Provides, (true, true)⟩

/-- The same entry built under the *old* grammar (`false`) — the stale-parse case. Its analysis differs,
which is exactly why serving it would be wrong. -/
private abbrev Stale : Entry Unit (Bool × Bool) Bool Bool Unit :=
  ⟨(), (), true, false, Provides, (false, true)⟩

private theorem witness_faithful : Faithful id id O W := ⟨rfl, fun _ => rfl, fun _ => rfl⟩

private theorem witness_fresh_built : BuiltFrom A id id Fresh true true := ⟨rfl, rfl, rfl⟩

private theorem witness_stale_built : BuiltFrom A id id Stale false true := ⟨rfl, rfl, rfl⟩

/-- Every hypothesis of `serves_sound` holds here, and the conclusion is non-trivial. -/
theorem witness_sound_is_inhabited :
    Valid A Fresh W Asks := by
  refine serves_sound (fun _ _ h => h) (fun _ _ h => h) witness_faithful witness_fresh_built ?_
  decide

/-- ...and in the same fixture, the stale entry is refused rather than served. -/
theorem witness_stale_is_refused : serves Stale O Asks = false := by
  refine stale_grammar_refused (fun _ _ h => h) witness_faithful witness_stale_built ?_
  decide

/-- A broken record of the current bytes. -/
private abbrev Broken : Entry Unit (Bool × Bool) Bool Bool Unit :=
  ⟨(), (), true, true, .broken, (true, true)⟩

/-- The verdict decision on the same fixture: the fresh entry elaborates, a broken record of the
current bytes rejects, and the stale entry answers nothing — a miss, so validate again. -/
theorem witness_verdict_fresh : elaborationVerdict? Fresh O = some .elaborates := by decide

theorem witness_verdict_broken : elaborationVerdict? Broken O = some .rejected := by decide

theorem witness_verdict_stale : elaborationVerdict? Stale O = none := by decide

end LeanFmt.Internal.Cache.Spec
