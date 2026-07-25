# Canonical Lean style

`lean-fmt` has one style. Configuration chooses the line width (100 by default), not a family of
competing layouts. The formatter derives layout from parsed structure and the active Lean environment;
it does not preserve source alignment or maintain a database of preferred source spellings.

The executable policy rows live in `tests/style/matrix.json`. Their IDs appear below so an
implementation cannot silently omit or rename a decision.

## Global rules

- Indentation is two spaces per structural level. Continuations use the owning construct's next level;
  columns are never aligned to an earlier token.
- A group uses its flat form when it fits. Otherwise it uses the named broken form; width decisions do
  not depend on the input's line breaks.
- Ordinary breakable syntax must reflow at the configured width. A literal token, URL, identifier,
  exact comment payload, or registry-owned opaque atom may exceed it.
- Horizontal whitespace is one space where separation is required and absent next to hugged
  delimiters. There are no tabs or trailing spaces in formatter-owned output.
- Ordinary modules end in one newline. Bytes beginning at a terminal command such as `#exit` are a
  verbatim tail and are not normalized. CRLF/LF choice is restored only at publication.
- Source order is semantic. Imports, modifiers, binders, fields, constructors, match arms, tactics,
  `do` items, and custom syntax are never sorted by formatting.
- Comments keep exact payload bytes and one structural owner. Reindentation changes surrounding layout,
  never text inside a line, block, doc, directive, string, character, or quotation token.

## Headers and command shells

`header.imports` keeps `module` and ordered imports at the left margin, one import statement per line.
Import modifiers remain in source order. A comment-separated import group remains a group; formatting
never deduplicates, reorders, or organizes imports. There is one blank line after the header before the
first ordinary command.

`commands.namespace` writes `namespace Name`, `section Name`, their bodies, and matching `end Name` at
the command column. Namespace and section nesting changes names and scope, not command indentation;
this follows ordinary Lean and mathlib source layout. Top-level declaration-like commands are
separated by one blank line; cohesive setup commands (`open`, `export`, `universe`, `variable`, local
options) may remain adjacent. Empty vertical padding is not preserved: a run of consecutive blank
lines collapses to one.

`commands.modifiers` keeps doc comments on their own line, then attributes, visibility/safety modifiers,
and the declaration keyword in parsed order. Short attribute lists are flat (`@[simp, aesop safe]`);
long lists break after `@[` with one entry per line and a closing `]` at the attribute's indentation.
A top-level declaration's attribute list always occupies its own line above the declaration, even a
short one: `@[simp] theorem foo` comes back as `@[simp]` on one line and `theorem foo` on the next.
That is the grammar's layout, not a width decision — a declaration-level attribute list carries a
hard line after it upstream, and the inline variant of that construct exists and is used for
structure fields, `let rec`, and binders, so the split is deliberate rather than a defect.

`commands.syntax` keeps syntax, notation, macro, `open`, `export`, `universe`, `variable`, and
`set_option` shells on one line while they fit. Their nested term/parser/tactic children break under
their own category's layout. A long notation declaration breaks only at parsed child boundaries, never
by splitting a quoted atom.

## Declarations and members

`decl.signature` uses a flat declaration when it fits:

```lean
def map (f : α → β) (xs : List α) : List β := xs.map f
```

When it does not fit, binders remain in order on owner-relative continuation lines, the result type is
a composable group, and a broken value starts two spaces below `:=`:

```lean
def map
  (f : α → β)
  (xs : List α) :
  List β :=
  xs.map f
```

The same header model applies to `def`, `abbrev`, `opaque`, `theorem`, `lemma`, `example`, `instance`,
and shared declaration forms. Termination and decreasing clauses follow the body at declaration
indentation; `where` begins at declaration indentation and owns a two-space-indented declaration list.

`decl.members` writes structure/class fields and inductive constructors one per line at two spaces.
Constructor pipes align with each other, not with source columns. Field defaults and constructor types
use ordinary term groups. A short `deriving` group stays flat; a broken group has one class per line.

`decl.mutual` writes `mutual` and `end` at the owner's indentation and each member two spaces within it.
Blank lines separate full member declarations, not individual binders or constructors.

## Terms and operators

