# What can and cannot be proved about cache validity

This note is the design record for `RCI-MODEL`. It exists because the informal claim "the cache is
always valid" is not a Lean theorem, and the shape that *is* a theorem needs stating before anyone
writes tactics.

## 1. The level audit

The intended claim is: if the cache serves an entry, that entry equals what a fresh analysis would
produce. Written directly, it quantifies over the filesystem, the Lean frontend, and Lake — that is,
over `IO`. Lean models `IO` as `EStateM` over an opaque `RealWorld` token whose primitives are
`@[extern]`; nothing in the logic constrains what `IO.FS.readFile` returns. **No amount of effort makes
the direct statement provable.** It is not hard, it is not statable.

What is statable: make the currency decision a pure function of an explicit observation, specify what a
correct answer is independently of the implementation, and prove the function meets the specification
**under hypotheses** that name every unprovable step.

The value is not the QED. It is that the hypotheses must be enumerated, so "we think the cache is safe"
becomes "the cache is safe exactly if A1–A4 hold", and A1–A4 can then be argued, tested, or rejected
individually.

## 2. Objects and comparison

| Object | Meaning |
| --- | --- |
| `Source` | normalized module text (`raw.crlfToLf`, per the repository's one coordinate system) |
| `Grammar` | the syntax environment a module is parsed under — abstract; the open-grammar dependency |
| `Analysis` | `SemanticAnalysis` |
| `Obs` | what the cache can observe without running the frontend: recorded trace facts, on-disk digests |
| `Tier` | `.source` / `.syntax`, the existing `RuleImpl` constructor distinction |

Comparison is `=` on `Analysis`. It is data with `BEq`/`ToJson`, there is no quotient and no chosen
representative, so equality is the right relation and `≃`/`≅` would be affectation.

```
Spec.analyze : Grammar → Source → Analysis          -- what a run *should* compute
Valid e g s  : Prop := e.analysis = Spec.analyze g s
serves       : Entry → Obs → Tier → Bool            -- the decision, pure
```

**Non-triviality check.** `Spec.analyze` must be defined as the analysis function, never as "whatever
the cache returns". Defined the latter way the theorem is vacuous. Real content remains: digest
equality must imply value equality (A1), and the observation must determine the grammar (A3).

## 3. Obstacles, one lemma each

| Lemma | Obstacle removed |
| --- | --- |
| `source_current` | the entry's source digest identifies the current source |
| `grammar_current` | the entry's artifact was built under `g'`; establish `g' = g` |
| `tier_adequate` | a `.source` entry never serves a selection requiring a syntax rule |
| `schema_current` | the entry's on-disk shape is the one this binary deserializes |

These are independent — each can fail while the others hold. `schema_current` is not new work; it
formalizes the versioning discipline `Semantic.lean` already documents at `v2`–`v5`, where each bump
exists because a defaulted field would have read as a false fact.

The top-level proof is assembly: `Spec.analyze` is a function, so equal `(schema, tier, grammar,
source)` gives equal analyses.

## 4. The assumptions, which are the deliverable

| | Assumption | Status |
| --- | --- | --- |
| A1 | `Digest` is injective on the values compared | Cryptographic (SHA-256 collision freedom). Not provable in Lean; standard to assume; state it once |
| A2 | `Obs` reflects the filesystem at decision time | **Not provable, and false in general.** The filesystem can change between observation and use. The weakest link |
| A3 | Lake's recorded import hash changes whenever the grammar changes | A claim about Lake's implementation. Testable against Lake's sources; not provable here |
| A4 | `Analysis` is a pure function of `(Grammar, Source)` | Nearly *enforced* already: `Rules.lean:17` — a rule "cannot reach a workspace, a cache, an `Environment`, or `IO` ... because `run`'s argument type is a fact view" |

**Carry these as theorem hypotheses, never as `axiom` declarations.** An `axiom` is discharged silently
and invisibly at every use site; a hypothesis appears in the type of everything that depends on it,
which is the entire point. A2 in particular should stay visible, because it is the one that is
*actually false* in the general case and is being accepted as a bounded race.

## 5. Two traps

**Vacuous soundness.** `serves := fun _ _ _ => false` satisfies soundness perfectly. "Prove the cache is
valid" is discharged by disabling the cache. The statement therefore needs a completeness companion —
an entry genuinely built from the current world *is* served — or the proof means nothing. Both
directions, or neither.

**Proving the implementation instead of the specification.** A closed goal shows the term type-checks.
It does not show `Spec.analyze` describes what `lean-fmt` should do. The specification must be reviewed
against intent by reading, and that review is a deliverable of `RCI-MODEL`, not a consequence of it.

## 6. What this already ruled out

Stating `grammar_current` refutes the design this stack was first rescoped toward — "compare each
module's own-source hash against its trace, propagate staleness to dependents":

1. Edit `A`. Run `lake build`. `A` rebuilds; `B`'s build **fails**.
2. `A`'s trace is fresh and `A`'s source matches it.
3. `B`'s source never changed, so `B`'s source matches `B`'s **old** trace.
4. No staleness is detected — and `B`'s artifact encodes **old-`A` grammar**. Stale hit.

Per-module self-consistency is insufficient; `grammar_current` is unprovable under it. The check must be
graph consistency: `B`'s recorded `["A transitive imports (all)", h]` must agree with `A`'s *current*
recorded value. `RCI-SPEC` owns confirming this against Lake's sources — the counterexample is
constructed from the trace format as sampled, not from Lake's implementation.

That refutation is the argument for doing this work at all: the design survived review, and did not
survive an attempt to state its theorem.

## 7. Where the module goes

Not a single top-level `Proofs.lean`. It would import most of the tree, inverting the dependency
direction, and become the grab-bag this repository's deep-module preference exists to avoid. Put the
pure model and its theorems next to what they specify — `LeanFmt/Cache/Spec.lean` — so a later proof
about the printer lives next to the printer.

**The library glob matters more than the filename.** `CLAUDE.md` records that Lake links every module a
library globs, imported or not, and that reachable rules once invalidated every integrated module's
trace. Proof modules must not enter `LeanFmtCompilerPlugin` or the shipped binary's link closure. Give
them their own `lean_lib` and glob it explicitly.

## 8. Consequence for the roadmaps

Every `ruff-*` roadmap sets `blueprint_tracked: false` on the grounds that the work "introduces no
mathematical theorem claim". This stack would introduce one. That flag should be flipped deliberately
for this stack, with the scope stated — a soundness/completeness pair for one decision function, not a
verified formatter — rather than left stale.
