---
name: verso-docs
description: Create, build, revise, and maintain this repository's Verso documentation — Lean-authored docs with type-checked examples, living in their own Lake package under docs/. Use this skill whenever the user mentions Verso, a manual or handbook or book or docs site for lean-fmt, documentation written in Lean rather than markdown, checked or live code examples in docs, `#doc`, `manualMain`, `blogMain`, `lake exe docs`, or asks to add a chapter, restructure the manual, preview the rendered site, fix a docs build error, or move something out of docs/*.md into the manual — including when they only say "the manual" or "the docs site" without naming Verso.
---

# Verso documentation for lean-fmt

Verso is Lean's documentation authoring tool. You write prose in a markdown-like syntax inside `.lean` files, and the
Lean elaborator checks the code examples as it builds the document. A snippet that stops compiling breaks the docs build
instead of quietly becoming a lie.

This repository keeps Verso documentation in its own Lake package under `docs/`, separate from the `lean-fmt` package.
Everything below assumes that boundary; the reason it exists is the first thing to read.

## The dependency boundary, and why it is not negotiable by accident

The `lean-fmt` package has **zero dependencies** — `lake-manifest.json` lists no packages. That is load-bearing, not
incidental. `AGENTS.md` states that the result cache's identity includes "the ordered Lake environment — search-path
precedence and dependency build traces, so a `lake update` that moves any dependency invalidates everything." Adding a
dependency to the root `lakefile.lean` means every entry in every user's `.lean-fmt-cache` misses whenever that
dependency's pin moves.

So the Verso package requires Verso; the `lean-fmt` package requires nothing. Never add `verso` or `subverso` to the
root `lakefile.lean` to make a docs feature work. If a feature seems to need it, read `references/code-examples.md` —
there is almost always a way to get the same example without crossing the line, and the one case that genuinely cannot
is a decision for the user, not for you.

Two more facts about how the repository already treats `docs/`:

- `lean-fmt.toml`'s `exclude` list contains `docs/**`, so `lake lint` and a bare `lean-fmt check` never read Verso
  sources. This is convenient — Verso's `#doc` markup is not Lean the formatter can lay out — but it also means **no
  formatter or linter is watching these files**. Keep them tidy by hand.
- `docs/rules/*.md` is generated from the rule registry and gated by `lean-fmt docs --check` (the catalog suite asserts
  it). Never hand-edit those pages and never point Verso output at that directory.

## What belongs in Verso and what stays in markdown

The repository has two documentation systems on purpose, so the standing risk is that they drift into saying the same
thing differently. Prevent that by dividing them on capability, not on topic:

**Verso earns its place when a document needs Lean to check itself.** Style rules illustrated with before-and-after Lean
that must actually parse. Reference material where every mentioned name should be a hyperlink to its signature. Anything
with worked examples whose output is asserted rather than transcribed by hand.

**Markdown stays right for everything else.** `docs/ci.md`'s YAML recipes, `docs/editor-setup.md`'s editor stanzas,
`README.md`. These have no Lean in them; putting them through a Lean elaborator buys nothing and costs a build.

When a Verso document covers ground a markdown file also covers, do not restate it — link to it, and say in one line
what the other document is for. Two records that overlap will disagree eventually, and `AGENTS.md`'s ordering ("`docs/`
is the user-facing contract") gives neither one priority over the other.

## Setting up the package (once)

Run the scaffold script from the repository root. It derives the Verso revision from `lean-toolchain`, verifies that tag
exists upstream before writing anything, and refuses to overwrite an existing package:

```bash
.claude/skills/verso-docs/scripts/scaffold.sh docs/manual
```

Verso tags track Lean releases one-for-one — whatever version `lean-toolchain` names, Verso has a tag of that name. That
pairing is the single most common thing to get wrong, and it fails as a wall of elaboration errors rather than a clear
message, so the script derives it rather than letting you type it.

What the script writes, and why each piece is there:

| File | Purpose |
| --- | --- |
| `docs/manual/lakefile.toml` | Requires `verso` at the derived tag; declares the `Manual` library and the `docs` executable |
| `docs/manual/lean-toolchain` | Must match the root `lean-toolchain` byte for byte |
| `docs/manual/Main.lean` | The entry point: `manualMain (%doc Manual) (config := config)` |
| `docs/manual/Manual.lean` | The root document — its `#doc` becomes the front page, and it `{include}`s the chapters |
| `docs/manual/Manual/` | One module per chapter (optional; the current manual is a single page, so this directory does not exist — `Main.lean` sets `htmlDepth := 0`) |

The first `lake build` in that directory downloads and builds Verso, which takes minutes. It is cached afterward.

## The authoring loop

```bash
cd docs/manual
lake exe docs                                    # build; output lands in _out/html-multi/
python3 ../../.claude/skills/verso-docs/scripts/serve.py 8000 -d _out/html-multi
```

Verso's HTML does not work when opened as a `file://` URL — code hovers are deduplicated into a JSON file the page
fetches at runtime, and the browser blocks that fetch. Serve it. The bundled script sends no-cache headers, which
Python's plain `http.server` does not, so a rebuild actually shows up on reload.

`lake exe docs` accepts `--output DIR`, `--depth N`, `--with-tex`, and `--with-html-single`; the defaults in the
scaffolded `config` are usually what you want.

**Read the build errors literally.** Verso reports a mistyped role or an unbalanced directive at the source position in
the `.lean` file, the same as any Lean error. A confusing error almost always means the markup nested wrong, not that
Verso is broken.

## Publishing

