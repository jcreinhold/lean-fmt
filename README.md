# lean-fmt

A native Lean formatter and linter for Lean 4. Every compiled source uses Lean 4.32's module
system; `lakefile.lean` is executable configuration and is the repository exception.

## Commands

```sh
lake build
.lake/build/bin/lean-fmt check --root .
.lake/build/bin/lean-fmt format --root . --json LeanFmt/Basic.lean
.lake/build/bin/lean-fmt diff --root . LeanFmt/Basic.lean
.lake/build/bin/lean-fmt fix --root . LeanFmt/Basic.lean
.lake/build/bin/lean-fmt lsp --root .
.lake/build/bin/lean-fmt serve --root .
.lake/build/bin/lean-fmt rules --json
.lake/build/bin/lean-fmt compiler setup
.lake/build/bin/lean-fmt compiler status --root . --json
.lake/build/bin/lean-fmt clean --root .
.lake/build/bin/lean-fmt check --help
```

`check` reports selected findings. `format` returns the complete proposed source for changed files,
and `diff` returns a deterministic unified diff. These three commands never write source. `fix` is
the only `.lean` source writer: it rejects invalid byte ranges and conflicting edits as a unit,
validates the complete candidate under the target's exact Lake module setup, rereads the original
snapshot to reject stale writes, and publishes by permission-preserving same-directory rename.

Exit `0` means clean or successfully applied output. Exit `1` means findings, proposed changes,
broken sources, or rejected fixes. Exit `2` means a request, workspace, or infrastructure failure
prevented a trustworthy result. `--max-memory GIB` is an aggregate operating envelope, not a worker
or scheduling control. Statistics go to stderr so `--json` stdout remains one valid object.

## Configuration and selection

Configuration is discovered hierarchically. Walking up from each source file to the project root, the
**closest** `.lean-fmt.toml` (or `lean-fmt.toml`) governs it; the hierarchy does not merge, so a nested
config replaces its ancestors for its subtree rather than layering onto them. Both recognized names in
one directory is an error, not a silent precedence win. `--config PATH` overrides discovery entirely
and anchors at the project root.

```toml
extend = "../shared/lean-fmt.toml"   # the only composition: explicit, one file, cycle-detected
include = ["LeanFmt/**/*.lean", "Main.lean"]
exclude = ["Generated/**"]
force-exclude = true                 # apply exclude to explicitly named paths too
respect-gitignore = true             # default
preview = false

[format]                             # settings that change canonical bytes
line-width = 100                     # 1..1000

[lint]                               # settings that project over results
select = ["all"]
ignore = ["FMT002"]
per-file-ignores = { "Legacy/*.lean" = ["FMT001"] }
```

Linter keys still work at the top level and emit a deprecation notice; setting one in both places is an
error. `line-width` has no flat spelling. In an `extend` chain scalars and base arrays replace, the
`extend-*` family concatenates, and `extend` itself is not inherited.

Path patterns anchor at the **declaring** config's directory, never the root and never the consuming
file: `*` and `?` stay within one path component, while a complete `**` component spans zero or more.
Selection runs as an ordered set of gates — `.lake` first, then git ignore sources, then the config's
`exclude`, then its `include`. `.lake` is an absolute floor: no key, no `--config`, and no explicitly
named path lifts it. Ignore sources apply in precedence order (global git ignore, `.git/info/exclude`,
`.gitignore` outer to inner, `.ignore`) and are read directly rather than by invoking `git`.

Directory symlinks are not followed, so a link that points at its own ancestor cannot make the walk
loop. A symlinked source inside the project resolves to its target and is reported once under the
target's path; one whose target lies outside the project is not discovered at all.

Explicit positional files bypass the ignore and `include`/`exclude` gates — you named the file — unless
`force-exclude = true`, which is precisely the setting that makes exclusion apply to them too. Rule
selection applies either way. Repeatable CLI `--select` replaces configured selection when present; CLI
`--ignore` then wins. Unknown keys, selectors, and malformed patterns fail clearly instead of being
ignored.

`lean-fmt config show PATH [--json]` answers what actually applies to one file: every effective setting
with the file and line it came from, the `extend` chain, the ignore sources in force, and whether the
path would be selected with the deciding gate. It is read-only and deterministic.

A `[format]` key enters the result-cache identity; a `[lint]` key never does. That is the same
discipline stated as a rule you can check by inspection: rule selection is a projection over one
canonical semantic result, so changing selection neither changes frontend strategy nor creates
strategy-specific cache entries. It decides one thing only: which fact tier a run must obtain, which is
the cheapest tier answering every selected rule. Changing `line-width` does change the canonical bytes,
so it correctly misses a cache entry recorded at another width.

Without positional files, selection covers every root-relative `.lean` source that survives the gates,
not only library modules. Standalone scripts and nested/root `lakefile.lean` configuration therefore
receive the same deterministic report and cache semantics as buildable modules.

## Cache and compiler integration

