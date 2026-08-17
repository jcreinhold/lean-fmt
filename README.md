# lean-fmt — Lean 4 formatter and linter

lean-fmt formats Lean 4 source into one canonical style and lints it for common problems: duplicate imports, unused
variables, stray `set_option`s, bidirectional control characters.

```lean
-- this
def foo(x:Nat):Nat:=x+1

-- becomes this
def foo (x : Nat) : Nat :=
  x + 1
```

Every result is re-parsed and compared token-for-token against the original. A file that does not match is refused,
never written half-formatted.

## Install

One release per Lean toolchain, tagged exactly as the toolchain. Read yours:

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
```

Lake builds lean-fmt from source against your toolchain. Nothing in your project imports it, so adding the dependency
never rebuilds your own modules.

To put `lean-fmt` on your `PATH` instead of calling it through `lake exe`:

```sh
git clone --branch v4.34.0-rc1 https://github.com/jcreinhold/lean-fmt.git && cd lean-fmt && make install
```

With elan on `PATH` this installs the matching toolchain itself. `PREFIX=/usr/local` overrides the install location,
`DESTDIR` stages, `make uninstall` removes.

Windows is untested; nothing in lean-fmt targets a Unix-only interface, and a report either way is useful.

## Use

```sh
lake exe lean-fmt format          # rewrite files to the canonical layout
lake exe lean-fmt format --check  # preview: which files would change
lake exe lean-fmt format --diff   # preview: the changes as a patch
lake exe lean-fmt check           # report lint findings
lake exe lean-fmt check --fix     # apply the safe fixes
```

Each runs over the Lake project in the working directory; `--root PATH` points elsewhere, named files narrow it, and
`--changed` / `--changed-since REV` / `--staged` follow git. A preview never writes; a write is atomic and validated
first.

Exit codes are the script interface: `0` clean, `1` findings or drift, `2` the run itself failed.

`lean-fmt rules` lists every rule, `lean-fmt explain FMT003` describes one, and `lean-fmt <command> --help` lists that
command's options. Further commands: `organize` (canonical import headers), `lsp`, `compiler` (the optional plugin),
`config show PATH`, `clean`.

To make `lake lint` run lean-fmt — which is how `leanprover/lean-action` picks it up in CI — add two lines to your
package:

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

Guillemets are required: `lean-fmt` is not a legal Lean identifier. lean-fmt reports files that do not compile as
`broken`, so exclude any you keep on purpose (linter fixtures, draft notes).

## Editors

`lean-fmt lsp` is a language server offering formatting, range formatting, code actions, and diagnostics. It runs
alongside Lean's own server, which offers no formatting. Setup for VS Code, Neovim, and Emacs: `docs/editor-setup.md`.

## Configure

Optional. With no config file, everything is checked with defaults. To configure, add `.lean-fmt.toml`:

```toml
exclude = ["Generated/**"]

[format]
line-width = 100

[lint]
select = ["all"]
ignore = ["FMT004"]
```

The config file closest to each source file governs it; configs do not merge. lean-fmt honors git ignore files and
rejects unknown keys and rule codes. `lean-fmt config show PATH` prints a file's effective settings and where each came
from. `docs/configuration.md` is the full reference.

## Stability

Output will change before 1.0, and a Lean release can change it too, since lean-fmt renders through Lean's
pretty-printer. Pin a tag and land a reformat as its own commit.

The line width is a target for breakable syntax, not a guarantee: a string literal, URL, or long identifier can exceed
it because no break placement would shorten it.

## Documentation

- [The manual](https://jcreinhold.github.io/lean-fmt/) — layout, rules, and configuration, worked through with compiled
  examples.
- `docs/style.md` — the canonical style, decision by decision.
- `docs/configuration.md` — every config key, selection, streaming, workers, the cache.
- `docs/ci.md` — CI recipes, caching, upgrading.
- `docs/editor-setup.md` — the language server.
- `docs/maintenance.md` — the release policy and what happens when Lean moves.
- `CHANGELOG.md` — what changed in each release.

For contributors: `docs/adding-a-rule.md`, `docs/toolchain-upgrade.md`, `docs/flaky-tests.md`, `docs/upstream-defects/`.

## Develop

```sh
lake build
lake test              # unit tier plus non-slow suites
lake test -- --all     # everything
lake lint              # the formatter on itself
```