`terms.application` keeps a fitting application flat. A broken application keeps the function on the
first line and places arguments at a two-space hanging indent, one structural argument group per line.
Named arguments stay atomic with their value boundary. Projections hug their receiver and projection
name.

`terms.operator` reads precedence and association from syntax, never from a flat token stream. A flat
chain has one space around an infix operator. A broken chain leaves the operator with its left operand
and indents the following operand two spaces. Identifier operands are ordinary operands: `a+1`, `a+b`,
qualified names, and Unicode notation all participate in spacing and reflow.

`terms.lambda-let-if` keeps a small lambda or `let` flat. Broken lambda bodies are indented two spaces
after `=>`; sequential `let` bindings occupy their own lines. A broken conditional is:

```lean
if condition then
  yes
else
  no
```

Parentheses are introduced or retained only when precedence/parenthesizer structure requires them.

## Delimited forms, records, and matches

`collections.delimiters` hugs empty and flat delimiters: `()`, `(a, b)`, `[a, b]`, and `#[a, b]`.
A broken collection places one parsed element per line at two spaces and the closing delimiter at the
owner's indentation. The formatter does not invent a trailing separator; it preserves one only when
the parsed grammar makes it part of the form.

`collections.records` uses `{ field := value, other := value }` when flat. Separator tokens are
preserved: the formatter neither inserts nor deletes a comma. With comma-bearing input, the broken form
is:

```lean
{ field := value,
  other := value }
```

Every continuation is two spaces from `{`; source-column alignment is discarded. Layout-separated
record syntax without commas remains layout-separated. Record updates,
typed records, and ellipses keep their parsed order and delegate every value.

`collections.match` keeps `match discriminant with` together when possible. Arms begin with `|` at the
match owner's indentation. A fitting arm body follows `=>`; a broken body is indented two spaces.
Multiple discriminants break only at discriminant boundaries.

## Tactics and offside blocks

`blocks.tactic` permits `by exact term` or another single atomic tactic to remain flat when it fits and
has no comment. Multiple tactics, comments, focus, alternatives, or a broken child force:

```lean
by
  intro x
  · exact x
```

Bullets and case/focus bodies own their bodies' indentation. Project-defined tactics break under the
same live registry as core ones; they do not cause the enclosing declaration to become verbatim.

`blocks.do-where` writes `do` followed by two-space-indented items unless one simple item fits flat.
`where` uses the declaration rule above. Match arms containing `by`, tactic alternatives, and nested
`Id.run do` each establish a new two-space offside base. Membership is taken from the AST, never
recovered from source columns.

## Comments, literals, and suppression

`trivia.leading-trailing-dangling` writes a leading comment immediately before its owner at the owner's
indentation. A trailing line comment follows one space after code when it fits; otherwise it becomes a
leading comment for the same owner. Dangling comments occupy their delimiter/block slot on their own
line. Comment order and blank-line ownership are stable.

`trivia.literal-verbatim` treats literal, quotation, and comment payload bytes as unbreakable. If a
toolchain formatter proposes changing those token bytes, structural admission rejects the whole
candidate. Terminal tails are copied exactly. These are intentional over-width exceptions.

`trivia.suppression` keeps rule-finding directives (`ignore`, `ignore-next`, `ignore-file`) independent
from formatting. Formatter suppression adds only:

```lean
-- lean-fmt: format-ignore-next
```

It suppresses the next complete ordinary formatting unit, copies that unit's normalized bytes exactly,
and resumes canonical formatting afterward. It cannot target part of an expression, the module/import
header, a terminal tail, or the whole file. Unmatched/malformed directives are non-silent. Suppression
never makes invalid Lean acceptable and never acts as unsupported-syntax fallback.

## Open project syntax

`registry.custom` assigns layout to the live registered formatter under the environment and options
that parsed the file. That is not a rule for imported syntax alone: one adapter drives every command,
so project syntax and core syntax reach the same authority, and nothing keys layout on a kind name, a
quoted atom, or a canonical-rewrite table. Lean-fmt owns what surrounds those documents -- the module
stream, comments, and the alignment and offside constraints a candidate must satisfy before it is
admitted. A registry-owned unbreakable atom may exceed the width.