Successful semantic results are cached under `.lean-fmt-cache/` by default. One environment-scoped,
atomically replaced index holds the per-source results, avoiding thousands of filesystem probes and
writes. Each entry still validates the exact source, target toolchain, evaluated source/module
configuration, ordered Lake environment, dependency trace content, formatter runtime, validation
level, and semantic-result schema. The environment epoch also hashes current project and dependency
sources because compact downloaded traces do not necessarily enumerate every source input. Missing,
stale, or corrupt indexes and entries are ordinary misses. `--no-cache` performs neither cache reads
nor writes.

A warm run still evaluates the Lake workspace because `lakefile.lean` is executable configuration;
skipping that step cannot be sound for general projects. Once its epoch is validated, an all-hit run
returns before constructing a project frontend environment, starting an analyzer/extractor child, or
creating fallback temporary files. Buildable and standalone sources are both cacheable when the
project capability can establish their complete semantic identity.

Each rule declares whether it needs only immutable source bytes or exact syntax, by which fact view
its implementation reads (`docs/adding-a-rule.md`). For source-tier rules, one shared Lake no-build
graph can use a current ordinary `.olean` as successful-compilation evidence without loading its
frontend environment. It never fabricates a syntax projection. A compiler plugin stores the exact
frontend's lossless projection in each integrated `.olean` — the projection only, never this
formatter's findings about the module, so editing a rule cannot rebuild an integrating project. Lake
owns its derived sidecar. When syntax is required, one private Lake operation requests the registered
`leanFmtArtifact` jobs with `noBuild := true`, then recomputes each content hash and verifies the
module and complete source snapshot. Missing or invalid artifacts fall through to the exact frontend
instead of being rebuilt during a check. Every path produces the same canonical result before rule
projection. The CLI resolves the target root's Lean and Lake installation itself, so normal use does
not wrap the binary in a second `lake env` process.

On the recorded Apple-silicon machine, the final release candidate checked an already ordinarily
built mathlib revision `783ccda4` with 8,795 selected sources and a cold formatter cache in 136.549
seconds. Peak aggregate RSS was 1,316,240 KiB, memory pressure remained normal, and swap did not grow.
The subsequent all-hit check took 23.012 seconds with module evidence, artifacts, and the analyzer all
forcibly disabled; it returned byte-identical output without starting a frontend or extractor.
These measurements exclude the prerequisite mathlib build and apply to the recorded binary and
workload digests; full details are in the execution-core evidence.

`compiler setup` prints versioned integration identifiers and guidance. It deliberately does not
rewrite arbitrary executable `lakefile.lean`. `compiler status` performs a read-only, path-sorted
audit of exact toolchain compatibility and embedded module-artifact coverage; it neither builds
modules nor publishes artifacts. `clean` removes only the root `.lean-fmt-cache` and is idempotent.

## Using lean-fmt in another project

There is no prebuilt binary. Lean's ecosystem has no artifact server — Reservoir indexes packages and
reports build status, it does not serve builds — so a consuming project takes `lean-fmt` as an ordinary
Lake dependency and builds it from source, the way `doc-gen4` and `lake exe cache` are consumed.

Three levels, each independent of the ones below it. `tests/downstream/run.sh` exercises all three
against a real two-package workspace.

**Run it.** With `require «lean-fmt» from git "..."` in the lakefile, the executable already resolves:
Lake searches every package in the workspace for an executable target.

```sh
lake exe lean-fmt check --root .
```

**Wire it into `lake lint`.** Lake has a lint-driver protocol, and `leanprover/lean-action` probes
`lake check-lint` and runs `lake lint` when a driver is configured. Two lines in the consuming package:

```lean
package myproject where
  lintDriver := "«lean-fmt»/«lean-fmt»"
  lintDriverArgs := #["check"]
```

The guillemets are required in **both** halves. `lean-fmt` is not a legal Lean identifier, and Lake
resolves a driver spec through `String.toName`, so the bare spelling finds neither the package nor the
executable. Findings exit 1 and infrastructure failures exit 2, so CI can tell them apart. Note that
`lake lint MODULE` does not forward `MODULE` to the driver; arguments reach it after `--`.

**Add the compiler plugin.** Optional, and purely a speed measure: without it a syntax-tier rule runs
the exact frontend and returns the same finding. One line, on the package rather than on each library,
because `LeanLib.plugins` is the package's plugins followed by the library's own:

```lean
package myproject where
  plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared]
```

That also reaches the language server, since Lake writes the plugin list into each module's
`setup.json`. The `leanFmtArtifact` facet needs no declaration on your side: Lake merges every
dependency's facet declarations into one workspace-global map.

Three costs to weigh. The plugin's shared library enters every consuming module's build trace, so
editing the plugin re-elaborates every module that loads it — that edge is what makes the artifact
trustworthy, and `platformIndependent := true` suppresses it only by lying. Loading a plugin runs the
initializers of the plugin module and all its imports, per module. And on macOS, Lake adds its own
shared library as a second plugin whenever any plugin is present.

