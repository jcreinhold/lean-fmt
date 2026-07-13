# Using lean-fmt

`lean-fmt` checks, formats, fixes, diffs, and serves editor requests for Lean 4 source in a Lake project. It
is conservative: it applies only edits with explicit rule support and verifies that edited files still parse
(and, when asked, still elaborate) before writing them. Comments and docstrings are preserved.

The `lean-fmt` binary is **Lean-free** — it never links `libleanshared`. It reaches the Lean frontend by
spawning a Lean-linked *worker child* as a subprocess, which loads the installed `LeanFmt` capability. So the
first step on any machine is to install a worker for your toolchain.

## Install a worker

```sh
# Build and install the worker for the toolchain of the current Lake project
# (reads ./lean-toolchain; falls back to the pinned default).
lean-fmt install-worker
```

`install-worker` builds the `LeanFmt` capability and the `lean-fmt-worker-child` host for one toolchain,
smoke-tests the load, and installs it under the per-user data directory keyed by toolchain. It resolves the
Lean sysroot from elan for the toolchain by default. Useful flags:

| Flag | Purpose |
| --- | --- |
| `--toolchain <T>` | Build for `leanprover/lean4:v4.32.0-rc1` or the bare `v4.32.0-rc1` instead of the project's. |
| `--sysroot <DIR>` | Build and link against an explicit Lean sysroot. |
| `--install-dir <DIR>` | Install into `DIR` instead of the user data dir (also honored via `LEAN_FMT_WORKERS_DIR`). |
| `--worker-child <FILE>` | Use a prebuilt `lean-fmt-worker-child` binary instead of building one. |
| `--force` | Rebuild even if a current, smoke-passing install already exists. |

A second identical-input install is a cache hit and does no work. Once a worker is installed, every
file-processing command resolves it automatically from the project's `lean-toolchain`.

## The file-processing commands

All four operate over a Lake project (discovered from `--root`, default `.`) or an explicit list of `.lean`
files. Discovery is skipped when explicit files are given.

```sh
lean-fmt check           # report findings; never writes
lean-fmt format          # report what formatting would change; never writes
lean-fmt fix             # apply safe fixes to files on disk
lean-fmt diff            # show the unified diff formatting would produce
```

Shared options (`check`, `format`, `fix`, `diff`):

| Flag | Meaning |
| --- | --- |
| `[FILE ...]` | Explicit `.lean` files; skips workspace discovery. |
| `--root <DIR>` | Lake project root to discover (default `.`). |
| `--module-root <MODULE>` | Restrict discovery to one module root. |
| `--config <FILE>` | Explicit config file (default `lean-fmt.toml` at the root). |
| `--format text\|json` | Output rendering (default `text`). JSON stdout stays a single clean object. |
| `--select <SELECTOR>` | Activate a rule id, category, or `all` (repeatable). Overrides config. |
| `--ignore <SELECTOR>` | Deactivate a rule id, category, or `all` (repeatable). Beats a matching select. |
| `--no-cache` | Ignore the incremental result cache (diagnostic escape hatch; the cache is otherwise sound). |
| `--statistics` | Print run statistics (counts, cache hits, files written) to stderr. |

`fix` adds write-validation control (the safe-apply gate re-parses each edited file before writing it):

| Flag | Meaning |
| --- | --- |
| `--check-syntax` | Re-parse each edited file; refuse to write if it no longer parses. **On by default.** |
| `--check-elab` | Re-parse *and elaborate*; refuse to write unless elaboration also succeeds (stricter, slower). |
| `--unsafe-no-validate` | Skip the re-check gate (escape hatch). The patch **conflict** check still always runs. |

The three `fix` level flags are mutually exclusive.

## Listing rules

```sh
lean-fmt rules              # text: id, on/off default, description
lean-fmt rules --format json
```

The built-in rules today (each `on` unless noted):

