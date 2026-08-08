import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Introduction" =>
%%%
tag := "introduction"
%%%

# What lean-fmt does

Two commands cover almost everything.

`lean-fmt format` rewrites files to the canonical layout. `lean-fmt check` reports rule findings —
a duplicate import, a leftover debugging option, a line past the margin — and `check --fix` applies
the ones that are safe to apply.

They are separate because they answer separate questions. Formatting is about where the bytes go;
a rule finding is a claim that something in the source is wrong. Running one never implies the
other.

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

The distinction between `1` and `2` matters in continuous integration. A `1` means the tool ran and
disagrees with your source; a `2` means it never got far enough to have an opinion, and treating
the two the same hides broken builds behind what look like style failures.

# Where the rest of the documentation lives

This manual covers the layout, the rules, and configuration. Four companion documents cover ground
that has no Lean in it, and so gain nothing from being a checked document:

- [Continuous integration](https://github.com/jcreinhold/lean-fmt/blob/main/docs/ci.md) — recipes
  for running lean-fmt in a project that depends on it.
- [Editor setup](https://github.com/jcreinhold/lean-fmt/blob/main/docs/editor-setup.md) — the
  language server, and stanzas for the common editors.
- [Canonical Lean style](https://github.com/jcreinhold/lean-fmt/blob/main/docs/style.md) — the
  normative list of layout decisions, each with an identifier that indexes a test. Read it when you
  need to know whether a behaviour is intended; read {ref "layout"}[the layout chapter] here when
  you want to see it.
- [Adding a rule](https://github.com/jcreinhold/lean-fmt/blob/main/docs/adding-a-rule.md) — for
  contributors extending the rule registry.
