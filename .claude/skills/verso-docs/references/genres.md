# Genres: Manual, Page, and Post

A Verso genre decides what a document *is* — what markup it accepts, what its metadata means, and
what the renderer produces. Two matter here.

## Contents

- [Choosing](#choosing)
- [Manual](#manual)
- [Blog: Page and Post](#blog)
- [Running both](#both)

<a id="choosing"></a>
## Choosing

**Manual** for anything with sections that need numbering, cross-referencing, or an index — a
reference work read by lookup rather than front to back. This is the default for lean-fmt, because
the material that benefits most from Verso (canonical style, the rule catalog, configuration) is
reference material.

**Page and Post** for a site: standalone pages plus dated entries with a navigation structure. Reach
for this when the user asks for a landing page, a release-notes stream, or anything with a front
page and a menu rather than a table of contents.

If the user asks for "documentation" without qualification, they mean Manual.

<a id="manual"></a>
## Manual

**Library:** `VersoManual`. **Opens:** `open Verso.Genre Manual`, plus
`open Verso.Genre.Manual.InlineLean` for code blocks.

Entry point:

```lean
import VersoManual
import Manual

open Verso.Genre Manual

def config : RenderConfig where
  emitTeX := false
  emitHtmlSingle := .no
  emitHtmlMulti := .immediately
  htmlDepth := 2
  sourceLink := some "https://github.com/jcreinhold/lean-fmt"
  issueLink := some "https://github.com/jcreinhold/lean-fmt/issues"

def main := manualMain (%doc Manual) (config := config)
```

`%doc Manual` names the module whose `#doc` is the root document. `RenderConfig` extends `Config`,
which extends `HtmlConfig`, `TeXConfig`, and `OutputConfig` — so every field below is settable in
one record.

Fields worth knowing:

| Field | Default | Effect |
| --- | --- | --- |
| `destination` | `"_out"` | Output directory |
| `emitHtmlMulti` | `.immediately` | One page per section |
| `emitHtmlSingle` | `.no` | Everything on one page |
| `emitTeX` | `false` | LaTeX output, for a PDF |
| `htmlDepth` | `2` | How deep before sections stop getting their own page |
| `sourceLink`, `issueLink` | `none` | URLs in the page chrome |
| `logo`, `logoLink` | `none` | Site logo |
| `sectionTocDepth`, `rootTocDepth` | `some 1` | Depth of the local table of contents |
| `draft` | `false` | Include `{draft}` content |

The executable also takes flags, which override the config: `--output DIR`, `--depth N`,
`--with-tex` / `--without-tex`, `--with-html-single`, and the `--delay-html-*` / `--resume-html-*`
pair for splitting a build across two invocations (Verso's own manual uses that to interleave a
LaTeX run).

**Manual gives you:** numbered parts and sections, `{ref}` cross-references by tag, permalinks, an
index via `{theIndex}`, margin notes, citations, and a search box.

<a id="blog"></a>
## Blog: Page and Post

**Library:** `VersoBlog`. **Opens:** `open Verso Genre Blog`.

Two document kinds share the genre. A `Page` is standalone; a `Post` carries a date and an author
and appears in a chronological listing.

```lean
import VersoBlog
open Verso Genre Blog

#doc (Page) "Title" =>

Prose.
```

```lean
import VersoBlog
open Verso Genre Blog

#doc (Post) "Title" =>
%%%
authors := ["Name"]
date := {year := 2026, month := 8, day := 7}
%%%

Prose.
```

The entry point declares the site's shape — the URL structure is written out directly:

```lean
import VersoBlog
import Blog

open Verso Genre Blog Site Syntax

def blog : Site := site Blog.FrontPage /
  "about" Blog.About
  "posts" Blog.Posts with
    Blog.Posts.FirstPost

def main := blogMain .default blog
```

`site Root / "path" Module` mounts a page at a URL. `Module with Post₁ Post₂` attaches posts to a
listing page.

**Blog gives you:** a front page, a navigation menu, dated post listings, and per-post metadata. It
does *not* give you numbered sections, an index, or the manual's cross-reference machinery.

<a id="both"></a>
## Running both

Nothing stops a repository from having a manual package and a site package side by side, each with
its own `lakefile.toml` and executable. Do it only if the user asks for both — two documentation
builds is two things to keep pinned, and the maintenance falls on whoever inherits it.

If both exist, the manual is the reference and the site links to it. Do not let the site restate
what the manual says; the same drift argument that separates Verso from `docs/*.md` applies here.
