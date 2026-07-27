/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import all LeanFmt.Rules

/-!
# The result cache's currency decision

This is the decision itself — one executable definition, generic in the types the cache instantiates.
`LeanFmt.Cache` and `LeanFmt.Application` **call** these functions; `LeanFmt.Cache.Spec` **proves**
about them. This module exists separately from either so that both use one definition.

Before it, `Spec` defined its own `serves` and the production path re-implemented the same idea across
two modules. Nothing forced them to agree, so a proof about `Spec.serves` said nothing about the
shipped cache — and they had already drifted: the model checked schema, source, closure and tier,
while the shipped gate also required the entry to carry canonical text when the run renders it and to
have captured every semantic sub-fact the run demands. The model's completeness theorem was therefore
about a decision more permissive than the one running.

Generic in `Mod`, `SDigest`, `GDigest`, `Schema` and `Analysis` because the proofs quantify over them;
`Tier` and `SemanticCaps` are the **real** production types, imported rather than restated.

## The split, and why it is not a second decision

`serves` is the whole decision. It factors into two halves that run in different places:

* `identityCurrent` — is this entry *about the current world*? `LeanFmt.Cache.readAll` applies it,
  because only the cache can observe digests.
* `Provided.meets` — does this entry *answer what this run asked*? `LeanFmt.Application` applies it,
  because only the caller knows the rule plan.

They are separate functions so each can run where its inputs are, and `serves` is their conjunction so
neither can drift from the whole. A caller applying only one would be visibly not applying `serves`.
-/

namespace LeanFmt.Internal.Cache.Decision

/-! ## What a run asks for -/

/-- What a run demands of a cached entry.

`tier` is the rule plan's `requiredTier`; `caps` the semantic sub-facts it needs; `renderCanonical`
whether it will print canonical text, which an entry that never computed any cannot supply. -/
structure Demand where
  tier : Tier
  caps : SemanticCaps
  renderCanonical : Bool
  deriving BEq

/-! ## What an entry carries -/

/-- What a cached entry recorded about its own analysis, as far as answering a demand goes.

`broken` means the analysis produced no result at all. Such an entry answers **any** demand: a file
that did not analyze did not analyze at some tier and fail to at another. -/
inductive Provided where
  | broken
  | success (tier : Tier) (caps : SemanticCaps) (hasCanonical : Bool)
  deriving BEq

/-- Does what the entry captured answer what the run asked?

A `.source` shortcut entry computed no syntax findings, so it cannot serve a run selecting a syntax
rule; without the tier clause, shipping the first syntax rule would let a source-only `check` turn a
later `--select FMT008` into a stored false clean. The caps clause is separate: a `.semantic` entry
serves only when it captured every sub-fact demanded, so a fixable-`FMT012` demand against an entry
captured by a report-only check misses and recomputes rather than serving a false clean. -/
def Provided.meets (p : Provided) (d : Demand) : Bool :=
  match p with
  | .broken => true
  | .success tier caps hasCanonical =>
    (!d.renderCanonical || hasCanonical) && tier.satisfies d.tier && d.caps.subset caps

/-! ## The world as the cache can see it -/

/-- What the cache can observe **without running the frontend**: the deserializer's own schema, and,
per module, a source digest and a closure digest recomputed from Lake's recorded traces.

`closureDigest` carries the correction: derived from each import's `X:importAllArts`,
recomputed from `X`'s own trace outputs — **not** from `X transitive imports (all)`, which excludes
`X` itself and would have passed on the stale case the check exists to catch. -/
structure Obs (Mod SDigest GDigest Schema : Type) where
  schema : Schema
  sourceDigest : Mod → SDigest
  closureDigest : Mod → GDigest

/-- One cached entry: what it is for, what it was built under, and what it will serve. -/
structure Entry (Mod Analysis SDigest GDigest Schema : Type) where
  mod : Mod
  schema : Schema
  sourceDigest : SDigest
  closureDigest : GDigest
  provided : Provided
  analysis : Analysis

section

variable {Mod Analysis SDigest GDigest Schema : Type}
  [DecidableEq SDigest] [DecidableEq GDigest] [DecidableEq Schema]

/-- Is this entry about the world as it is now?

The schema is this binary's, the module's own bytes are unchanged, and the grammar it was parsed under
is unchanged.

Note what is **absent**: the entry's own stored `depHash`. Read alone it records what the module was
*built against*, not whether that is still true, and it hits falsely on the stale case that matters.
Currency here compares the entry's recorded expectation against the **currently observed** value. -/
def Entry.identityCurrent (e : Entry Mod Analysis SDigest GDigest Schema)
    (o : Obs Mod SDigest GDigest Schema) : Bool :=
  decide (e.schema = o.schema) &&
  decide (e.sourceDigest = o.sourceDigest e.mod) &&
  decide (e.closureDigest = o.closureDigest e.mod)

/-- The currency decision, pure and entire. -/
def serves (e : Entry Mod Analysis SDigest GDigest Schema)
    (o : Obs Mod SDigest GDigest Schema) (d : Demand) : Bool :=
  e.identityCurrent o && e.provided.meets d

end

end LeanFmt.Internal.Cache.Decision
