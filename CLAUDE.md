# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project on Lean's private-by-default module system. Every
compiled production, entry-point, test, and fixture source begins with `module`; only the
`lakefile.lean` is exempt. The product has one private intent-to-report operation, an atomic aggregate
semantic-result cache, preview/fix modes, read-only compiler-integration audit, and a capacity-one
exact editor service. A compiler plugin writes a silent formatter record into the successful module
`.olean`; a Lake module facet extracts it into a compact content-addressed sidecar. The application
reads that facet through one private no-build Lake operation, and only when a selected rule needs
syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate
split. `docs/projects/execution-core-v2/` and its measurements govern architecture work.

## Build

```sh
lake build
lake exe lean-fmt
lake exe lean-fmt-tests
tests/compiler/run.sh
tests/check/run.sh
tests/suppression/run.sh
tests/lossless/run.sh
tests/modes/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/boundary/run.sh
tests/syntax/run.sh
tests/discovery/run.sh
```

Use the target project's exact Lean toolchain for frontend and plugin experiments. Keep experiments
out of production modules until their owning prompt selects and verifies the interface.

## Design constraints

- Prefer pure Lean. Add another language only for a named capability or a measured speed gain Lean
  cannot reach.
- Preserve exact ordered imports, search-path precedence, syntax effects, and validation identity.
- Do not call superset parsing exact.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as
  distinct workloads.
- Stop memory experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer private deep modules that hide lifecycle and cache sequencing.
- Keep CLI parsing and rendering in `LeanFmt.Cli`; semantic execution, validation, stale checking, and
  publication belong to `LeanFmt.Application` and its lower capabilities.
- `check` and `diff` never write source. `format` and `fix` publish only a complete, conflict-free
  result validated under the exact module setup, after a stale-source check: `format` publishes the
  canonical layout (no rule fix), `fix` publishes admitted rule fixes at original coordinates.
  `format --check` and `diff` are the non-writing previews.
- Rule selection is a projection over canonical results. It must not enter execution strategy or
  result-cache identity.
- `LeanFmt.Project` owns complete non-`.lake` source selection, exact Lake setup, and one shared typed
  no-build graph. Do not replace it with per-file Lake runs or module-only selection.
- Path errors name the caller's own argument, as `selected file does not exist: <arg>` does. New
  path-taking CLI surface — ranges, LSP URIs, integration entry points — pre-checks and does the same.
- A current ordinary `.olean` is successful-compilation evidence for source-tier rules, not a
  serialized syntax projection. Syntax-tier rules need the compiler artifact or the exact frontend.
- A rule's tier is its `RuleImpl` constructor, never a field; a declared tier field goes unenforced
  and rots.
- The module artifact holds the projection and nothing else — facts, never findings. Rules run outside
  the compiler, from those facts, in the process that reports them. `LeanFmt.Rules` is absent from both
  `LeanFmt/CompilerPlugin.lean`'s imports and `lean_lib LeanFmtCompilerPlugin`'s globs, and both
  absences matter: Lake links every module a library globs, imported or not. When the rules were
  reachable, editing one rule's message string invalidated every integrated module's Lake trace. See
  `docs/adding-a-rule.md`.
- Size the module artifact per element, not per source byte: about 25 B × (tokens + nodes), stored in
  the `.olean` at that size. On the frozen mathlib sample the artifact runs 10.26× the source, 660 KB
  for the largest module. The ratio tracks token density, which varies 16×, so a small source need not
  mean a small artifact.
- Every compiler-produced offset and digest indexes the normalized source, `raw.crlfToLf`, because
  `Parser.mkInputContext` normalizes before it assigns any position. Projections, rule findings, and
  artifact identity share that one coordinate system; a module linter sees already-normalized text and
  never the raw bytes. Only file read and publish touch raw bytes, through
  `LosslessSource.normalize`/`denormalize`. Digesting raw bytes against a compiler-produced identity
  compares two different strings.
- A `Syntax` leaf walk is not a linear cover of the source. A `choice` node holds several parses of one
  byte range, so only one alternative spells those bytes; walking all of them reads the tokens out of
  order. Terminal commands (`eoi`, `#exit`) never appear in the command stream, so the region a
  projection models ends where the terminal *begins*, and the rest is verbatim tail. Both matter on
  ordinary files, not just edge cases: `choice` hit 1 of 5 sampled mathlib modules, and `#exit` every
  file that contains it.
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a
  public descriptor, not authority by type alone; recompute its content hash and match the module and
  the full source snapshot. Filesystem presence or a raw path is not build validity.
- `LeanFmt.Service` owns only private NDJSON framing, normalized path/version state, and capacity-one
  FIFO sequencing. Unsaved bytes share `Application.ExactRun` with batch fallback, never disk-state
  evidence or persistent cache entries, and every request gets a fresh bounded child.
- Do not repeatedly run full mathlib during development. Prompt 10 uses the frozen sample and named
  stress cases; save the 8,795-file run for a plausible late candidate.
