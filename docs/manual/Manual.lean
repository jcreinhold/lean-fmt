import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "lean-fmt — Lean 4 Formatter and Linter" =>
%%%
tag := "top"
shortTitle := "lean-fmt"
%%%

*Audience: anyone running lean-fmt.*

lean-fmt is a code formatter and linter for Lean 4. It formats Lean source into one canonical
style and adds static-analysis rules for common source-level problems.

Every Lean example in this manual is compiled as the page is built. An example that stopped being
valid Lean would break the build rather than sit here quietly being wrong.

# What lean-fmt does

`lean-fmt format` rewrites files to the canonical layout. `lean-fmt check` reports rule findings —
a duplicate import, a leftover debugging option, a line past the margin — and `check --fix`
applies the ones that are safe to apply. Formatting decides where the bytes go; a finding says
something in the source is wrong. Running one never implies the other.

# One style, a few switches

lean-fmt has one style. There is no indent width to pick and no brace dialect to argue about in
review: layout follows from the structure the compiler parsed and one number, the line width.

A few switches exist for the boundary decisions Lean itself leaves open — where a declaration's
body goes relative to `:=`, how an empty structure instance is spelled, whether a trailing comma
forces a break. They are listed under {ref "configuration"}[Configuration]. Everything else is
fixed: two files that parse the same come out the same.

# What formatting never changes

- *Meaning.* A result is validated against the exact module setup before anything is written.
- *Order.* Imports, binders, fields, match arms, and tactics stay in the order you wrote them.
- *Text.* Comments, strings, and quotations keep their exact characters.
- *Line endings.* A file's CRLF or LF is restored on write.

# Exit codes

Every command uses the same three codes: `0` clean, `1` findings or preview differences, `2` the
run itself failed. The 1/2 distinction matters in CI: a `1` is the tool disagreeing with your
source, a `2` is the tool never having run properly. Treating them the same hides broken builds
behind what look like style failures.

# Canonical layout
%%%
tag := "layout"
%%%

Two rules generate almost every decision. *Structure decides the shape*: layout comes from how
Lean parsed the code, and nothing aligns to a column an earlier token happened to land on. *Width
decides where it breaks*: a construct stays on one line while it fits, and where the breaks fall
depends on the width alone, never on where the input was broken.

The default width is 100. The broken examples below are shown at width 34 so the breaks are
visible on the page.

## Declarations

A declaration that fits stays flat, except its body, which begins on its own line:

```lean -keep
def map (f : α → β) (xs : List α) : List β :=
  xs.map f
```

The next-line body is the layout Lean's own formatter produces, and it keeps the body in one
column however long the signature is. {ref "configuration"}[The `declaration-body` key] moves it
back onto the `:=` line.

When the signature does not fit, binders continue at four spaces and the body stays at two:

```lean -keep
def combineEverything
    (transform : Nat → Nat → Nat)
    (firstList : List Nat)
    (secondList : List Nat) :
    List Nat :=
  List.zipWith transform firstList
    secondList
```

Four spaces marks a continuation of the signature; two marks the body. Binders pack onto shared
rows while they fit — they split one per line only when each is too wide to share.

## Operators

A chain that fits has one space around each operator. A broken chain keeps the operator with its
left operand and indents the next operand two spaces — once, not once per link, so a long chain
does not staircase off the margin:

```lean -keep
def total (a b c d e : Nat) :
    Nat :=
  a + b * c + d - e + a + b + c +
    d +
    e
```

Precedence and associativity come from the syntax, never from a flat token stream. A
parenthesised sub-chain is a chain of its own and gets its own column.

## Conditionals and matches

A broken conditional puts each branch on its own line; a match writes one arm per line, pipes
aligned to each other:

```lean -keep
def classify (n : Nat) : String :=
  if n == 0 then "zero"
  else
    if n < 10 then "small"
    else "large"

def describe (xs : List Nat) :
    String :=
  match xs with
  | [] => "empty"
  | [_] => "one"
  | _ => "many"
```

## Structures and records

Fields and constructors go one per line, two spaces in. A record term hugs its braces while it
fits:

```lean -keep
structure Point where
  x : Nat
  y : Nat

def origin : Point :=
  { x := 0, y := 0 }
```

