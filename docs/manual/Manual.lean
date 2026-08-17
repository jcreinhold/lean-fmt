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
style and adds static-analysis rules for common source-level problems. With one style there is no
house dialect to agree on and nothing to argue about in review: layout follows from the structure
the compiler parsed and from one number, the line width.

Every Lean example in this manual is compiled as the page is built. An example that stopped being
valid Lean would break the build rather than sit here quietly being wrong.

# What lean-fmt does

Two commands cover almost everything.

`lean-fmt format` rewrites files to the canonical layout. `lean-fmt check` reports rule findings —
a duplicate import, a leftover debugging option, a line past the margin — and `check --fix`
applies the ones that are safe to apply. They are separate because they answer separate questions:
formatting is about where the bytes go, and a finding is a claim that something in the source is
wrong. Running one never implies the other.

# One style

lean-fmt does not have a style you configure. It has a style, and configuration chooses the line
width.

That is a deliberate trade. A formatter with options grows a per-project dialect, and every
dialect is a thing newcomers must learn and reviewers must police. With one style, the formatter's
output is the only correct answer, so nobody has to hold an opinion about it.

Layout is computed from the parsed structure of your code and the Lean syntax in scope. lean-fmt
does not read the alignment you used, does not keep a table of preferred spellings, and does not
try to preserve where you happened to break a line. Two files that parse the same come out the
same.

# What is never touched

Some things are yours, and formatting leaves them exactly as written:

- *Order.* Imports, modifiers, binders, fields, constructors, match arms, tactics, and `do` items
  stay in the order you wrote them. Source order carries meaning, so formatting never sorts.
- *Comment text.* A comment keeps its exact characters and stays attached to one construct.
  Reindenting moves a comment; it never edits inside one.
- *Literals.* Strings, character literals, and quotations are copied through untouched.
- *Line endings.* A file's CRLF or LF endings are restored when it is written back.

Formatting also never changes what a file means. A published result is validated against the exact
module setup before it replaces anything on disk.

# Reading the exit code

Every command uses the same three codes, which is what makes them usable in a script:

- `0` — clean.
- `1` — findings, or differences under a preview such as `format --check`.
- `2` — something failed. This is infrastructure trouble, not a verdict about your source.

The distinction between `1` and `2` matters in continuous integration. A `1` means the tool ran
and disagrees with your source; a `2` means it never got far enough to have an opinion. Treating
the two the same hides broken builds behind what look like style failures.

# Canonical layout
%%%
tag := "layout"
%%%

Two rules generate almost every layout decision.

*Structure decides the shape.* A construct's layout comes from how Lean parsed it, not from how it
was written. Nothing is ever aligned to a column that an earlier token happened to land on.

*Width decides where it breaks.* A construct stays on one line while it fits and takes its broken
form when it does not. Where the breaks fall depends on the width alone, never on where the input
was already broken.

The default width is 100 columns. The broken examples below are shown at a narrow width, 34, so
that the breaks are visible on this page instead of running off it.

## Declarations

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

The two indents do different jobs, which is why they differ. Four spaces marks a continuation of
the signature; two marks the body. If both used two, the last binder and the first line of the
body would sit in the same column.

Binders pack rather than splitting one per line as soon as anything overflows — the example above
breaks them apart only because each one is too wide to share a row.

## Operators

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

## Conditionals and matches

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

## Structures and records

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

When it breaks, every continuation is two spaces from the `{`, and the source's column alignment
is discarded. Separator tokens are preserved exactly: the formatter neither inserts nor deletes a
comma, so record syntax written without commas stays layout-separated.

## Lines that cannot be broken

Some rows have no break in them to take. An import, a long string literal, a URL in a comment, a
single identifier, or a token from project-defined syntax can all exceed the width, and lean-fmt
leaves them over the margin rather than mangling them.

Imports are the clearest case. The tokens of `public import Some.Very.Long.Module` cannot stack
vertically without changing what the line means, so the row overflows whole.

