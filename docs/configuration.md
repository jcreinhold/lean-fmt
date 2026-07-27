# Configuration reference

Configuration is optional. Without a config file, every root-relative `.lean` file outside `.lake` is checked with
default settings.

## Discovery

Walking up from each source file to the project root, the **closest** `.lean-fmt.toml` (or `lean-fmt.toml`) governs the
file. Configs do not merge: a nested config replaces its ancestors for its subtree. Both names in one directory is an
error. `--config PATH` overrides discovery and anchors at the project root.

```toml
extend = "../shared/lean-fmt.toml"   # inherit from one file (cycle-detected)
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

Linter keys still work at the top level with a deprecation notice; setting one both there and under `[lint]` is an
error. `line-width` has no flat spelling. In an `extend` chain, scalars and plain arrays replace the parent's,
`extend-*` keys append, and `extend` itself is not inherited.

## Selection

Path patterns are relative to the directory containing the config file: `*` and `?` stay within one path component; a
complete `**` component spans zero or more. Selection runs as ordered gates — `.lake` first, then git ignore sources,
then `exclude`, then `include`. Nothing selects inside `.lake`. Ignore sources apply in order: global git ignore,
`.git/info/exclude`, `.gitignore` outer to inner, `.ignore`. lean-fmt reads them directly rather than running `git`.

Files named on the command line skip the ignore and `include`/`exclude` gates — you named them — unless
`force-exclude = true`. Rule selection applies either way. CLI `--select` replaces configured `select`; CLI `--ignore`
then wins. Unknown keys, selectors, and malformed patterns are errors.

Directory symlinks are not followed. A symlinked file inside the project resolves to its target and is reported once
under the target's path; one whose target lies outside the project is not discovered.

Standalone scripts and nested or root `lakefile.lean` files get the same report and cache behavior as buildable modules.

`lean-fmt config show PATH [--json]` prints the effective settings for one file — each with its source file and line,
the `extend` chain, the ignore sources in force, and whether the path would be selected with the deciding gate.
Read-only and deterministic.

## Selection and the cache

A `[format]` key enters the result-cache identity; a `[lint]` key never does. Rule selection is a projection over one
canonical semantic result, so changing `select`/`ignore` changes neither the analysis nor cache entries — it decides
only which fact tier a run needs (the cheapest tier that answers every selected rule). Changing `line-width` changes the
canonical bytes, so it misses entries recorded at another width.

## Memory and parallelism

`--workers N` (batch commands) runs N frontend children in parallel. It defaults to `LEAN_NUM_THREADS` if that is set,
else the machine's core count — the rule Lake uses to size its own build. Output is assembled in file order, so the
report is byte-identical at any N. Measured on this repository's 40-file cold run: two workers are byte-identical to one
at 1.9× the speed. On a mathlib project, a 17-file cold `format` went 16.95 s at one worker to 6.74 s at four and 5.48 s
at eight.

**lean-fmt imposes no memory limit.** Neither does Lake, which spawns one `lean` per module and passes no `-M`, no
`ulimit`, and no `setrlimit`. A file that needs six gigabytes gets them; a machine that runs out swaps. `--workers N` is
the control — if N children do not fit, ask for fewer.

There used to be a `--max-memory` cap divided between workers. It refused work on any project that imports mathlib — 187
of 200 files at eight workers — because the number it divided counted each child's shared `.olean` mapping in full.
Those pages are shared, clean, and reclaimable: a child reading 2.05 GiB of RSS had a physical footprint of 173 MiB.

## Streaming and ranges

`-` as the file target reads a buffer from stdin and writes the answer to stdout. It requires `--stdin-filename PATH`:
the path the buffer would have on disk, used to find configuration and Lake setup (it need not exist). Without it the
buffer would silently get default settings and could differ from the same bytes on disk. A stdin run never writes files
and never touches the persistent cache.

```sh
lean-fmt format - --stdin-filename MyProj/Basic.lean < buffer.lean
lean-fmt format - --stdin-filename MyProj/Basic.lean --range 120:180 < buffer.lean
lean-fmt format - --stdin-filename MyProj/Basic.lean --range-lines 12:1-18:1 --json < buffer.lean
```

`--range` takes half-open byte offsets into the normalized source; `--range-lines` takes 1-based lines and codepoint
columns. Both require `-`. Formatting is command-granular, so **the returned range is usually wider than requested** — a
request touching bytes inside a declaration formats the whole declaration. The actual range is reported on stderr and in
`--json` as `actualRange`, with a `sourceMap` of each unit's extents. A full range is byte-identical to formatting the
buffer.

A range is not cheaper than a whole buffer: either costs one full parse. Ranges control which bytes come back changed,
not how long the run takes.

## Cache and compiler integration

Successful analysis results are cached under `.lean-fmt-cache/`. Each entry validates the exact source, toolchain,
evaluated configuration, ordered Lake environment, dependency trace content, formatter runtime, validation level, and
result schema. Missing, stale, or corrupt entries are ordinary misses. A warm run still evaluates the Lake workspace
(`lakefile.lean` is executable configuration); once the environment validates, an all-hit run returns without starting a
frontend. `--no-cache` neither reads nor writes the cache; `clean` removes only the root cache.

Rules declare whether they need source bytes or exact syntax. For source-tier rules, a current `.olean` counts as
successful-compilation evidence. For syntax-tier rules, the optional compiler plugin stores a lossless syntax projection
in each integrated `.olean`; without it, the exact frontend runs and returns the same findings more slowly. The
projection holds facts, never findings, so editing a rule cannot rebuild an integrating project.

`compiler setup` prints integration identifiers and guidance; it does not rewrite your `lakefile.lean`.
`compiler status` audits toolchain compatibility and artifact coverage read-only. Plugin costs and Lake details: README
§"Using lean-fmt in another project" and `docs/ci.md`.
