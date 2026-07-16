# RLF-COMMANDS — where the printer reads its tree from

## 1. The question

`ruff-02-layout-core` delivered a `Doc` algebra and a renderer, and nothing consumes them. This stack
must produce a `Doc` from an accepted Lean module. The prompt introduces a new abstraction — the
printer — so its interface is designed twice here before anything is built.

The question is not "what does a `def` look like". It is **what the printer reads**, because that
choice fixes the error surface, the cache identity, and whether the printer can ask the parser
anything at all.

## 2. What the boundary actually is (measured, before deciding)

`LosslessSource` carries `kinds : Array String`, `nodes : Array Node` where
`Node = {kind, parent : Option Nat, range}`, and `tokens : Array Token` where `Token` names its
immediate parent node. There is **no children array and no arg index**.

Measured by `experiments/run-projection-shape.sh` over every module of this repository — 20 modules,
34,844 nodes, real parser output — by reconstructing the tree from the projection and testing each
property (`evidence/01-projection-shape.txt`):

| property | result |
| --- | --- |
| subtree of node *j* is a contiguous index range | **0 violations** |
| among a parent's token-bearing node-children, index order agrees with byte order | **0 violations** |
| nodes whose subtree contains no token at all | **12,797 — 36.7%** |
| …of those, whose parent also has direct token children | **5,345 — 15.3% of all nodes** |

The first two are not luck. `LosslessSource.collect` pushes a node's placeholder at
`build.nodes.size` *before* folding its args left to right, so children of one parent necessarily have
strictly increasing indices in arg order, and a pre-order walk necessarily makes each subtree
contiguous. The measurement confirms the reading of the code rather than substituting for it.

**Row 2 is deliberately not "are children in arg order", and the distinction cost a defect to find.**
The projection stores only `parent`, so index order is the *only* order it retains: asking whether
children are in arg order compares index order against itself and returns 0 for every possible input.
The first draft of the probe asked exactly that and reported a reassuring `misordered = 0` that no
input could have contradicted. Arg order is guaranteed by `collect`'s code and is unobservable in its
output. Byte order *is* observable, and index order disagreeing with it is what a fold over args in the
wrong order would actually produce — so that is what row 2 measures. Both hard checks were then
mutation-tested rather than trusted: a synthetic tree whose child precedes its parent, and one with a
foreign node inside a parent's span, each raise the contiguity count; reversing child order on the real
corpus raises row 2 to **4,324**, which is also the number of parents whose child order the check
genuinely exercises.

The last two decide the interface:

- **More than a third of the tree is absent syntax.** `def f : Nat := 0` alone carries seven empty
  `null` children under `declModifiers` — the docComment, attributes, visibility, `noncomputable`,
  `unsafe`, and `partial`/`nonrec` slots. Across the corpus, 11,462 of the 12,797 empty nodes are
  anonymous `null`; the named remainder is exactly what the name suggests — `letConfig` (423),
  `declModifiers` (318), `Termination.suffix` (261), `optDeclSig` (98), `optDeriving` (25). These
  nodes are the *absence* of syntax, recorded positionally.
- **An empty node has range `(0,0)`**, because `collect` computes a node's range as the hull of the
  leaves beneath it and there are none: `span.getD {start := 0, stop := 0}`. This is not information
  the projection dropped — `Lean.Syntax` has none either. An empty `null` node genuinely has no
  position, and `Syntax.getPos?` returns `none` for it.

**Therefore arg order cannot be recovered from positions.** For 5,345 of 34,844 nodes, an empty
node-child sits among direct token-children of the same parent and nothing in the projection says
whether it came before or after them. That is a seventh of the tree, not an edge case, and no amount
of care with ranges fixes it: the information is absent from `Lean.Syntax` upward.

This single fact drives everything below.

## 3. Design A — print from the projection

The printer takes `LosslessSource` + the normalized source and dispatches on `kinds[node.kind]`, a
`String`. It knows the shape of each kind it supports because that shape is written into the printer,
cited against Lean's parser definitions.

- **Caller knowledge.** The caller has the artifact already: the facet produces it, the cache stores
  it, and `Application` fetches it. Formatting needs no new capability and no frontend run.
- **Invariants hidden.** Parent-pointer and pre-order reconstruction stay inside the printer's tree
  view. Callers never see `Lean.Syntax`, which is `ruff-01`'s contract verbatim: "carries byte ranges
  and parent/child structure **without exposing Lean frontend objects to product callers**".
- **Error surface.** An unknown kind is an ordinary case, not an error — it falls back to the
  conservative token round-trip (§5). Layout cannot fail (`RLC-FINAL`), so the printer's whole error
  surface is decode failure, which is already an ordinary miss.
- **Exactness.** The projection is byte-exact by `RLS-FINAL` and `validFor` binds it to its source.
- **Cache identity.** Unchanged. The artifact is already the cache key; formatting is a pure function
  of it plus the margin (configuration, which enters identity — `RLC-SPEC` §5).
