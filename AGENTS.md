# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project using Lean's private-by-default module system.
All compiled production, entry-point, test, and fixture sources begin with `module`; only executable
`lakefile.lean` configuration is exempt. The product now has one private intent-to-report operation,
an aggregate atomic semantic-result cache, preview/fix modes, and read-only compiler-integration
audit, plus a capacity-one exact editor service. A compiler plugin persists a silent formatter record
in the successful module `.olean`, and a
Lake module facet owns supported extraction into a compact content-addressed sidecar. The application
consumes that registered facet through one private no-build Lake operation only when a selected rule
needs syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate
decomposition. Architecture work is governed by `docs/projects/execution-core-v2/` and its recorded
measurements.

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
```

Use the target project's exact Lean toolchain for frontend/plugin experiments. Keep experiments out
of production modules until their owning prompt selects and verifies the interface.

## Design constraints

- Prefer pure Lean. Add another language only for a named capability or measured performance gain
  unavailable in Lean.
- Preserve exact ordered imports, search-path precedence, syntax effects, and validation identity.
- Do not call superset parsing exact.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as
  distinct workloads.
- Stop memory experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Keep public API minimal; favor private deep modules that hide lifecycle and cache sequencing.
- Keep CLI parsing/rendering in `LeanFmt.Cli`; semantic execution, validation, stale checking, and
  publication belong to `LeanFmt.Application` and its lower capabilities.
- `check`, `format`, and `diff` never write source. `fix` publishes only a complete conflict-free
  patch validated under the exact module setup, after a stale-source check.
- Rule selection is a projection over canonical results and must not enter execution strategy or
  result-cache identity.
- `LeanFmt.Project` owns complete non-`.lake` source selection, exact Lake setup, and one shared
  typed no-build graph. Do not replace it with per-file Lake runs or module-only selection.
- Path-selection errors name the caller's own argument, not a resolver's partially-resolved buffer.
  A missing selected file throws `selected file does not exist: <arg>` (beside its outside-root and
  not-a-Lean-source siblings), so a whole file list accidentally passed as one path — an unquoted shell
  variable under a non-splitting shell like zsh — is legible on sight rather than a mangled absolutized
  string. New CLI surface that takes paths (ranges, LSP document URIs, integration entry points)
  follows the same rule: pre-check and report what the caller wrote.
- A current ordinary `.olean` is successful-compilation evidence for source-tier rules, not a
  serialized syntax projection. Syntax-tier rules require the compiler artifact or exact frontend.
- A rule's tier is its `RuleImpl` constructor, never a field. The field that used to declare it was a
  claim no code had to honor and was wrong for the product's whole life without anything noticing.
- The module artifact carries the projection and nothing else — facts, never findings. Rules run
  outside the compiler, from those facts, in the process that reports them. `LeanFmt.Rules` is
  reachable from neither `LeanFmt/CompilerPlugin.lean`'s imports nor `lean_lib
  LeanFmtCompilerPlugin`'s globs, and both halves are load-bearing: Lake links every module a library
  globs whether or not anything imports it. While the rules were reachable, editing one rule's message
  string invalidated every integrated module's Lake trace. See `docs/adding-a-rule.md`.
- Size the module artifact per element, not per source byte: it costs about 25 B x (tokens + nodes)
  and lands in the `.olean` at its own size. Measured over the frozen mathlib sample that is 10.26x
  the source, 660 KB for the largest module there. Ratio against source tracks token density, which
  varies 16x, so a small source does not imply a small artifact.
- Every compiler-produced offset and digest indexes the normalized source, `raw.crlfToLf`, because
  `Parser.mkInputContext` normalizes before assigning any position. Projections, rule findings, and
  artifact identity share that one coordinate system; a module linter is handed already-normalized
  text and cannot observe the file's bytes at all. Only reading a file and publishing one may touch
  raw bytes, via `LosslessSource.normalize`/`denormalize`. Digesting raw bytes against a
  compiler-produced identity compares two different strings.
- A `Syntax` leaf walk is not a linear cover of the source. A `choice` node holds several parses of
  one byte range, so exactly one alternative may spell those bytes; walking all of them runs the
  token stream backwards. Terminal commands (`eoi`, `#exit`) are never in the command stream, so the
  region a projection models ends where the terminal *begins*, and everything from there is
  verbatim tail. Both rules are load-bearing on ordinary files, not edge cases: measured incidence
  is 1 of 5 sampled mathlib modules for `choice`, and every file containing `#exit` for the other.
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a
  public descriptor, not authority by type alone; recompute its content hash and match module and
  the full source snapshot. Filesystem presence or a raw path is not build validity.
- `LeanFmt.Service` owns only private NDJSON framing, normalized path/version state, and capacity-one
  FIFO sequencing. Unsaved bytes share `Application.ExactRun` with batch fallback, never disk-state
  evidence or persistent cache entries, and every request receives a fresh bounded child.
- Do not repeatedly run full mathlib during development. Prompt 10 uses the frozen sample and named
  stress cases; the 8,795-file run is reserved for a plausible late candidate.
