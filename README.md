# lean-fmt — Lean 4 formatter and linter

lean-fmt is a code formatter and static-analysis linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`). Every result is
re-parsed and compared token-for-token against the original; whatever does not match is refused.

The linter adds rules on top: duplicate and redundant imports, unused variables, stray
`set_option`s, bidirectional control characters. Some carry fixes. `lean-fmt rules` lists them all.

## Install

lean-fmt serves exactly one Lean toolchain: it loads your project's `.olean`s, and those load only
in the compiler that wrote them. So **the release tag is the toolchain**. Read yours:

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

If the tag matches your `lean-toolchain`, the pairing is right; every release asserts the two are
equal, so a tag naming a toolchain it was not built against cannot be published.

Lake builds lean-fmt from source: 70 modules, half a minute on a 12-core laptop, and free
afterwards. Your own build is not disturbed — adding the dependency to a fully built Mathlib
leaves all 8,695 targets up to date, because nothing in your project imports it.

For a `lean-fmt` on your `PATH` instead of `lake exe lean-fmt` (`PREFIX=/usr/local` to override,
`DESTDIR` to stage, `make uninstall` to remove). With elan on `PATH` this installs the matching
toolchain itself:

```sh
git clone --branch v4.34.0-rc1 https://github.com/jcreinhold/lean-fmt.git && cd lean-fmt && make install
```

Windows is untested rather than unsupported. Nothing in lean-fmt is written against a Unix-only
interface, but there is no Windows CI leg and the test harness itself reads `ps`, so no suite has
ever run there. A report either way is useful.

Releases through `v0.7.1` used semantic versions and a compatibility table; `v0.7.1` is the last
of them and pairs with Lean `v4.34.0-rc1`. Those tags stay where they are; prebuilt binaries are
no longer published.

## First run

From your project root:

```sh
lake exe lean-fmt format --check
```

(Every command below is spelled `lean-fmt …`. Through the Lake dependency the spelling is
`lake exe lean-fmt …`; after `make install` the bare name works.)

Nothing is written. It names the files that would change, then reports:

```
6 of 128 files would be reformatted.
```

Anything lean-fmt declined to touch gets its own line, and only when it happened:

```
2 files rejected: lean-fmt could not verify its own output.
1 file does not compile and was skipped.
```

Exit status is 0 when clean, 1 on drift or a finding, 2 on failure. `lean-fmt format --diff` shows
the same run as a patch; `--statistics` adds the full counts on stderr.

The first run over a project is the slow one: it elaborates what it must to know how to parse
your files, then caches that in `.lean-fmt-cache/`. Later runs over unchanged files skip it.

## Use

```sh
lean-fmt check          # report findings, write nothing (--fix applies rule fixes in place)
lean-fmt format         # write the canonical layout in place
lean-fmt format --check # preview formatting changes as a status
lean-fmt format --diff  # preview formatting changes as a patch
```

Each runs over the Lake project in the working directory; `--root PATH` points elsewhere, and
named files narrow it.

`check` and the `format` previews never write. `check --fix` and `format` write a file in one
atomic step, only after checking the whole result against the current source. `format
--no-validate` is the one exception, and only for a module that already compiles: the result is
re-parsed and compared token-for-token against the original, then written, skipping the second
render and full comparison. A file that fails the re-parse is still refused. Each skip is counted
as `validation_bypassed`, the result is never cached, and every non-writing form rejects the flag.

`--json` prints one JSON object; `--output-format` also takes `concise|github|sarif|junit`;
`--statistics` writes totals to stderr. `--changed`, `--changed-since REV`, and `--staged` narrow
a run to what git says moved. `--workers N` sets parallelism (default `LEAN_NUM_THREADS`, else the
core count); the report is byte-identical at any N.

Other commands: `organize` (canonical import headers), `explain` (one rule), `lsp`, `compiler`
(plugin setup/status/build), `config show PATH`, `clean`. `lean-fmt <command> --help` lists that
command's options.

## Configure

Optional. With no config file, lean-fmt checks everything with defaults. To configure, add
`.lean-fmt.toml`:

```toml
exclude = ["Generated/**"]

[format]
line-width = 100           # 1..1000

[lint]
select = ["all"]
ignore = ["FMT004"]
```

The config file **closest** to each source file governs it; configs do not merge. lean-fmt honors
git ignore files, and rejects unknown keys and rule codes. `lean-fmt config show PATH` prints a
file's effective settings and where each came from. `docs/configuration.md` is the full reference.

## In another project

To make `lake lint` run lean-fmt, add two lines to your package:

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

Guillemets are required in both halves — `lean-fmt` is not a legal Lean identifier. A package has
one lint driver, so if you already have one, keep it and run `lake exe lean-fmt check` as its own
step.

lean-fmt reports files that do not compile as `broken`, so exclude any you keep on purpose
(linter fixtures, draft notes). An optional compiler plugin speeds up the syntax-dependent rules;
findings are the same without it. Setup, costs, and CI recipes: `docs/ci.md`.

## Editors

`lean-fmt lsp` serves a language server offering formatting, range formatting, code actions, and
diagnostics, alongside Lean's own. Setup for VS Code, Neovim, and Emacs: `docs/editor-setup.md`.

## Stability

Output will change before 1.0, and a Lean release can change it too, since lean-fmt renders
through Lean's pretty-printer. Pin a version, and land a reformat as its own commit.

What does not move is whether a file is safe. A result is published only after re-parsing and a
token-for-token comparison against the original; a file that cannot be verified is left exactly as
it was and reported as `rejected` or `infrastructure-failure`, never written half-formatted. Over
a 1,610-file Lean corpus, no result failed validation and 2 files (0.12%) were refused before one
was produced.

The line width is a target for breakable syntax, not a guarantee. A string literal, URL, long
identifier, or comment payload can exceed it because no break placement would shorten it.
`FMT016` reports every row that does, and is off by default:

```toml
[lint]
extend-select = ["FMT016"]
```

Prose inside comments is not rewrapped unless you turn on `reflow-comments`
(`docs/configuration.md`).

## More

For using lean-fmt:

- [The manual](https://jcreinhold.github.io/lean-fmt/) — the layout, the rules, and configuration,
  worked through with compiled examples.
- `CHANGELOG.md` — what changed in each release, and what upgrading asks of you.
- `docs/style.md` — the canonical style, including `format-ignore-next` suppression.
- `docs/configuration.md` — every config key, selection gates, streaming and ranges, workers, and
  the cache.
- `docs/ci.md` — CI recipes, caching between runs, and what upgrading changes in CI.
- `docs/maintenance.md` — the release policy: one tag per toolchain, what is automated, and what
  to do if a release is late.
- `docs/editor-setup.md` — the language server, with stanzas for VS Code, Neovim, and Emacs.
- `docs/rules/` — one page per rule, generated from the registry.

For working on lean-fmt:

- `docs/adding-a-rule.md` — writing a lint rule.
- `docs/toolchain-upgrade.md` — checklist for a `lean-toolchain` bump.
- `docs/flaky-tests.md` — the ledger of intermittent CI failures, and the no-retry rule.
- `docs/upstream-defects/` — toolchain defects with no open `leanprover/lean4` item, one file each
  with a toolchain-only reproduction.

## Develop

```sh
lake build
lake test              # unit tier plus non-slow suites
lake test -- --all     # everything
lake lint              # the formatter on itself
```
