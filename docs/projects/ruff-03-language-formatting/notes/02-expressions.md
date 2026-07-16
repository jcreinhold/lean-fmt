# RLF-EXPRESSIONS — where precedence comes from

## 1. The question this has to answer first

`prompts/02-expressions.md` asks for "**precedence-aware** formatting … using parser/category
information rather than textual guessing", and its stop rule says "parentheses may change only with a
precedence proof and exact reparse validation".

`RLF-COMMANDS` decided the printer reads the `LosslessSource` projection and never touches
`Lean.Syntax` or an `Environment` (`notes/01-command-printing.md` §3-5). Precedence lives in Lean's
parser tables, and reading those needs an `Environment`. The projection carries none of it:

    structure Node  where kind : Nat; parent : Option Nat; range : SourceRange
    structure Token where node : Nat; leading; start; stop; trailing; info

(`LeanFmt/LosslessSource.lean:64-86`.) There is no precedence, no priority, no category. So the
question is whether this prompt is blocked on a lower-layer piece — the projection would have to start
carrying precedence, which is `ruff-01`/`ruff-02`'s layer, not this one.

## 2. It is not blocked, and the reason is that the parser already ran

**The tree *is* the precedence, already resolved.** `a + b * c` does not reach the projection as a
flat token run for the printer to re-associate; it reaches it as a tree in which `b * c` is a subtree
of the `+` node, because the parser applied precedence when it built it. The numbers are what the
parser needed to *decide* the shape. The shape is what a printer needs, and the shape is what the
projection has.

This is exactly what the prompt's own phrase asks for. "Using parser/category information rather than
textual guessing" is satisfied by reading the kinds and the tree — the alternative it forbids is
matching `+` in the bytes and guessing what binds tighter. The projection is parser information by
construction: it is the parser's own output.

**Where precedence numbers would still be needed is where the stop rule forbids going anyway.**
Deciding that `(a + b) * c`'s parentheses are *redundant*, or that removing them is safe, needs the
precedence table and a proof. The stop rule already says parentheses may change only with a precedence
proof and exact reparse validation. This prompt does not have the table, so it does not make that
claim, so it does not touch a parenthesis. Those are the same conclusion reached from two directions,
and the second one is the prompt's own instruction.

So the scope is: **re-space and break terms according to their tree; never add, remove, or move a
parenthesis; never touch a literal's contents.** That needs kinds and structure, which the projection
has, and needs nothing it lacks.

## 3. What is not yet decided

- Which term kinds are flat runs that want one space, and which are not. This is the same per-kind
  cited claim `canonical?` makes for commands, and it must be measured before it is designed:
  `RLF-COMMANDS` learned the hard way that a census taken over this repository alone says more about
  the author than about Lean, so the frozen mathlib sample is the corpus that decides here.
- **This is where `Doc`'s break behaviour finally gets exercised.** Every layout so far is a flat run
  of tokens one space apart, so no `group`, `line`, or `nest` has ever reached the engine from real
  source; `RLC-FINAL`'s caveat has been narrowed but not answered. A term is the first thing that can
  exceed the margin.
- **The margin is still unset**, and a layout that breaks needs one. `Printer.format` requires `width`
  rather than defaulting it (`RLC-SPEC` §5: it enters cache identity), and no prompt in this stack has
  picked a value.
- `Doc.hard` emits a newline plus the current indentation, and this printer never nests, so its only
  indentation is column 0 (`startsLine`'s docstring). A term that breaks *inside* an indented command
  cannot use `hard`, and `nest` has never been emitted. Whether that is a gap in the layouts or in
  `Doc`'s use is the first design question this prompt has to settle.