`.github/workflows/pages.yml` builds the manual on every push to `main` and publishes `_out/html-multi` to
<https://jcreinhold.github.io/lean-fmt/>. The apex domain 301s there permanently and serves nothing itself; that URL is
the canonical one. Verso emits no search metadata (no meta description, no canonical link, no sitemap), so the workflow
runs `scripts/pages-search-metadata.py` between the build and the upload to inject them — the host is hardcoded there
because a canonical link cannot be relative. Pull requests build the manual and stop, so a stale example fails review
rather than the deploy. The workflow follows the template Verso ships as `gh-setup/verso-literate-pages.yml`, adapted
for the Manual genre.

Two things worth knowing before you touch it:

- **There is no base URL to configure.** Verso emits relative links under a `<base href>` — `./` at the site root,
  `./../` a level down — so the site works at a project subpath unchanged. If a link breaks on the deployed site but
  works locally, the cause is a bad `{ref}` tag, not a path prefix.
- **CI enforces the pins.** The workflow fails if `docs/manual/lean-toolchain` or the `verso` rev drifts from the root
  `lean-toolchain`. That is the same check `scripts/check-pins.sh` runs locally; run it before pushing rather than
  learning it from a red build.

Pages is already enabled on this repository with GitHub Actions as the source. On a fork or a new repository it is a
one-time step — Settings → Pages → Source → GitHub Actions, or
`gh api repos/OWNER/REPO/pages -X POST -f build_type=workflow`. Until it is set, the deploy step fails saying Pages is
not enabled.

## Adding a chapter

The manual is currently one page by choice: the content was too short to spread over four. If it grows enough to need
chapters again, raise `htmlDepth` in `Main.lean` and then:

1. Write `docs/manual/Manual/YourChapter.lean`. It opens with the imports, then one `#doc`.
2. Import it from `docs/manual/Manual.lean`.
3. Add `{include 1 Manual.YourChapter}` at the point in the root document where it belongs. The number is the heading
   depth to shift the included content by.
4. Build, and read the rendered page rather than trusting the source.

A chapter module looks like this:

```lean
import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Chapter title" =>
%%%
tag := "stable-tag-for-cross-references"
%%%

Prose here.
```

Give every chapter and every section you intend to link to a `tag`. Tags are what `{ref "tag"}[link text]` resolves
against, and they survive reorganization — a link by tag keeps working when the chapter moves, which a link by heading
number does not.

## House style

The prose rules that govern `docs/*.md` govern Verso documents too. They were applied across the whole tree in commit
`713e219`; match them rather than reinventing a voice.

- **Open with the audience.** Every document in `docs/` starts with a bolded line naming who it is for — "Audience:
  anyone running lean-fmt." or "Audience: lean-fmt contributors." A reader who is in the wrong document should learn
  that in one line. In Verso, bold that line as `*Audience: …*` — one asterisk, not markdown's two.
- **No internal jargon.** *Candidate*, *admission*, *syntax frontier*, *projection*, *tier*, *the stack*, *offside base*
  name things a reader outside this repository cannot look up. Say what the thing does. If a term genuinely needs to
  exist in the document, define it with `{deftech}_term_` and refer to it with `{tech}[term]` — Verso will link every
  use back to the definition, which is the honest way to introduce vocabulary.
- **No metacommentary.** Do not write about the document ("this section covers…", "each detail below was measured rather
  than assumed") or about features that were removed. The reader wants the content, not its provenance.
- **Omit needless words.** Orwell's rules. Prefer the short word, cut the qualifier, use the active voice.
- **Explain why, not just what.** A rule with its reason attached survives; a bare rule gets ignored the first time it
  is inconvenient.

## Revising an existing document

Read the rendered page and the source together. Verso's markup means the source does not read like the output — a
`:::paragraph` block or an `{include}` can make a page's structure very different from the file's structure.

When you change something a document cites — a rule's behaviour, a config key's default, a CLI flag — the docs build
will not catch it unless the citation is a checked example. That is exactly what checked examples are for:
`references/code-examples.md` explains how to turn a claim about lean-fmt's behaviour into something the build verifies.

Before handing off, run both:

```bash
cd docs/manual && lake exe docs                  # the docs build
.claude/skills/verso-docs/scripts/check-pins.sh  # toolchain and Verso pins still aligned
```

`check-pins.sh` catches the failure mode that bites after a toolchain bump: the root `lean-toolchain` moves,
`docs/manual/` does not, and the manual builds against a Lean that no longer matches the code it documents.
`docs/toolchain-upgrade.md` is the checklist for a bump; add the docs package to whatever you do there.

## References

Read these when the task calls for them rather than up front:

- `references/markup.md` — the markup language: roles, code blocks, directives, metadata blocks, cross-references, the
  index. Read this before writing more than a paragraph.
- `references/genres.md` — Manual versus Blog/Page: what each renders, which entry point each needs, and how to choose.
  Read this when starting a new document or when the user asks for something that is not a manual.
- `references/code-examples.md` — the three ways to get Lean code into a document, ordered by what each costs the
  repository. **Read this before adding any code example**, because the cheapest option that works is not the one the
  upstream templates show first, and the most capable one requires changing the root `lakefile.lean`.

Upstream, when the references do not answer it:

- Verso itself: <https://github.com/leanprover/verso> (pin the tag matching `lean-toolchain`)
- Starting templates: <https://github.com/leanprover/verso-templates> — `package-docs/` is the closest match to this
  setup
- The Verso manual is built from `UsersGuide/` in the Verso repository; reading that source is often faster than finding
  the rendered page
