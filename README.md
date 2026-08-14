# lean-fmt

A formatter and linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`). lean-fmt re-parses every result and
compares it token-for-token against the original, refusing whatever does not match.

The linter adds rules on top: duplicate and redundant imports, unused variables, stray `set_option`s, bidirectional
control characters. Some carry fixes. `lean-fmt rules` lists them all.

## Install

lean-fmt serves exactly one Lean toolchain — it loads your project's `.olean`s, and those load only in the compiler that
wrote them. So **the release tag is the toolchain**. Read yours:

```sh
cat lean-toolchain      # leanprover/lean4:v4.34.0-rc1
```

and require the tag of the same name:

```lean
require «lean-fmt» from git
  "https://github.com/jcreinhold/lean-fmt" @ "v4.34.0-rc1"
```

```sh
lake update «lean-fmt»
lake exe lean-fmt format --check
```

There is no compatibility table to consult and no version to choose. If the tag matches your `lean-toolchain`, the
pairing is right; every release asserts the two are equal, so a tag naming a toolchain it was not built against cannot
be published.

Lake builds lean-fmt from source: 70 modules, half a minute on a 12-core laptop, and free afterwards. It does not
disturb your own build either — adding the dependency to a fully built Mathlib leaves all 8,695 targets up to date,
because nothing in your project imports it.

For a `lean-fmt` on your `PATH` instead of `lake exe lean-fmt` (`PREFIX=/usr/local` to override, `DESTDIR` to stage,
`make uninstall` to remove). With elan on `PATH` this installs the matching toolchain itself:

```sh
git clone --branch v4.34.0-rc1 https://github.com/jcreinhold/lean-fmt.git && cd lean-fmt && make install
```

Windows is untested rather than unsupported. Nothing in lean-fmt is written against a Unix-only interface, but there is
no Windows CI leg and the test harness itself reads `ps`, so no suite has ever run there. If you try it, a report either
way is useful.

Releases through `v0.7.1` used semantic versions and a compatibility table; `v0.7.1` is the last of them and pairs with
Lean `v4.34.0-rc1`. Those tags stay where they are, and prebuilt binaries are no longer published.

## First run

From your project root:

```sh
lake exe lean-fmt format --check
```

Every command below is spelled `lean-fmt …` for brevity. Through the Lake dependency the spelling is `lake exe
lean-fmt …`; after `make install` the bare name works.

Nothing is written. It names the files that would change, then says what it did:

```
6 of 128 files would be reformatted.
```

Anything lean-fmt declined to touch gets its own line, and only when it happened:

```
2 files rejected: lean-fmt could not verify its own output.
1 file does not compile and was skipped.
```

Exit status is 0 when clean, 1 when there is drift or a finding, 2 on failure. `lean-fmt format --diff` shows the same
run as a patch, and `--statistics` adds the full counts on stderr for a script to read.

The first run over a project is the slow one — it elaborates what it must to know how to parse your files, then caches
that in `.lean-fmt-cache/`. Later runs over unchanged files skip it.

## Use

```sh
lean-fmt check          # report findings, write nothing (--fix applies rule fixes in place)
lean-fmt format         # write the canonical layout in place
lean-fmt format --check # preview formatting changes as a status
lean-fmt format --diff  # preview formatting changes as a patch
```

Each runs over the Lake project in the working directory; `--root PATH` points elsewhere, and named files narrow it.

`check` and the `format` previews never write. `check --fix` and `format` write a file in one atomic step, and only
after checking the whole result against the current source. `format --no-validate` is the one exception, and it applies
only to a module that already compiles: lean-fmt re-parses the result and compares it token-for-token against the
original, then writes, skipping the second render and full comparison that normally follow. A file that fails the
re-parse is still refused. Each skip is counted as `validation_bypassed` and its result is never cached, so a later
ordinary run checks it in full. Every non-writing form (`--check`, `--diff`, stdin, `check --fix`) rejects the flag.

Exit 0 clean, 1 findings or files that failed to analyze, 2 infrastructure failure. `--json` prints one JSON object;
`--output-format` also takes `concise|github|sarif|junit`, and `--statistics` writes totals to stderr. `--changed`,
`--changed-since REV`, and `--staged` narrow a run to what git says moved. `--workers N` sets parallelism — default
`LEAN_NUM_THREADS`, else the core count — and the report is byte-identical at any N.

Other commands: `organize` (canonical import headers), `explain` (one rule), `lsp`, `compiler` (plugin
setup/status/build), `config show PATH`, `clean`. `lean-fmt <command> --help` lists that command's options.

Runs cache results in `.lean-fmt-cache/`, so a warm run where nothing changed skips the Lean frontend. `--no-cache`
turns the cache off; `docs/configuration.md` says what invalidates an entry.

## Configure

Optional — with no config file, lean-fmt checks everything with defaults. To configure, add `.lean-fmt.toml`:

```toml
exclude = ["Generated/**"]

