---
kind: state
first_unresolved: 01-commands
---

# Current state

`RLF-COMMANDS` is **in progress**: the printer skeleton is live and proven lossless, and no canonical
layout exists yet. Its external prerequisite stack `ruff-02-layout-core` is verified and its live
implementation still matches recorded state.

**`RLC-FINAL`'s standing caveat is now half-answered.** That prompt closed the layout stack noting
nothing consumed it, so every claim about realistic documents rested on fixtures written against the
engine. `LeanFmt/Printer.lean` is the first consumer: it renders a real `Doc` from a real projection of
real modules. What it does not yet do is *decide* anything — every kind is still on the conservative
path — so `Doc`'s break behaviour remains exercised only by `ruff-02`'s fixtures. The caveat narrows
from "nothing consumes it" to "nothing yet asks it to break a line".

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

- **Imports are not commands, and the projection structurally cannot carry them.** The corpus holds
  **403 commands in 7 distinct kinds** and not one is an `import`: the module header is not in the
  token stream at all. `headerStop` is 54 bytes on `LeanFmt/Rules.lean` and covers `module` plus both
  `import` lines, recorded as bytes with no node and no token. This is one layer down and deliberate —
  `LosslessSource.ofSource` (`LosslessSource.lean:358`): "Neither producer may pass the module
  header — a module linter never receives it". The plugin producer is a module linter and Lean never
  hands it the header, so no schema carrying header syntax could be produced by both mandated
  producers. **This is not a blocker and not a missing lower-layer piece**:
  `Lean.Parser.parseHeader` (`Lean/Parser/Module.lean:75`) takes an `InputContext` and **no
  `Environment`**, so the printer can parse `[0, headerStop)` with Lean's own parser on bytes
  `normalizedDigest` already binds. The open cost is that `format` acquires an `IO` boundary, or a
  pure header parse must be found.
- **The ownership table is measured, and it is shorter than the prompt's list.**
  `declaration` 336, `namespace` 25, `end` 25, `moduleDoc` 8, `open` 7, `registerOption` 1,
  `initialize` 1 (`evidence/01-projection-shape.txt`). Structures, inductives, attributes, and binders
  are **not** commands — the grammar nests them inside `declaration`, under `declModifiers` and the
  `def`/`theorem`/`structure`/`inductive` choice — so they are reached by dispatching within it. A
  declaration's *value* is a term, which `RLF-EXPRESSIONS` owns; `RLF-COMMANDS` lays out the shell and
  leaves the value conservative, which the skeleton supports directly because one command's `Doc` can
  mix canonical structure with `verbatim` subtrees.
- **The printer skeleton is lossless on real parser output, and the test proves it by mutation.**
  `LeanFmt/Printer.lean` renders header + command extents + `#exit` tail; with every kind on the
  conservative path it is the identity on accepted source. `tests/printer/run.sh`:
  `modules_checked=20 commands=403 failures=0`, at margins 0, 1, 40, 80, 120, and 1000 — the margin
  must not matter, since `verbatim` is specified to emit bytes unchanged and not to force a break.
  A generated fixture on the real parser covers what this repository lacks: a custom `syntax`/
  `macro_rules` command (an unknown kind), CJK and emoji, a multi-line string literal, an inline and a
  newline-spanning block comment, and a 173-byte `#exit` tail. **Non-vacuity is proven twice, and the
  two checks catch different things.** Mutating `tokenEnd` to ignore trailing trivia fails every
  module — but by only *one byte* (5416 → 5415), because dropping a trailing run merely shifts a
  boundary and the next extent absorbs the bytes; only the last command's trailing newline actually
  escapes. Mutating the extent walk to never close at a command boundary is **invisible to byte
  identity** — it round-trips perfectly at every margin — and is caught only by the tiling assertion:
  `11 commands produced 1 extents`. Byte identity alone would have accepted a printer with no
  command structure at all.
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
- **No canonical layout exists yet, so the printer decides nothing.** Every kind takes the
  conservative path, which is why `format` is currently the identity. `RLF-COMMANDS` is not met until
  module headers, imports, namespaces/sections, attributes, binders, declarations, structures,
  inductives, and command comments have cited layouts with golden and idempotence tests. Until then
  the skeleton is proven and the claim is not.
- **`Doc`'s break behaviour is still exercised only by `ruff-02`'s own fixtures.** The printer
  consumes `Doc`, but only through `verbatim`, `cat`, and `empty` — no `group`, `line`, or `nest`
  reaches it from real source yet. `RLC-FINAL`'s "`call-args` is my model of a Lean call, not a Lean
  call" stands until the first canonical layout lands.
- **The margin is unset.** `Printer.format` requires `width` rather than defaulting it: the value is
  configuration, it enters cache identity (`RLC-SPEC` §5), and `RLC-FINAL` left it an open language
  decision. Nothing in this stack has picked one, and no caller passes one outside tests.
- **Every supported kind's grammar shape will be a hardcoded claim about a parser the printer cannot
  query.** There is no `Environment` outside the frontend. Each shape must carry the parser
  declaration it mirrors and be pinned by a golden fixture, or it is the "textual guessing" the
  roadmap forbids.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
