# Canonical Lean style

This is what formatted source looks like, and why.

`lean-fmt` has one style. Configuration chooses the line width (100 by default), not a family of competing layouts.
Layout comes from the parsed structure of your code and the Lean syntax in scope; lean-fmt does not preserve source
alignment or keep a table of preferred spellings.

Each decision below carries an ID such as `header.imports` or `terms.operator`. The same IDs index a test matrix, so a
decision cannot be dropped or renamed without a test failing.

## Global rules

- Indentation is two spaces per level of nesting. A continued line indents from the construct that owns it; nothing is
  ever aligned to a column an earlier token happened to land on.
- A construct stays on one line when it fits, and otherwise breaks into the form shown below. Where the breaks fall
  depends on the width alone, never on how the input was already broken.
- Anything that can be broken reflows at the configured width. A literal, URL, identifier, comment text, or unbreakable
  token from project-defined syntax may exceed it. `FMT016` reports every row that does; it is off by default because
  the unbreakable rows are the common case.
- Horizontal whitespace is one space where separation is required and absent next to hugged delimiters. There are no
  tabs or trailing spaces in formatter-owned output.
- A module ends in one newline. Everything from a terminal command such as `#exit` onward is copied verbatim. Your
  file's CRLF or LF line endings are restored when it is written back.
- Source order carries meaning, so formatting never sorts. Imports, modifiers, binders, fields, constructors, match
  arms, tactics, `do` items, and custom syntax stay in the order you wrote them.
- A comment keeps its exact text and stays attached to one construct. Reindenting moves the comment, never the
  characters inside it. The same holds for strings, character literals, and quotations.

## Headers and commands

`header.imports` keeps `module` and ordered imports at the left margin, one import statement per line. Import modifiers
stay in source order. A comment-separated import group stays a group; formatting never deduplicates, reorders, or
organizes imports. A row that exceeds the line width overflows whole: an import cannot be shortened, so the tokens of
one row (`public`, `import`, the module name) never stack vertically — mathlib's longLine linter exempts whole import
lines for exactly this reason. One blank line follows the header before the first ordinary command.

`commands.namespace` writes `namespace Name`, `section Name`, their bodies, and matching `end Name` at the command
column. Namespace and section nesting changes names and scope, not command indentation. One blank line separates
top-level declaration-like commands; cohesive setup commands (`open`, `export`, `universe`, `variable`, local options)
may stay adjacent. Empty vertical padding is not preserved: a run of consecutive blank lines collapses to one.

`commands.modifiers` keeps doc comments on their own line, then attributes, visibility/safety modifiers, and the
declaration keyword in parsed order. Short attribute lists are flat (`@[simp, aesop safe]`); long lists break after `@[`
with one entry per line and a closing `]` at the attribute's indentation. A top-level declaration's attribute list
always occupies its own line above the declaration, even a short one: `@[simp] theorem foo` comes back as `@[simp]` on
one line and `theorem foo` on the next. That is Lean's own layout for the construct, not a width decision. Lean has a
separate inline form, used for structure fields, `let rec`, and binders, which stays on one line.

An attribute argument can itself be a doc comment — `@[to_additive /-- … -/]` is the mathlib shape. Its text is never
reflowed, so the only width lean-fmt controls is which column it starts at. A doc comment written against its attribute
stays there; one written on its own line moves left, along with the closing `]`, to the attribute list's own column.

`commands.syntax` keeps `syntax`, `notation`, `macro`, `open`, `export`, `universe`, `variable`, and `set_option` on one
line while they fit. Anything nested inside — a term, a parser, a tactic — breaks by its own rules. A long `notation`
declaration breaks only between its parts, never inside a quoted token.

## Declarations and members

`decl.signature` keeps the whole header on one line when it fits, and the body goes on the next line at two spaces:

```lean
def map (f : α → β) (xs : List α) : List β :=
  xs.map f
```

That second line is `declaration-body`'s default, `"next-line"`. Under `"same-line"` a body that fits joins the header
row instead: `def map (f : α → β) (xs : List α) : List β := xs.map f`. Everything below is the same either way.

When the header does not fit, the binders keep their order on continuation lines four spaces from the declaration, the
result type breaks on its own if it has to, and the body starts two spaces from the declaration:

```lean
def map (f : α → β)
    (xs : List α) :
    List β :=
  xs.map f
```

Binders pack rather than taking a line each: the first stays on the header line while it fits, and they split one per
line only when they cannot share a row. The four-space continuation and the two-space body differ on purpose: with both
at two, the last binder and the first line of the body would sit in the same column.

The same header model applies to `def`, `abbrev`, `opaque`, `theorem`, `lemma`, `example`, `instance`, and shared
declaration forms. Termination and decreasing clauses follow the body at declaration indentation; `where` begins at
declaration indentation and owns a two-space-indented declaration list.

`decl.members` writes structure/class fields and inductive constructors one per line at two spaces. Constructor pipes
align with each other, not with source columns. Field defaults and constructor types use ordinary term groups. A short
`deriving` group stays flat; a broken group has one class per line.