Lake's `plugins` field is still officially experimental and its target-key syntax has been revised
more than once. Pin the toolchain and re-run `tests/downstream/run.sh` after a bump.

## Streaming and ranges

`-` is a file target: the buffer arrives on stdin and the answer goes to stdout. It requires
`--stdin-filename PATH`, which is the buffer's identity rather than its content — the path need not
exist, but configuration, module resolution, and the exact Lake setup are resolved from where it
claims to be. Without it a buffer would silently get built-in defaults and answer differently than the
same bytes on disk. Every gate a file argument passes still applies, and a stdin run never writes
source and never touches a persistent cache entry.

```sh
lean-fmt format - --stdin-filename LeanFmt/Basic.lean < buffer.lean
lean-fmt format - --stdin-filename LeanFmt/Basic.lean --range 120:180 < buffer.lean
lean-fmt format - --stdin-filename LeanFmt/Basic.lean --range-lines 12:1-18:1 --json < buffer.lean
```

`--range` takes half-open byte offsets into the normalized source; `--range-lines` takes 1-based lines
and 1-based codepoint columns. Both require `-`. Formatting is command-granular, so **the range that
comes back is usually wider than the one you asked for**: the request is widened to the layout units
it touches, and that actual range is reported on stderr and in `--json` as `actualRange`, alongside a
`sourceMap` giving each unit's source and output extent. A request naming a few bytes inside a
declaration formats the whole declaration; a full range is byte-identical to formatting the buffer.

A range is not cheaper than the whole buffer. The cost of a stream request is one exact frontend run
over everything received, which a range cannot skip without giving up exactness. Ranges control which
bytes come back changed, not how long the run takes.

## Editors

`lsp` is the editor entry point. It speaks the Language Server Protocol over stdio and offers
formatting, range formatting, formatting-derived code actions (quickfix, fix-all, organize imports),
and diagnostics. It runs alongside Lean's own language server, which offers no formatting at all.
`docs/editor-setup.md` has the VS Code, Neovim, and Emacs inputs, and the two behaviors — widened
ranges and trailing-comment ownership — that otherwise get reported as bugs.

```sh
lean-fmt lsp --root . --debounce-ms 150
```

One workspace root per session, one exact frontend child per request, no writes: the server never
touches a `.lean` file or the result cache. `--max-memory` bounds the session and its children
together.

### The NDJSON service, and when it goes

`serve` predates `lsp` and is now a compatibility adapter. It reads `lean-fmt.service.v1` NDJSON from stdin and writes one compact response per line. It
supports `health`, exact unsaved-source `analyze`, and `shutdown` requests with arbitrary JSON IDs.
Analyze requests name an existing selected project source and carry a strictly increasing per-path
version plus replacement source bytes. Unsaved bytes always run through a fresh exact-context child;
ordinary outputs, compiler artifacts, and the persistent result cache describe disk state and are
never reused for editor snapshots.

The service processes exactly one request at a time and flushes its response before reading the next,
giving FIFO behavior and bounded stream backpressure without a concurrent queue. Malformed requests,
stale versions, invalid paths, child failures, and resource exhaustion are structured responses and
do not terminate the service. Request lines are limited to 32 MiB and sources to 16 MiB. The service
never writes source or `.lean-fmt-cache` state.

```json
{"id":1,"method":"health"}
{"id":2,"method":"analyze","path":"LeanFmt/Basic.lean","version":1,"source":"module\n"}
{"id":3,"method":"shutdown"}
```

Everything `serve` does, `lsp` does through a protocol editors already speak: `health` is
`$/lean-fmt/health`, `analyze` is `textDocument/didOpen`/`didChange` plus published diagnostics, and
`shutdown` is `shutdown`. `serve`'s string error codes are its own; `lsp` uses the JSON-RPC integers.
It is kept because it is a published interface with its own suite (`tests/service/`), not because
anything needs two of these.

**Removal plan.** `serve` is removed once (1) `lsp` has been exercised by a real editor rather than
only by protocol harnesses, and (2) one release has shipped with this notice, so a consumer has had a
version to migrate against. Neither has happened yet, so it stays and stays supported. It gains no new
capability in the meantime: `preview`, `unsafeFixes`, code actions, and range formatting are `lsp`'s
and are not being back-ported.

## Architecture and verification

The application exposes no library API. `LeanFmt.Project` hides complete source selection, immutable
snapshots, module evidence, and exact setup; `LeanFmt.Semantic` keeps product results independent of
compiler projections. Artifact validation, fallback, cache sequencing, validation, stale checks, and
writes remain behind one private execution operation. `LeanFmt.Cli` owns only parsing, presentation,
statistics, and exit mapping. Design and
performance evidence lives in `docs/projects/execution-core-v2/`; exploratory code remains under
`experiments/`. `docs/adding-a-rule.md` is the contributor guide for the rule engine.

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
tests/compiler/run.sh
tests/check/run.sh
tests/lossless/run.sh
tests/modes/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/boundary/run.sh
```
