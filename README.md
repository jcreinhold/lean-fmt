# lean-fmt

A formatter and linter for Lean 4.

The formatter rewrites Lean source into one canonical style (`docs/style.md`), with the line width as the only setting. It never changes what your code means: before any output is reported or written, the reformatted source is re-parsed and checked token-for-token against the original, and anything that fails that check is refused rather than shipped.

The linter adds rules on top — duplicate and redundant imports, unused variables, stray `set_option`s, formatting hazards like bidirectional control characters — some with automatic fixes. Fifteen rules ship today; `lean-fmt rules` lists them.

It runs three ways:

- **CLI** — check or rewrite files in a project, with a result cache that makes repeat runs fast.
- **Language server** — format-on-type, range formatting, and diagnostics in VS Code, Neovim, and Emacs (`docs/editor-setup.md`).
- **Compiler plugin** — an optional Lake plugin that speeds up lint rules by caching parse artifacts in your `.olean` files.

## Installation

**Prebuilt binary** (Linux and macOS, x86-64 and ARM), into `~/.local/bin`:

```sh
curl -sSfL https://raw.githubusercontent.com/jcreinhold/lean-fmt/main/install.sh | sh
```

The script verifies the release's SHA-256 checksum before installing. `PREFIX` and `VERSION` environment variables override the prefix and the release. The binaries are statically self-contained; at runtime `lean-fmt` needs the *target* project's Lean toolchain, which a Lean project has by definition. There is no Windows build — the memory-envelope reaper is Unix-only — so on Windows use the Lake dependency below.

**From source** (override with `make install PREFIX=/usr/local`, stage with `DESTDIR`):

```sh
git clone https://github.com/jcreinhold/lean-fmt.git
cd lean-fmt
make install
```

With elan on `PATH`, the first build installs the pinned toolchain from `lean-toolchain`. `make uninstall` removes exactly what `make install` placed.

## Quick start

Run it against your project:

```sh
lean-fmt check --root .        # report findings, write nothing
lean-fmt diff --root .         # preview formatting changes
lean-fmt fix --root .          # apply formatting and fixes in place
lean-fmt format --root . A.lean   # print the formatted source to stdout
```

`check`, `format`, and `diff` never write files. `fix` is the only writer: it validates the complete result against your project's exact Lake setup, re-checks that the file on disk hasn't changed since it was read, and writes atomically — a batch is published as a unit or not at all.

Exit codes: `0` means clean or applied; `1` means findings or proposed changes; `2` means something went wrong (bad arguments, workspace problems, internal failure). With `--json`, the report is one JSON object on stdout; statistics go to stderr.

Other commands: `rules` lists the lint rules, `lsp` starts the language server, `compiler setup`/`compiler status` manage the compiler plugin, `clean` removes the cache. `lean-fmt <command> --help` shows every flag.

## Performance and parallelism

lean-fmt caches successful analysis results under `.lean-fmt-cache/`, keyed on the source, toolchain, configuration, and dependencies of each file. A warm run where nothing changed returns without starting the Lean frontend at all — on a mathlib-sized project this is several times faster than a cold run, with byte-identical output. `--no-cache` disables all cache reads and writes; `clean` removes the cache.

`--max-memory GIB` sets a total memory budget for the run (default: 8 GiB). A run that would exceed it refuses the affected files by name rather than swapping or being killed.

`--workers N` runs N analysis workers in parallel (batch commands only). Results are identical at any N — output is assembled in file order — but the memory budget is divided among the workers, so a file that fits under one worker may be refused under four. Rule of thumb: use `--workers` for cold runs over many files; leave it at 1 for import-heavy files or small memory budgets. Measured on this repository's own 40-file cold run with `--max-memory 8`: two workers give identical output at 1.9× the speed; four divide memory too finely for the ~2 GiB per-file analyses.

## Formatting guarantees