`decl.mutual` writes `mutual` and `end` at the owner's indentation and each member two spaces within it. Blank lines
separate full member declarations, not individual binders or constructors.

## Terms and operators

`terms.application` keeps a fitting application flat. A broken application keeps the function on the first line and
places arguments at a two-space hanging indent, one structural argument group per line. Named arguments stay atomic with
their value boundary. Projections hug their receiver and projection name.

`terms.operator` reads precedence and association from syntax, never from a flat token stream. A flat chain has one
space around an infix operator. A broken chain leaves the operator with its left operand and indents the following
operand two spaces. Two spaces once, not once per link: every break in one chain lands at the same column however many
operands it has, and either associativity reads the same way. A parenthesised sub-chain is a separate chain and holds a
column of its own. Identifier operands are ordinary operands: `a+1`, `a+b`, qualified names, and Unicode notation all
participate in spacing and reflow.

`terms.lambda-let-if` keeps a small lambda or `let` flat. Broken lambda bodies are indented two spaces after `=>`;
sequential `let` bindings occupy their own lines. A broken conditional is:

```lean
if condition then
  yes
else
  no
```

Parentheses are introduced or retained only when precedence/parenthesizer structure requires them.

## Delimited forms, records, and matches

`collections.delimiters` hugs empty and flat delimiters: `()`, `(a, b)`, `[a, b]`, and `#[a, b]`. A broken collection
places one parsed element per line at two spaces and the closing delimiter at the owner's indentation. The formatter
does not invent a trailing separator; it preserves one only when the parsed grammar makes it part of the form.

`collections.records` uses `{ field := value, other := value }` when flat. Separator tokens are preserved: the formatter
neither inserts nor deletes a comma. With comma-bearing input, the broken form is:

```lean
{ field := value,
  other := value }
```

Every continuation is two spaces from `{`; source-column alignment is discarded. Layout-separated record syntax without
commas stays layout-separated. Record updates, typed records, and ellipses keep their parsed order and delegate every
value.

`collections.match` keeps `match discriminant with` together when possible. Arms begin with `|` at the match owner's
indentation. A fitting arm body follows `=>`; a broken body is indented two spaces. Multiple discriminants break only at
discriminant boundaries.

## Tactics and offside blocks

`blocks.tactic` permits `by exact term` or another single atomic tactic to stay flat when it fits and has no comment.
Multiple tactics, comments, focus, alternatives, or a broken child force:

```lean
by
  intro x
  · exact x
```

Bullets and case/focus bodies own their bodies' indentation. A focusing `·` always keeps its first tactic on its own row
— `· calc`, `· exact`, however long the block under it — because mathlib's cdot linter flags an isolated `·`; everything
past the first token breaks under the ordinary rules. The term-level `·` in `(· + ·)` is a different construct and is
untouched. Project-defined tactics break by the same rules as core ones, and do not make the surrounding declaration opt
out of formatting.

`blocks.do-where` writes `do` followed by two-space-indented items unless a single simple item fits on the `do` line.
`where` follows the declaration rule above. Match arms containing `by`, tactic alternatives, and a nested `Id.run do`
each start a new two-space indentation base. What belongs to a block comes from the parsed structure, never from the
columns the source used.

## Comments, literals, and suppression

`trivia.leading-trailing-dangling` puts a comment written above a construct immediately above it, at the same
indentation. A trailing comment follows the code by one space when it fits, and moves to the line above otherwise. A
comment with nothing after it — inside empty brackets, or at the end of a block — gets its own line there. The order of
comments and the blank lines around them do not change.

`trivia.literal-verbatim` never breaks the text of a literal, quotation, or comment. If formatting would change any of
those characters, lean-fmt refuses the file rather than writing it. Terminal tails are copied exactly. These rows may
exceed the line width on purpose.

`trivia.suppression` keeps rule-finding directives (`ignore`, `ignore-next`, `ignore-file`) independent from formatting.
Formatter suppression adds only:

```lean
-- lean-fmt: format-ignore-next
```

It suppresses the next whole declaration or command, copies it through unchanged, and resumes formatting afterward. It
cannot target part of an expression, the `module` and import header, a terminal tail, or the whole file. A directive
that is misspelled or has nothing to suppress is reported, not ignored. Suppression never makes invalid Lean acceptable
and is not a fallback for syntax lean-fmt cannot handle.

## Project-defined syntax

`registry.custom` lays out your own `syntax`, `notation`, and `macro` declarations using the layout Lean itself
registered for them, under the imports and options that parsed the file. Core syntax and project syntax go through the
same path — nothing keys layout on a syntax kind's name or on a table of preferred spellings — so a project-defined
tactic breaks like a built-in one. lean-fmt decides only what surrounds those constructs: the module structure,
comments, and the indentation constraints a result must satisfy before it is written. A token from project syntax that
cannot be broken may exceed the line width.
