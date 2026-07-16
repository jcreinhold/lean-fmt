---
kind: state
first_unresolved: 01-commands
---

# Current state

`RLF-COMMANDS` is **in progress**: its interface decision is made and its boundary is measured, and no
printer exists yet. Its external prerequisite stack `ruff-02-layout-core` is verified, and its live
implementation still matches recorded state — `LeanFmt/Doc.lean` and `LeanFmt/Comments.lean` are
present in `LeanFmtCore`, and `RLC-FINAL`'s standing observation that **nothing consumes the layout
core** is still true. This stack is what changes that.

`notes/01-command-printing.md` designs the printer interface twice and decides: **the printer reads the
`LosslessSource` projection, not `Lean.Syntax` inside the frontend.** The decision is forced by
`RLS-SPEC`, not chosen here — `ruff-01`'s roadmap line 18 already committed to carrying structure
"without exposing Lean frontend objects to product callers", and the artifact is already the cache key.
Printing inside the frontend would buy free arg order for a median 1.96 s frontend run per file
(`RLS-FINAL`) and would give up the cache to do it.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-commands | RLF-COMMANDS | planned | — |
| 02-expressions | RLF-EXPRESSIONS | planned | RLF-COMMANDS |
| 03-tactics | RLF-TACTICS | planned | RLF-EXPRESSIONS |
| 04-extensions | RLF-EXTENSIONS | planned | RLF-TACTICS |
| 05-corpus | RLF-FINAL | planned | RLF-EXTENSIONS |

## Known evidence

- **A seventh of real syntax cannot be placed by position, so the printer must know the grammar.**
  Measured by `experiments/run-projection-shape.sh` over all 20 modules of this repository, 34,844
  nodes (`evidence/01-projection-shape.txt`): `pre_order_contiguity_violations=0` and
  `nonempty_node_children_out_of_source_order=0`, so a tree view over the projection is
  reconstructable and its child order agrees with the source. But **12,797 nodes (36.7%) carry no
  token at all** — they are *absent* syntax, and `collect` gives them range `(0,0)` because a node's
  range is the hull of the leaves beneath it and there are none. Of those, **5,345 (15.3% of all
  nodes)** sit under a parent that also has direct token children, so nothing in the projection says
  where among its siblings an absent slot belongs. This is not a gap the projection introduced:
  `Lean.Syntax` has no position for an empty node either. A printer therefore cannot reconstruct arg
  order from ranges and must dispatch on kind — which it must do anyway, since canonical layout is
  per-construct by definition.
- **The conservative fallback is the only path that rests on no grammar claim.** Empty nodes
  contribute no bytes, so re-emitting a subtree's tokens in source order with their trivia is
  unaffected by all 5,345 ambiguous placements. The roadmap's "unknown commands must round-trip
  conservatively" and this measurement point the same way.
- **"Are children in arg order" is unaskable of the projection, and asking it produced a vacuous
  pass.** The projection stores only `parent`, so index order is the only order it retains and the
  question compares index order against itself. The probe's first draft asked it and reported
  `misordered=0` — a number no input could have contradicted. Arg order is guaranteed by `collect`'s
  code, not by its output. The replacement check compares index order against *byte* order, and was
  mutation-tested: reversing child order on the real corpus raises it to 4,324.

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- **No printer exists yet.** The interface is decided and the boundary measured; nothing renders a
  `Doc` from a projection, so `RLC-FINAL`'s "nothing consumes the layout core" still stands and every
  layout claim still rests on fixtures written in `ruff-02`.
- **Every supported kind's grammar shape will be a hardcoded claim about a parser the printer cannot
  query.** There is no `Environment` outside the frontend. Each shape must carry the parser
  declaration it mirrors and be pinned by a golden fixture, or it is the "textual guessing" the
  roadmap forbids.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