When it breaks, every continuation is two spaces from the `{`. Separators are preserved exactly —
the formatter never inserts or deletes a comma, so comma-free record syntax stays
layout-separated.

## Lines that cannot be broken

An import, a long string literal, a URL in a comment, or a token from project-defined syntax may
have no break to take. lean-fmt leaves such rows over the margin rather than mangling them.
{ref "rules"}[`FMT016`] reports every row wider than the configured width; it is off by default
because the unbreakable rows are the common case.

# Rules and findings
%%%
tag := "rules"
%%%

A rule reports one specific problem in one place:

```
LeanFmt/Scratch.lean:4:1: FMT003 duplicate import of Lean
```

`lean-fmt rules` lists the registry; `lean-fmt explain FMT003` describes one rule with a worked
example. Each rule carries four facts: a *category* (selectable as a unit, so `--select imports`
turns on every import rule), a *stability* (`stable`, or `preview` — off until `--preview`), a
*fix* (`fixable` or `report-only`), and whether it is on by *default*.

`check --fix` applies only fixes that are safe to apply. A rule that can spot a problem but cannot
repair it without guessing stays report-only by design: a fix that is right most of the time moves
the work from writing the change to auditing it.

Selection is the same on every command: `--select` sets the active rules, `--extend-select` adds,
`--ignore` switches off. The same choices live under `[lint]` in configuration. To silence one
occurrence rather than a rule, suppress it in place with `-- lean-fmt: ignore[FMT003]` — naming
the rule, so the next reader knows what was silenced.

Every rule has a generated reference page under
[`docs/rules/`](https://github.com/jcreinhold/lean-fmt/tree/main/docs/rules), generated from the
registry itself, so the pages cannot drift from the rules that run.

# Configuration
%%%
tag := "configuration"
%%%

Configuration is optional: with no file at all, every `.lean` file outside `.lake` is checked with
defaults. When files exist, the *closest* `lean-fmt.toml` (or `.lean-fmt.toml`) governs each
source file. Configs do not merge — a nested config replaces its ancestors, so write a nested one
as a complete statement of what that subtree wants. Both spellings in one directory is an error;
`--config PATH` skips discovery.

```
extend = "../shared/lean-fmt.toml"
exclude = ["Generated/**"]

[format]
line-width = 100
declaration-body = "next-line"

[lint]
select = ["all"]
ignore = ["FMT004"]
```

`[format]` holds the settings that change the bytes on disk; `[lint]` holds rule selection.

The keys worth knowing first:

- `line-width` (1–1000) is the only number that changes layout.
- `declaration-body = "same-line"` keeps a fitting body on the `:=` line.
- `reflow-comments = true` rewraps overflowing `--` comment blocks, preserving the words and not
  the lines. Off by default.
- `pinned-comments` lists phrases marking a comment as immovable. The default is
  `["shake: keep"]`; setting the key replaces it.
- `force-exclude = true` extends `exclude` to files named explicitly on the command line — what
  you want when an editor or pre-commit hook passes paths in.

One policy is not configurable: comments never change layout. Break decisions are computed from
the code alone, so a trailing comment overflows the margin rather than pushing the code around.
The alternative would split `public import X` to make room for a note — and the note would
usually overflow anyway.

`lean-fmt config show PATH` prints a file's effective settings and where each came from; run it
first when a file formats in a way you did not expect. The full key reference is in
[docs/configuration.md](https://github.com/jcreinhold/lean-fmt/blob/main/docs/configuration.md).

# Companion documents

- [Continuous integration](https://github.com/jcreinhold/lean-fmt/blob/main/docs/ci.md) — recipes,
  caching, and upgrading in CI.
- [Editor setup](https://github.com/jcreinhold/lean-fmt/blob/main/docs/editor-setup.md) — the
  language server, with stanzas for VS Code, Neovim, and Emacs.
- [Canonical Lean style](https://github.com/jcreinhold/lean-fmt/blob/main/docs/style.md) — the
  normative list of layout decisions, each with an identifier that indexes a test. Read it to
  learn whether a behaviour is intended; read {ref "layout"}[the layout section] here to see it.
- [Adding a rule](https://github.com/jcreinhold/lean-fmt/blob/main/docs/adding-a-rule.md) — for
  contributors extending the rule registry.