[format]
line-width = 100           # 1..1000

[lint]
select = ["all"]
ignore = ["FMT004"]
```

The config file **closest** to each source file governs it; configs do not merge. lean-fmt honors git ignore files, and
rejects unknown keys and rule codes. `lean-fmt config show PATH` prints a file's effective settings and where each came
from. `[format]` and `[lint]` take more keys than these; `docs/configuration.md` is the full reference.

## In another project

§"Install" covers the dependency itself. To make `lake lint` run it, add two lines to your package. A package has one lint driver, so if you already have one,
keep it and run `lake exe lean-fmt check` as its own step:

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

Guillemets are required in both halves — `lean-fmt` is not a legal Lean identifier.

lean-fmt reports files that do not compile as `broken`, so exclude any you keep on purpose (linter fixtures, draft
notes). An optional compiler plugin speeds up the syntax-dependent rules; findings are the same without it. Setup,
costs, and CI recipes: `docs/ci.md`.

## Editors

`lean-fmt lsp` serves a language server offering formatting, range formatting, code actions, and diagnostics, alongside
Lean's own. Setup for VS Code, Neovim, and Emacs: `docs/editor-setup.md`.

## Stability

Output will change before 1.0, and a Lean release can change it too, since lean-fmt renders through Lean's
pretty-printer. Pin a version, and land a reformat as its own commit.

What does not move is whether a file is safe. lean-fmt publishes a result only after re-parsing it and comparing it
token-for-token against the original; a file it cannot verify is left exactly as it was and reported as `rejected` or
`infrastructure-failure`, never written half-formatted. Over a 1,610-file Lean corpus: no result failed validation, and
2 files (0.12%) were refused before one was produced.

The line width is a target for breakable syntax, not a guarantee. A string literal, URL, long identifier, or comment
payload can exceed it because no break placement would shorten it. `FMT016` reports every row that does. It is off by
default:

```toml
[lint]
extend-select = ["FMT016"]
```

Prose inside comments is not rewrapped at all unless you turn on `reflow-comments` (`docs/configuration.md`).

## More

For using lean-fmt:

- [The manual](https://www.jcreinhold.com/lean-fmt/) — the layout, the rules, and configuration, worked through with
  compiled examples.
- `CHANGELOG.md` — what changed in each release, and what upgrading asks of you.
- `docs/style.md` — the canonical style, including `format-ignore-next` suppression.
- `docs/configuration.md` — every config key, selection gates, streaming and ranges, workers, and the cache.
- `docs/ci.md` — CI recipes, caching between runs, pinning and upgrading.
- `docs/maintenance.md` — what happens when Lean moves: the release contract, what is automated, what a person decides,
  and what to do if a release is late.
- `docs/editor-setup.md` — the language server, with stanzas for VS Code, Neovim, and Emacs.
- `docs/rules/` — one page per rule, generated from the registry.

For working on lean-fmt:

- `docs/adding-a-rule.md` — writing a lint rule.
- `docs/toolchain-upgrade.md` — checklist for a `lean-toolchain` bump.
- `docs/flaky-tests.md` — the ledger of intermittent CI failures, and the no-retry rule.
- `docs/upstream-defects.md` — toolchain defects with no open `leanprover/lean4` item, each with a
  toolchain-only reproduction.

## Develop

```sh
lake build
lake test              # unit tier plus non-slow suites
lake test -- --all     # everything
lake lint              # the formatter on itself
```