Every command that produces canonical layout — `format`, `diff`, `fix`, `format --check` — validates the result before reporting it. Validation re-parses the candidate under a fresh frontend and checks node kinds, token spellings, comments, imports, and the `#exit` tail against the original (indentation and column positions may change), then formats the candidate a second time and requires byte-identical output. Only a result that passes is reported or written.

A file that fails validation is reported as `infrastructure-failure` with the failing check named, the run exits 2, and nothing is written. There is no silent fallback to unvalidated output. The one escape hatch is explicit: `-- lean-fmt: format-ignore-next` on the line above a declaration copies that declaration through unchanged (`docs/style.md` §"Comments, literals, and suppression").

Some content can't be broken across lines — a long string literal, a URL, an exact comment — and may exceed the line width rather than be rewritten. Two layout facts to know before the first run: a declaration's attributes move to their own line, and consecutive blank lines collapse to one.

## Configuration

Configuration is optional. Without any config file, every `.lean` file in the project is checked with default settings. To configure, put a `.lean-fmt.toml` (or `lean-fmt.toml`) in your project. The file **closest** to each source file governs it — configs do not merge; a nested config replaces its ancestors for its subtree:

```toml
extend = "../shared/lean-fmt.toml"   # inherit from one other file (cycle-detected)
include = ["LeanLib/**/*.lean", "Main.lean"]
exclude = ["Generated/**"]
force-exclude = true                 # apply exclude to explicitly named files too
respect-gitignore = true             # default
preview = false                      # enable preview-stage rules

[format]                             # settings that change the formatted bytes
line-width = 100                     # 1..1000

[lint]                               # rule selection
select = ["all"]
ignore = ["FMT004"]
per-file-ignores = { "Legacy/*.lean" = ["FMT005"] }
```

Notes:

- Path patterns are relative to the directory containing the config file. `*` and `?` match within one path component; `**` spans components.
- Files inside `.lake` are never selected. Git ignore files (`.gitignore`, `.git/info/exclude`, global ignore, `.ignore`) are honored in their usual order when `respect-gitignore` is on.
- Files you name on the command line skip the include/exclude and ignore gates — you named them — unless `force-exclude = true`. Rule selection still applies. CLI `--select` replaces configured `select`; CLI `--ignore` then wins.
- Unknown keys, unknown rule codes, and malformed patterns are errors, not warnings.
- `lean-fmt config show PATH [--json]` shows the effective settings for one file and where each came from. Read-only.
- Symlinked directories are not followed. A symlinked file inside the project is reported once, under its target's path.
- In an `extend` chain, scalar settings and plain arrays replace the parent's; `extend-*` keys append; `extend` itself is not inherited. Top-level linter keys still work with a deprecation notice; setting one both at top level and under `[lint]` is an error.
- `[format]` settings affect the cache key (different width, different bytes); `[lint]` settings do not — rule selection is a filter over results, so changing it never triggers re-analysis.

## Using lean-fmt in another project

For the CLI alone, install the binary (above). To use lean-fmt as part of a Lean project's build — `lake lint` integration or the compiler plugin — add it as a Lake dependency. Lean's ecosystem has no binary artifact server, so consumers build from source; the first `lake exe lean-fmt` run compiles it (minutes, once), then Lake's build cache makes it free. Your project's `lean-toolchain` must match one lean-fmt builds against.

There are three levels, each independent of the next. The downstream test suite exercises all three.

**1. Run it.** Add the dependency; `lake exe` finds lean-fmt's executable automatically:

```lean
require «lean-fmt» from git
  "https://github.com/jcreinhold/lean-fmt" @ "v0.1.0"
```

```sh
lake exe lean-fmt check --root .
```

Pin the tag, not a branch: what CI runs is what you reviewed.

**2. Wire it into `lake lint`.** Two lines, so `lake lint` (and `leanprover/lean-action` in CI) runs lean-fmt:

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