- **Critical path.** No frontend run, no environment, no elaboration. Format is artifact → `Doc` →
  string.
- **Memory.** Bounded by the artifact, whose largest instance in `RLS-FINAL`'s frozen sample is
  660,805 B (`Analysis/Normed/Module/Multilinear/Basic.lean`, from a 63,690 B source).

**The cost, stated plainly:** the printer cannot ask Lean what a kind's arguments are. There is no
`Environment` out here. Every supported kind's shape is a hardcoded claim about a parser the printer
cannot query, and it must be sourced by citation and pinned by a golden test, or it is exactly the
"textual guessing" the roadmap forbids one layer up.

## 4. Design B — print inside the exact frontend

The printer runs where the module was parsed, holding real `Lean.Syntax` and a live `Environment`.

- **Caller knowledge.** Formatting now requires an exact frontend run per file. `LeanFmt.Project`
  owns exact setup and one shared no-build graph; this makes formatting a second consumer of it.
- **Invariants hidden.** Fewer: `Syntax` has `getArgs`, so arg order is *free* and the 954 ambiguous
  nodes vanish. The `Environment` can in principle be asked about parser descriptions rather than
  told.
- **Error surface.** Grows to include everything a frontend run can fail at, for an operation that is
  otherwise total.
- **Exactness.** Equal — same parser, same normalized coordinates.
- **Cache identity.** Worse. The artifact stops being sufficient for formatting, so either formatting
  is uncacheable or a second key appears beside the one `RLS-FINAL` verified.
- **Critical path.** A frontend run per format. `RLS-FINAL` measured analysis at median 1.96 s and max
  15.5 s per module on the frozen sample. That is the whole cost of formatting, against ~0 for A.
- **Memory.** A live `Environment` per file, against a 660 KB artifact.

**And it contradicts a decision already made.** `ruff-01`'s completion contract commits to carrying
structure "without exposing Lean frontend objects to product callers", and `AGENTS.md` states the
application "consumes that registered facet through one private no-build Lake operation". Design B
does not extend that architecture; it reopens it.

## 5. Decision

**Design A.** The printer reads the projection.

The decision rests on two things and not on preference:

1. **Cache identity and the critical path.** The artifact exists, is verified byte-exact, and is
   already the cache key. B pays a 1.96 s median frontend run per file to recover an arg index, and
   gives up the cache to do it.
2. **The architecture already chose.** `ruff-01` froze "no frontend objects to product callers" and
   built the facet around it. B is not a printer decision; it is a reversal of `RLS-SPEC`, and it
   would be made here by a prompt that does not own it.

B's one real advantage — free arg order — is worth less than it looks, because **the printer is
grammar-aware under either design**. Canonical layout is per-construct by definition: deciding that a
`def` breaks before `:=` and that an `import` never breaks means knowing you are looking at a `def` and
an `import`. A printer that knew only "node with four children" could not choose a layout at all, so
the grammar shape has to be in the printer regardless of whether arg order is free. What A gives up is
therefore not layout knowledge but the ability to *check* its grammar claims against the parser at
runtime. A golden fixture checks them at build time instead, which is where a claim about a fixed
grammar belongs.

## 6. What this forces on the printer

- **Node-children are read in arg order, never sorted by range.** Arg order is guaranteed by
  `collect`; range order is wrong for 15.3% of nodes and *silently* wrong, which is worse.
- **Every supported kind's shape is a citation.** The shape goes in the printer with the parser
  declaration it mirrors, and a golden fixture pins it. An uncited shape is an unsourced claim.
- **The conservative fallback reads tokens, not the tree.** This is the load-bearing consequence of
  §2: empty nodes contribute no bytes, so a printer that re-emits a subtree's tokens in source order
  with their trivia is unaffected by all 5,345 ambiguous placements. Unknown syntax round-trips
  through the one path that does not depend on the information the projection lacks. The roadmap's
  "unknown commands must round-trip conservatively" and this measurement point the same way — the
  fallback is not a concession, it is the only path whose correctness does not rest on a grammar
  claim.

## 7. What this note does not decide

- The canonical layout of any construct. `RLF-COMMANDS` decides commands; terms, tactics, and
  extensions belong to later prompts and are named here only where they constrain the interface.
- Import sorting. The prompt is explicit that ordered import semantics are preserved and sorting is a
  separate opt-in fix.
- The margin. It is configuration and enters cache identity (`RLC-SPEC` §5); this note does not pick a
  number.

## 8. Risks

- **A hardcoded grammar shape can be wrong or go stale.** The mitigation is citation plus golden
  fixtures plus the idempotence and round-trip checks the roadmap requires, not care.
- **The conservative fallback can be over-used.** A kind that falls back silently looks like success
  and prints the old bytes. `RLF-FINAL` runs a generated syntax-kind inventory for exactly this
  reason; until then, coverage must be reported rather than assumed.
