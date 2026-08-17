# Verso markup

Verso's markup looks like markdown and is not markdown. The differences that actually bite are listed first; the rest is
a reference to skim when you need a construct.

## Contents

- [Differences from markdown](#differences)
- [Document structure](#structure)
- [Metadata blocks](#metadata)
- [Inline roles](#roles)
- [Block directives](#directives)
- [Code blocks](#code)
- [Cross-references](#refs)
- [The index](#index)
- [Citations](#citations)

<a id="differences"></a>
## Differences from markdown

**Headings are relative, not absolute.** A `#` inside a `#doc` starts a section within that document, and
`{include N Module}` shifts an included document's headings down by `N`. So a chapter written with `#` headings renders
as a subsection when included at depth 1. Do not compensate by hand — set the include depth.

**Bold is `*one asterisk*`, emphasis is `_underscores_`.** This is the reverse of markdown's convention, and writing
`**bold**` out of habit gets you a linter warning — `Unnecessary '*'` — not bolder text.

**Roles and directives are the extension points.** Anything markdown cannot express is either an inline role —
`` {name}`arg` `` — or a block directive — `:::name` … `:::`. There is no raw HTML escape hatch, which is deliberate:
the same document has to render to LaTeX.

**Code blocks are typed.** ` ```lean ` is not "a code block that happens to say lean" — it names an expander that
elaborates the contents. An unrecognized name is an error, not an inert block. Use ` ``` ` with no name for code that
should be shown verbatim without checking.

**Line breaks inside a paragraph are insignificant**, as in markdown. A blank line starts a new paragraph. Use
`:::paragraph` when several blocks are logically one paragraph and should render tightly.

<a id="structure"></a>
## Document structure

```lean
import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Document title" =>
%%%
tag := "some-tag"
%%%

Opening prose.

# First section

More prose.

## A subsection

{include 1 Manual.OtherChapter}
```

One `#doc` per module. The genre in parentheses (`Manual`, `Page`, `Post`) decides which markup is available — see
`genres.md`.

<a id="metadata"></a>
## Metadata blocks

A `%%%` block immediately after a title or heading sets that part's metadata:

```
%%%
tag := "cross-reference-tag"
number := false
htmlSplit := .never
shortTitle := "Short"
authors := ["Name"]
%%%
```

| Field | Effect |
| --- | --- |
| `tag` | Stable name for `{ref}`; survives reorganization |
| `number` | `false` suppresses section numbering (use for an index or appendix) |
| `htmlSplit` | `.never` keeps a section on its parent's page instead of getting its own |
| `shortTitle` | Title used in navigation when the real one is long |
| `authors`, `date` | Blog/Post metadata |

<a id="roles"></a>
## Inline roles

Spelled `` {role}`code argument` `` or `{role}[prose argument]`, depending on the role.

**Code and names**

| Role | Use |
| --- | --- |
| `` {lean}`expr` `` | Elaborate and highlight an expression inline |
| `` {leanTerm}`term` `` | Same, for a term |
| `` {name}`Foo.bar` `` | Link a name to its definition |
| `` {lit}`text` `` | Literal text, not elaborated |
| `` {option}`opt.name` `` | Reference a Lean option |
| `` {inst}`Inst` `` | An instance |
| `` {tactic}`tac` ``, `` {conv}`c` `` | A tactic or conv step |

**Prose**

| Role | Use |
| --- | --- |
| `{deftech}_term_` | Define a technical term |
| `{tech}[term]` | Refer to one; links back to the definition |
| `{ref "tag"}[link text]` | Cross-reference a tagged section |
| `{margin}[note]` | A marginal note, used like a footnote |
| `{index}[entry]` | Add an index entry |
| `{draft}[text]` | Mark text as draft; visible only in draft builds |

<a id="directives"></a>
## Block directives

```
:::paragraph
Several blocks that are logically one paragraph.

Rendered tightly together.
:::
```

| Directive | Use |
| --- | --- |
| `:::paragraph` | Group blocks as one logical paragraph |
| `:::table` | A table, with rows as nested lists |
| `:::row` | A row within a table |
| `:::leanSection` | Scope Lean `open`/`variable` commands to a region of the document |
| `:::progress` | Track completion state while drafting |

<a id="code"></a>
## Code blocks

Named by the expander that handles them. `code-examples.md` covers which to reach for; this is the list.

| Block | Contents |
| --- | --- |
| ` ```lean ` | A Lean command, elaborated in the document's environment |
| ` ```leanTerm ` | A Lean term |
| ` ```leanOutput NAME ` | The message produced by the block declared `(name := NAME)`; must match |
| ` ```signature ` | A declaration's signature, read from the environment |
| ` ```syntaxError ` | Source expected to fail parsing, with its error |
| ` ```module `, ` ```anchor ` | Code from an external project (tier 3 — see `code-examples.md`) |
| ` ```moduleInfo `, ` ```anchorInfo ` | That code's output |
| ` ```exampleFile `, ` ```inputFile `, ` ```outputFile ` | File contents |
| ` ```stdin `, ` ```stdout `, ` ```stderr `, ` ```ioLean ` | A program's input and output |
| ` ```imports ` | A module's import block |
| ` ``` ` (unnamed) | Verbatim, unchecked |

Most accept keyword arguments in parentheses: ` ```lean (name := ex1) `, ` ```anchor (module := M) `.

To show markup itself without it being interpreted, fence with four backticks and put the three-backtick block inside.

<a id="refs"></a>
## Cross-references

Tag the target in its metadata block, then link to it:

```
# Configuration
%%%
tag := "configuration"
%%%

...

See {ref "configuration"}[the configuration section].
```

Tags are the stable identity. A tagged section also gets a permalink in the rendered HTML, so a reader can link to it
even after the document is reorganized. Give a tag to anything you expect to link to more than once.

<a id="index"></a>
## The index

Mark entries in the prose with `{index}[term]`, sub-entries with `{index (subterm := "sub")}[term]`, and cross-entries
with `{see "other"}[term]` and `{seeAlso "other"}[term]`.

Then place the index itself, usually as an unnumbered final section:

```
# Index
%%%
number := false
tag := "index"
%%%

{theIndex}
```

<a id="citations"></a>
## Citations

Define citable references as values in one module — the role a `.bib` file plays in LaTeX — then cite them:

| Role | Renders |
| --- | --- |
| `{citet ref}[]` | Textual: "Author (2024) showed…" |
| `{citep ref}[]` | Parenthetical: "…as shown (Author 2024)" |
| `{citehere ref}[]` | Inline, not as a margin note; use inside a margin note |

Rarely needed for tool documentation. Useful if a document justifies a design against published work.
