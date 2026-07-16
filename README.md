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

An explicit `--config PATH` or conventional root `lean-fmt.toml` may contain only:

```toml
include = ["LeanFmt/**/*.lean", "Main.lean"]
exclude = ["LeanFmt/Generated/**"]
select = ["all"]
ignore = ["FMT002"]

[per-file-ignores]
"LeanFmt/Legacy/*.lean" = ["FMT001"]
```

Path patterns are root-relative: `*` and `?` stay within one path component, while a complete `**`
component spans zero or more components. Explicit positional files bypass include/exclude but still
honor rule selection. Repeatable CLI `--select` replaces configured selection when present; CLI
`--ignore` then wins. Selectors are exact rule codes, `text`, or `all`. Unknown keys, selectors, and
malformed patterns fail clearly instead of being ignored.

Rule selection is a projection over one canonical semantic result, so changing selection neither
changes frontend strategy nor creates strategy-specific cache entries.

Without positional files, selection covers every root-relative `.lean` source outside `.lake`, not
only library modules. Standalone scripts and nested/root `lakefile.lean` configuration therefore
receive the same deterministic report and cache semantics as buildable modules.

## Cache and compiler integration

Successful semantic results are cached under `.lean-fmt-cache/` by default. The cache key includes
the exact source, target toolchain, evaluated source/module configuration, ordered Lake environment
and verified build traces, formatter binary, validation level, and semantic-result schema. Missing or corrupt
entries are ordinary misses. `--no-cache` performs neither cache reads nor writes.

A warm run still evaluates the Lake workspace because `lakefile.lean` is executable configuration;
skipping that step cannot be sound for general projects. Once its epoch is validated, an all-hit run
returns before constructing a project frontend environment, starting an analyzer/extractor child, or
creating fallback temporary files. Buildable and standalone sources are both cacheable when the
project capability can establish their complete semantic identity.

Each rule declares whether it needs only immutable source bytes or exact syntax. For source-input
rules, one shared Lake no-build graph can use a current ordinary `.olean` as successful-compilation
evidence without loading its frontend environment. It never fabricates a syntax projection. A
compiler plugin stores syntax-capable formatter data in each integrated `.olean`; Lake owns its
derived sidecar. Syntax-input rules use that exact artifact or the ordinary frontend in a fresh,
memory-bounded child. Every path produces the same canonical result before rule projection. The CLI
resolves the target root's Lean and Lake installation itself, so normal use does not wrap the binary
in a second `lake env` process.

`compiler setup` prints versioned integration identifiers and guidance. It deliberately does not
rewrite arbitrary executable `lakefile.lean`. `compiler status` performs a read-only, path-sorted
audit of exact toolchain compatibility and embedded module-artifact coverage; it neither builds
modules nor publishes artifacts. `clean` removes only the root `.lean-fmt-cache` and is idempotent.

## Architecture and verification

The application exposes no library API. `LeanFmt.Project` hides complete source selection, immutable
snapshots, module evidence, and exact setup; `LeanFmt.Semantic` keeps product results independent of
compiler projections. Artifact validation, fallback, cache sequencing, validation, stale checks, and
writes remain behind one private execution operation. `LeanFmt.Cli` owns only parsing, presentation,
statistics, and exit mapping. Design and
performance evidence lives in `docs/projects/execution-core-v2/`; exploratory code remains under
`experiments/`.

```sh
LEAN_NUM_THREADS=1 lake build
LEAN_NUM_THREADS=1 lake exe lean-fmt-tests
tests/compiler/run.sh
tests/check/run.sh
tests/modes/run.sh
tests/scale/run.sh
```