{ref "rules"}[`FMT016`] reports every row wider than the configured width. It is off by default,
because rows that cannot be broken are the common case and a rule that fires mostly on things you
cannot fix is a rule people learn to ignore.

# Rules and findings
%%%
tag := "rules"
%%%

A rule reports one specific problem in one place. `lean-fmt check` runs the active rules and
prints a finding per line:

```
LeanFmt/Scratch.lean:4:1: FMT003 duplicate import of Lean
```

The shape is the usual one — file, line, column, identifier, message — so an editor or a CI
annotation parses it without help.

## Asking what a rule is

`lean-fmt explain` describes any rule, including a worked example of what it flags:

```
FMT003  remove a duplicate import  [stable]
  category: imports   tier: source   fix: fixable   default: on

  The same module is imported twice in a header. The safe fix removes the later
  duplicate line. An exact repeat imports nothing new, so removing it preserves
  the module's environment and import order.

  Example
    - bad -
    import Lean
    import Lean
    - good -
    import Lean

  Select:    --select FMT003   |   --select imports
  Suppress:  -- lean-fmt: ignore[FMT003]
  Docs:      docs/rules/FMT003.md
```

`lean-fmt rules` lists the whole registry. Each rule carries four facts that decide when it runs
and what it can do:

- *Category* — `imports`, `security`, `redundancy`, `unused`, `layout`, and so on. A category is
  selectable as a unit, so `--select imports` turns on every import rule.
- *Stability* — `stable` or `preview`. A preview rule is still being tried out and stays off until
  you pass `--preview`.
- *Fix* — `fixable` or `report-only`. Only a fixable rule can be applied by `check --fix`.
- *Default* — whether it runs when you have not selected anything.

## Fixing

`lean-fmt check --fix` applies the fixable findings. It publishes at the original coordinates and
changes nothing else about the file — it is not a formatting pass, and running it does not
reformat the source around what it fixed.

Only fixes that are safe to apply are applied. A rule that can spot a problem but cannot repair it
without guessing stays `report-only` by design, because a fix that is right most of the time is
worse than no fix: it moves the work from writing the change to auditing it.

## Selecting rules

Selection is a filter over the findings, and it is the same on every command:

- `--select SELECTOR` sets the active rules. A selector is a rule identifier, a category, or
  `all`. Repeat the flag to name several.
- `--extend-select SELECTOR` adds to the active set instead of replacing it.
- `--ignore SELECTOR` switches rules off.
- `--preview` unlocks the preview rules.

The same choices live in configuration under `[lint]`, which is the better home for anything a
whole project should agree on. {ref "configuration"}[The configuration section] has the keys.

## Suppressing one finding

When a rule is right in general and wrong in one place, suppress it there rather than switching it
off everywhere:

```
-- lean-fmt: ignore[FMT003]
```

Naming the rule in the comment is what makes this readable later. A bare suppression tells the
next reader that something was silenced but not what, and it keeps silencing the rule after the
reason has gone away.

For a whole file or a directory, `per-file-ignores` in configuration says the same thing in one
place instead of once per occurrence.

## The catalog

