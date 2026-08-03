# lean-fmt

A formatter and linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`). lean-fmt re-parses every result and
compares it token-for-token against the original, refusing whatever does not match.

The linter adds rules on top: duplicate and redundant imports, unused variables, stray `set_option`s, bidirectional
control characters. Some carry fixes. `lean-fmt rules` lists them all.

## Install

Prebuilt binary (Linux and macOS, x86-64 and ARM) into `~/.local/bin`; `PREFIX` and `VERSION` override the prefix and
the release:

```sh
curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
```

From source (`PREFIX=/usr/local` to override, `DESTDIR` to stage, `make uninstall` to remove):

```sh
git clone https://github.com/jcreinhold/lean-fmt.git && cd lean-fmt && make install
```

With elan on `PATH`, the first build installs the pinned toolchain. At runtime lean-fmt uses the *target* project's
toolchain. There is no Windows build; on Windows take the Lake dependency below.

## Use

```sh
lean-fmt check --root .    # report findings, write nothing
lean-fmt diff --root .     # preview formatting changes
lean-fmt format --root .   # write the canonical layout in place (--check previews instead)
lean-fmt fix --root .      # apply rule fixes in place, without reflowing layout
```

`check` and `diff` never write. `format` and `fix` publish a file atomically, and only after validating the whole
result against the current source.

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
  "https://github.com/jcreinhold/lean-fmt" @ "v0.2.3"
```

```sh
lake update «lean-fmt»   # add it to the manifest
lake exe lean-fmt check --root .
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

## More

- `docs/style.md` — the canonical style, including `format-ignore-next` suppression.
- `docs/configuration.md` — config discovery, selection gates, streaming and ranges, memory and workers, cache internals.
- `docs/adding-a-rule.md` — writing a lint rule.
- `docs/toolchain-upgrade.md` — maintainer checklist for toolchain bumps.

## Develop

```sh
lake build
lake test              # unit tier plus non-slow suites
lake test -- --all     # everything
lake lint              # the formatter on itself
```
