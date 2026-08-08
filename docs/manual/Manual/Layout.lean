import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Canonical layout" =>
%%%
tag := "layout"
%%%

Two rules generate almost every decision in this chapter.

*Structure decides the shape.* A construct's layout comes from how Lean parsed it, not from how it
was written. Nothing is ever aligned to a column that an earlier token happened to land on.

*Width decides where it breaks.* A construct stays on one line while it fits and takes its broken
form when it does not. Where the breaks fall depends on the width alone, never on where the input
was already broken.

The default width is 100 columns. The broken examples below are shown at a narrow width, 34, so
that the breaks are visible on this page instead of running off it.

# Declarations

A declaration that fits stays flat, except for its body, which begins on its own line:

```lean -keep
def map (f : α → β) (xs : List α) : List β :=
  xs.map f
```

The body on the next line is the default. It is the layout Lean's own formatter produces, and it
keeps the eye on one column no matter how long the signature is. {ref "configuration"}[The
`declaration-body` key] moves it back onto the `:=` line if you would rather have it there.

When the signature does not fit, the binders go one per line, indented four spaces, and the result
type joins them. The body stays at two:

```lean -keep
def combineEverything
    (transform : Nat → Nat → Nat)
    (firstList : List Nat)
    (secondList : List Nat) :
    List Nat :=
  List.zipWith transform firstList
    secondList
```

The two indents are doing different jobs, which is why they differ. Four spaces marks a
continuation of the signature; two marks the body. If both used two, the last binder and the first
line of the body would sit in the same column and the eye would have nothing to separate them.

Binders pack rather than splitting one per line as soon as anything overflows — the previous
example breaks them apart only because each one is too wide to share a row.

# Operators

An operator chain reads its precedence and associativity from the syntax, never from a flat stream
of tokens. A chain that fits has one space around each operator. A broken chain keeps each operator
with its left operand and puts the next operand two spaces in:

```lean -keep
def total (a b c d e : Nat) :
    Nat :=
  a + b * c + d - e + a + b + c +
    d +
    e
```

Two spaces once, not once per link. Every break in one chain lands in the same column however many
operands it has, so a long chain does not walk off the right margin in a staircase. A
parenthesised sub-chain is a chain of its own and gets its own column.

# Conditionals and matches

A conditional that has to break puts each branch on its own line:

```lean -keep
def classify (n : Nat) : String :=
  if n == 0 then "zero"
  else
    if n < 10 then "small"
    else "large"
```

A match writes one arm per line with the pipes aligned to each other — to each other, not to
whatever column they occupied in the source:

```lean -keep
def describe (xs : List Nat) :
    String :=
  match xs with
  | [] => "empty"
  | [_] => "one"
  | _ => "many"
```

# Structures and records

Structure fields and inductive constructors go one per line, two spaces in:

```lean -keep
structure Point where
  x : Nat
  y : Nat
```

A record term hugs its braces while it fits:

```lean -keep
structure Point where
  x : Nat
  y : Nat

def origin : Point :=
  { x := 0, y := 0 }
```

When it breaks, every continuation is two spaces from the `{`, and the source's column alignment is
discarded. Separator tokens are preserved exactly: the formatter neither inserts nor deletes a
comma, so record syntax written without commas stays layout-separated.

# Lines that cannot be broken

Some rows have no break in them to take. An import, a long string literal, a URL in a comment, a
single identifier, or a token from project-defined syntax can all exceed the width, and lean-fmt
leaves them over the margin rather than mangling them.

Imports are the clearest case. The tokens of `public import Some.Very.Long.Module` cannot stack
vertically without changing what the line means, so the row overflows whole.

{ref "rules"}[`FMT016`] reports every row wider than the configured width. It is off by default,
because rows that cannot be broken are the common case and a rule that fires mostly on things you
cannot fix is a rule people learn to ignore.