Every rule has a generated reference page under
[`docs/rules/`](https://github.com/jcreinhold/lean-fmt/tree/main/docs/rules), one file per
identifier, with the rule's rationale and its examples. Those pages are generated from the
registry itself, so they cannot drift from the rules that actually run.

# Configuration
%%%
tag := "configuration"
%%%

Configuration is optional. With no config file at all, every `.lean` file in the project outside
`.lake` is checked with the default settings.

## Where the settings come from

Walking up from each source file toward the project root, the *closest* `lean-fmt.toml` — or
`.lean-fmt.toml` — governs that file.

Configs do not merge. A config in a subdirectory replaces its ancestors for that subtree rather
than layering on top of them. This is worth knowing before you add the second one: a nested config
that sets a single key silently drops every other setting its parent made, so a nested config
should be a complete statement of what that subtree wants.

Having both spellings of the name in one directory is an error rather than a precedence puzzle.
`--config PATH` skips discovery entirely and anchors at the project root.

## A worked file

```
extend = "../shared/lean-fmt.toml"
include = ["LeanLib/**/*.lean", "Main.lean"]
exclude = ["Generated/**"]
respect-gitignore = true

[format]
line-width = 100
declaration-body = "next-line"
reflow-comments = false

[lint]
select = ["all"]
ignore = ["FMT004"]
per-file-ignores = { "Legacy/*.lean" = ["FMT005"] }
```

`[format]` holds the settings that change the bytes on disk. `[lint]` holds rule selection. The
split is the same one the commands make: formatting and findings are separate questions, and a key
belongs to whichever one it can actually affect.

## The keys worth knowing first

`line-width` is the only number that changes layout, and it accepts 1 to 1000. Everything in
{ref "layout"}[the layout section] follows from it.

`declaration-body` chooses where a body goes relative to `:=`. The default, `"next-line"`, puts it
on its own line. `"same-line"` keeps it on the `:=` line whenever the joined line fits, and breaks
exactly like the default when it does not.

`reflow-comments` is off by default. Turned on, a standalone `--` comment block whose rows
overflow the margin is repacked to fit: the words keep their order, the lines do not. It leaves
alone anything where rewrapping would do more harm than good — trailing comments, doc comments,
block comments, list items, and blocks that already fit. A block with under twenty columns of room
is also left alone: confetti is worse than an overflow.

`pinned-comments` lists phrases that mark a comment as immovable. An inline comment containing one
is never moved and never has its line split, even when the code alone overflows. The default is
`["shake: keep"]`, because a tooling directive that drifts off the import it annotates has stopped
meaning anything. Setting the key replaces the default rather than adding to it; an empty list
turns pinning off.

`exclude` keeps paths out. `force-exclude` extends it to files named explicitly on the command
line, which is what you want when an editor or a pre-commit hook passes paths in directly.

## Comments do not change layout

This one is not configurable, and it surprises people often enough to be worth stating plainly.

Break decisions are computed from the code alone. A trailing comment never changes the layout of
the code it trails. If the code fits the width, the line stays whole and the comment overflows the
margin; if the code alone overflows, it breaks and the comment follows whatever it annotates.

The alternative is worse. Letting a comment's width push the code around would split
`public import X` across lines to make room for a note — and the note would usually overflow
anyway.

## Checking what applies

`lean-fmt config` prints the effective configuration for a file: which config file governs it and
what every setting resolved to. When a file is being formatted in a way you did not expect, that
is the first thing to run, because it answers whether the surprise is in the configuration or in
the layout.

The full key reference, including the `extend` chain's merge behaviour and the import-layout
settings the organizer uses, is in
[the configuration reference](https://github.com/jcreinhold/lean-fmt/blob/main/docs/configuration.md).

# Companion documents

Four documents cover ground that has no Lean in it, and so gain nothing from being checked at
build time:

- [Continuous integration](https://github.com/jcreinhold/lean-fmt/blob/main/docs/ci.md) — recipes
  for running lean-fmt in a project that depends on it.
- [Editor setup](https://github.com/jcreinhold/lean-fmt/blob/main/docs/editor-setup.md) — the
  language server, and stanzas for the common editors.
- [Canonical Lean style](https://github.com/jcreinhold/lean-fmt/blob/main/docs/style.md) — the
  normative list of layout decisions, each with an identifier that indexes a test. Read it when
  you need to know whether a behaviour is intended; read {ref "layout"}[the layout section] here
  when you want to see it.
- [Adding a rule](https://github.com/jcreinhold/lean-fmt/blob/main/docs/adding-a-rule.md) — for
  contributors extending the rule registry.
