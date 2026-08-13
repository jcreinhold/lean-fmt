# lean-fmt

A formatter and linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`). lean-fmt re-parses every result and
compares it token-for-token against the original, refusing whatever does not match.

The linter adds rules on top: duplicate and redundant imports, unused variables, stray `set_option`s, bidirectional
control characters. Some carry fixes. `lean-fmt rules` lists them all.

## Install

First, check which Lean your project is on:

```sh
cat lean-toolchain
```

A lean-fmt build serves exactly one Lean toolchain — it loads your project's `.olean`s, and those load only in the
compiler that wrote them. Find your row:

| lean-fmt | Lean |
| --- | --- |
| 0.6.0, 0.7.0 | `v4.34.0-rc1` |
| 0.5.0 | `v4.33.0` |
| 0.4.0, 0.4.1 | `v4.33.0-rc2` |
| 0.2.0 – 0.3.1 | `v4.33.0-rc1` |

If your toolchain is not in that table, the binary will refuse your project and say so. Take the Lake dependency below
instead: it moves your project onto lean-fmt's toolchain rather than requiring you to match it.

Prebuilt binary (Linux and macOS, x86-64 and ARM) into `~/.local/bin`; `PREFIX` and `VERSION` override the prefix and
the release. Run it from your project directory and it checks the pairing above for you:

```sh
curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
```

From source (`PREFIX=/usr/local` to override, `DESTDIR` to stage, `make uninstall` to remove). With elan on `PATH`, this
installs the matching toolchain itself:

```sh
git clone https://github.com/jcreinhold/lean-fmt.git && cd lean-fmt && make install
```

`lean-fmt --version` reports both numbers, so it always answers which Lean a given binary is for.

There is no Windows build; on Windows take the Lake dependency.

## First run

From your project root:

```sh
lean-fmt format --check
```

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

To run lean-fmt from a Lake build, add the dependency. Lake builds it from source, which takes minutes once and is free
after that:

```lean
require «lean-fmt» from git
  "https://github.com/jcreinhold/lean-fmt" @ "v0.7.0"
```

```sh
lake update «lean-fmt»   # add it to the manifest, and move lean-toolchain to lean-fmt's
lake exe lean-fmt check
```

To make `lake lint` run it, add two lines to your package. A package has one lint driver, so if you already have one,
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
