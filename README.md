# lean-fmt

A formatter and linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`); the line width is the only setting.
Before any output is reported or written, the result is re-parsed and checked token-for-token against the original —
anything that fails is refused, never shipped. The linter adds rules on top (duplicate and redundant imports, unused
variables, stray `set_option`s, bidirectional control characters), some with automatic fixes. `lean-fmt rules` lists
them.

## Installation

**Prebuilt binary** (Linux and macOS, x86-64 and ARM), into `~/.local/bin`:

```sh
curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
```

`PREFIX` and `VERSION` override the install prefix and the release. No Windows build; on Windows use the Lake dependency
below.

**From source** (`PREFIX=/usr/local` to override, `DESTDIR` to stage):

```sh
git clone https://github.com/jcreinhold/lean-fmt.git
cd lean-fmt
make install
```

With elan on `PATH`, the first build installs the pinned toolchain. At runtime `lean-fmt` uses the *target* project's
Lean toolchain. `make uninstall` removes what `make install` placed.

## Quick start

```sh
lean-fmt check --root .     # report findings, write nothing
lean-fmt fix --root .       # rewrite files in place, atomically
lean-fmt diff --root .      # preview formatting changes
lean-fmt format --root .    # format files in place, atomically
```

`check`, `format`, and `diff` never write files; `fix` is the only writer. Exit `0` clean, `1` findings, `2` failure.
`--json` prints one JSON object on stdout; statistics go to stderr.

Other commands: `format` (print formatted source), `rules`, `lsp` (language server), `compiler setup`/`status` (plugin),
`clean` (remove cache). `lean-fmt <command> --help` lists every flag.

Batch runs show a tqdm-style progress line on stderr when it is a terminal; pipes and `--json` never see it.

Results are cached in `.lean-fmt-cache/`; a warm run where nothing changed skips the Lean frontend entirely.
`--no-cache` disables it. `--workers N` parallelizes cold runs over many files; the report is identical at any N. It
defaults to `LEAN_NUM_THREADS`, else the machine's core count — what Lake uses for its own build.

## Configuration

Optional; without a config file everything is checked with defaults. To configure, add `.lean-fmt.toml`:

```toml
exclude = ["Generated/**"]

[format]
line-width = 100           # the only style setting, 1..1000

[lint]
select = ["all"]
ignore = ["FMT004"]
```

The config file **closest** to each source file governs it; configs do not merge. Git ignore files are honored. Unknown
keys and rule codes are errors. `lean-fmt config show PATH` prints the effective settings for a file and where each came
from. Full reference: `docs/configuration.md`.

## Using lean-fmt in another project

To run lean-fmt as part of a Lake build, add the dependency (built from source; the first run takes minutes, then Lake's
cache makes it free):

```lean
require «lean-fmt» from git
  "https://github.com/jcreinhold/lean-fmt" @ "v0.1.8"
```

```sh
lake update «lean-fmt»   # add it to the manifest
lake exe lean-fmt check --root .
```

If your project keeps intentionally non-compiling files (linter fixtures, draft notes), lean-fmt reports them `broken`;
exclude them in `.lean-fmt.toml` (`docs/configuration.md`).

To make `lake lint` run it, two lines in your package (a package has one lint driver; if you already have one, keep it
and run `lake exe lean-fmt check` as a separate step instead):

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

(Guillemets required in both halves — `lean-fmt` is not a legal Lean identifier.)

An optional compiler plugin speeds up the syntax-dependent rules; findings are identical without it. Setup, costs, and
CI recipes: `docs/ci.md`.

## Editors

`lean-fmt lsp` is a language server offering formatting, range formatting, code actions, and diagnostics, alongside
Lean's own server. Setup for VS Code, Neovim, and Emacs: `docs/editor-setup.md`.

## More

- `docs/style.md` — the canonical style, including `format-ignore-next` suppression.
- `docs/adding-a-rule.md` — writing a lint rule.
- `docs/toolchain-upgrade.md` — maintainer checklist for toolchain bumps.
- `docs/configuration.md` — config discovery, selection gates, streaming and ranges, memory and workers, cache
  internals.

## Developing

```sh
lake build
lake test              # unit tier plus non-slow suites
lake test -- --all     # everything
lake lint              # the formatter on itself
```