The guillemets are required in **both** halves: `lean-fmt` is not a legal Lean identifier, and Lake resolves the driver string through `String.toName`. Findings exit 1 and infrastructure failures exit 2, so CI can tell them apart. `lake lint MODULE` does not forward `MODULE` to the driver; pass arguments after `--`.

**3. Add the compiler plugin.** Optional, and purely a speed measure: without it, the syntax-dependent rules run the Lean frontend and produce the same findings more slowly. One line, on the package:

```lean
package myproject where
  plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared]
```

Costs to weigh: editing the plugin re-elaborates every module that loads it (its shared library is part of each module's build trace); loading a plugin runs its initializers once per module; and on macOS Lake adds its own shared library as a second plugin whenever any plugin is present. Lake's `plugins` field is still officially experimental — pin your toolchain and re-test after upgrades.

`compiler setup` prints integration identifiers and guidance. `compiler status` audits toolchain compatibility and artifact coverage without building anything. `docs/ci.md` has CI recipes, caching guidance, and upgrade checklists.

## Formatting a stream or a range

Use `-` as the file to read a buffer from stdin and write the answer to stdout — this is how editor plugins talk to the CLI. It requires `--stdin-filename PATH`: the path the buffer would have on disk, used to find configuration and Lake setup (the path need not exist). Without it the buffer would silently get default settings and could differ from the same bytes on disk. A stdin run never writes files and never touches the cache.

```sh
lean-fmt format - --stdin-filename MyProj/Basic.lean < buffer.lean
lean-fmt format - --stdin-filename MyProj/Basic.lean --range 120:180 < buffer.lean
lean-fmt format - --stdin-filename MyProj/Basic.lean --range-lines 12:1-18:1 --json < buffer.lean
```

`--range` takes half-open byte offsets; `--range-lines` takes 1-based lines and columns. Formatting works on whole declarations, so **the range that comes back is usually wider than the one you asked for** — a request touching a few bytes inside a declaration formats the whole declaration. The actual range is reported on stderr and in `--json` as `actualRange`, with a `sourceMap` of each unit's extents.

A range is not faster than a whole buffer: either way, the run costs one full parse of the input. Ranges control which bytes come back changed, not how long the run takes.

## Editors

`lean-fmt lsp` is a language server offering formatting, range formatting, code actions (quickfix, fix-all, organize imports), and diagnostics over stdio. It runs alongside Lean's own language server, which has no formatter.

```sh
lean-fmt lsp --root . --debounce-ms 150
```

One workspace root per session; analysis is incremental and debounced, so a burst of edits costs one re-analysis. The server never writes to `.lean` files or the cache. `--max-memory` bounds the session. Setup for VS Code, Neovim, and Emacs — plus two behaviors (widened ranges, trailing-comment ownership) that otherwise get reported as bugs — is in `docs/editor-setup.md`.

`lsp` replaces `serve`, the NDJSON service earlier releases shipped. Every `serve` request has an LSP counterpart: `health` is `$/lean-fmt/health`, `analyze` is `textDocument/didOpen`/`didChange` plus published diagnostics, and `shutdown` is `shutdown`.

## Architecture and verification

The application exposes no library API. `LeanFmt.Project` hides source selection, immutable snapshots, module evidence, and exact setup; `LeanFmt.Semantic` keeps product results independent of compiler projections. Layout authority is Lean's own grammar: the formatter registered for each parser produces the layout document, and `LeanFmt.Formatter.NativeLayout` adapts those documents under source-owned trivia and parser-significant-column constraints — nothing keys layout on a kind name, a quoted atom, or a rewrite table. Artifact validation, fallback, cache sequencing, stale checks, and writes stay behind one private execution operation. `LeanFmt.Cli` owns only parsing, presentation, statistics, and exit mapping.
`docs/adding-a-rule.md` is the contributor guide for the rule engine; `docs/toolchain-upgrade.md` is the maintainer checklist for moving the pinned Lean toolchain.

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
lake test              # the unit tier plus every non-slow suite
lake test -- --all     # everything, including compiler/downstream/ci
```