```
text/trailing-whitespace     Trailing whitespace at end of line.
text/final-newline           File ends with exactly one trailing newline.
imports/sorted               Import statements are sorted and deduplicated.
layout/blank-lines           Excess consecutive blank lines between commands.
layout/end-name              A bare `end` closing a named block carries the block's name.
declaration/header-spacing   Spacing around declaration headers and binders.
tactic/block-indent          Tactic block indentation is consistent.
safety/preserve-comments     Formatting never drops or reorders comments.
performance/large-file       [off] File exceeds the size where formatting is skipped by default.
```

## Configuration

Config lives in `lean-fmt.toml` at the Lake project root (or an explicit `--config` path). Unknown keys are
rejected. Every field has a default, so the file is optional. All fields:

```toml
# lean-fmt.toml
line_width      = 100            # target line width for layout rules
include         = ["Mathlib/"]   # if non-empty, only paths under these prefixes are formatted
exclude         = ["vendor/"]    # paths under these prefixes are skipped (.lake is always excluded)
select          = ["all"]        # rule/category/all selectors turned on; empty = each rule's default
ignore          = ["tactic"]     # selectors turned off; an ignore beats a select in the same layer

# per-path-prefix extra ignores: files under the key additionally ignore these selectors
[per_file_ignores]
"tests/" = ["imports/sorted"]
```

Precedence, lowest to highest: each rule's built-in default → config `select`/`ignore` → command-line
`--select`/`--ignore` → `per_file_ignores` (a per-file ignore wins over everything).

## The incremental cache

Runs are cached under `.lean-fmt-cache` at the project root. The cache key is every semantic input — config
fingerprint, toolchain label, runtime source digest, source digest, the file's import set, and the validation
mode — so an unchanged file with unchanged config and toolchain is a sound cache hit and is not re-parsed.
`--no-cache` bypasses reuse and writes nothing to the cache; it is a diagnostic tool, not a correctness knob.

The worker resolves project-internal imports against `.lake/build/lib`. If the project is unbuilt, a file with
project-internal imports Degrades to a reported broken file rather than being formatted against a stale model —
so build the project (`lake build`) before formatting files that import its own modules.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. `check`/`diff`: nothing to change and nothing broken. `fix`: applied cleanly, nothing broken. |
| `1` | `check`/`diff`: at least one file would change or is broken. `fix`: at least one file is broken. |
| `2` | A per-file failure (e.g. no usable worker for a file, or an analysis error). |

`fix` treats a *changed* file as success (it applied the change); only a *broken* file is a nonzero exit. A
top-level error (config/discovery failure, no installed worker for the workspace toolchain, render failure) is
also a nonzero exit with a `lean-fmt: <error>` line on stderr.

## Editor integration (`serve`)

```sh
lean-fmt serve --root .
```

`serve` runs a long-lived, stdio, line-delimited JSON service for editors: one JSON **request** object per line
on stdin, one JSON **response** object per line on stdout, with progress and errors on stderr. A single
controller thread owns the one worker session and answers requests one at a time in FIFO order, so no two
requests ever mutate the session concurrently. Options mirror the file commands (`--root`, `--module-root`,
`--config`, `--select`/`--ignore`, `--check-elab`, `--no-cache`).

Requests are `method`-tagged:

```json
{"method":"format","path":"A.lean","text":"import Init\n\ndef x := 0\n","version":3}
{"method":"check","path":"A.lean","text":"...","version":4}
{"method":"health"}
{"method":"shutdown"}
```

Responses are `status`-tagged: `analyzed` (with `changed`, optional `formatted`/`diff`, and rule `findings`),
`broken` (parse findings), `stale` (a request whose `version` is at or below the last seen for that path — a
late request never clobbers newer editor state), `busy` (the bounded queue is full; retry), `health`,
`shutting_down`, and `error` (a malformed request line — the loop continues). EOF on stdin, or a `shutdown`
request, ends the server.

## Typical workflow

```sh
cd my-lake-project
lean-fmt install-worker      # once per toolchain
lake build                   # so project-internal imports resolve
lean-fmt check               # see what is off (exit 1 if anything)
lean-fmt diff                # preview the edits
lean-fmt fix                 # apply them (re-parsed before each write)
```
