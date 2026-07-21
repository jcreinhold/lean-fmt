# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project on Lean's private-by-default module system. Every
compiled production, entry-point, test, and fixture source begins with `module`; only the
`lakefile.lean` is exempt. The product has one private intent-to-report operation, an atomic aggregate
semantic-result cache, preview/fix modes, read-only compiler-integration audit, and a language
server. A compiler plugin writes a silent formatter record into the successful module `.olean`; a Lake module facet extracts it into a compact content-addressed sidecar. The application
reads that facet through one private no-build Lake operation, and only when a selected rule needs
syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate
split. `docs/projects/execution-core-v2/` and its measurements govern architecture work.

## Directory guides

Read the nearest guide before working in a directory. A guide may add rules. It may not contradict
this file.

- `LeanFmt/AGENTS.md` for writing Lean;
- `docs/projects/AGENTS.md` for prompt stacks.

## Build and checks

```sh
lake build           # also builds LeanFmtCacheSpec; a broken proof fails the build
lake exe lean-fmt
lake exe lean-fmt-tests
lake lint            # the formatter on itself, under lean-fmt.toml; this is what CI runs
```

Suites live in `tests/*/run.sh`: boundary, cache, catalog, check, compiler, discovery, downstream,
imports, layout, lossless, modes, printer, reporting, scale, semantic, stream, suppression, syntax,
watch.

Match the checks to the change:

- While working, build the modules you touched and read every error.
- Run the suites that cover what you changed.
- Before handoff, run `lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every suite.
- `lean-fmt.toml` is this repository's own discovered configuration, and `lake lint` runs the
  formatter under it with no `--config`. Its `exclude` list keeps the fixture trees out; anything
  absent from that list is linted, so a new directory is covered until someone says otherwise.
- `tests/security/bench.sh` measures the linear-time claim. It is a benchmark, not a suite. Run it
  when you touch the source scans, and record the numbers.
- `tests/watch/run.sh` §9.6 runs `check --staged` against *this* repository, so it fails whenever a
  `.lean` file is staged. That is a defect in the suite, not in your change; re-run it with a clean
  index. `ruff-20-acceptance` owns the repair (move the assertion to a fixture repository).
- `tests/lsp/acceptance.sh` drives the language server with the toolchain's own LSP client
  (`Lean.Data.Lsp.Ipc`) and measures cancellation latency and hundred-request memory stability. It
  costs about 90 s, so it is not in the `tests/*/run.sh` sweep. Run it when you touch
  `LeanFmt/LanguageServer.lean`, and record the numbers.
- `tests/lsp/editor.sh` drives the same server with Neovim's own LSP client, through the stanza
  `docs/editor-setup.md` hands users. It needs Neovim 0.11 or newer and skips without it, so it is
  also outside the sweep. Run it when you touch `LeanFmt/LanguageServer.lean` or the editor setup.

Use the target project's exact Lean toolchain for frontend and plugin experiments. Keep experiments
out of production modules until their owning prompt selects and verifies the interface.

## Which record wins

- Built code decides what the product does. No record outranks it.
- `results/` freezes a decision a prompt made, with its evidence. Amend it; do not work around it.
- `evidence/` and `notes/` are working material. They support a result. They do not stand in for one.
- `state/current.md` records where a stack stopped and what is unfinished. It does not overrule code
  or a result.
- `roadmap.md` orders the work. It does not report status.

If code contradicts a result, reopen the stack that owns the result. Do not patch around it. If two
records disagree, write down the disagreement and how you settled it.

## Stack order

The number sets the step: finish every stack at a lower number before starting a higher one. A letter
suffix marks a stack opened against an earlier one, and it runs after the stack it amends.

## Design constraints

### Scope and language

- Prefer pure Lean. Add another language only for a named capability or a measured speed gain Lean
  cannot reach.

### What the commands do

- `check` and `diff` never write source. `format` and `fix` publish only a complete, conflict-free
  result validated under the exact module setup, after a stale-source check: `format` publishes the
  canonical layout (no rule fix), `fix` publishes admitted rule fixes at original coordinates.
  `format --check` and `diff` are the non-writing previews.
- Path errors name the caller's own argument, as `selected file does not exist: <arg>` does. New
  path-taking CLI surface — ranges, LSP URIs, integration entry points — pre-checks and does the same.
- Rule selection is a projection over canonical results. It must not enter execution strategy or
  result-cache identity.

### Module ownership

- Prefer private deep modules that hide lifecycle and cache sequencing.
- Keep CLI parsing and rendering in `LeanFmt.Cli`; semantic execution, validation, stale checking, and
  publication belong to `LeanFmt.Application` and its lower capabilities.
- `LeanFmt.Project` owns complete non-`.lake` source selection, exact Lake setup, and one shared typed
  no-build graph. Do not replace it with per-file Lake runs or module-only selection.
- `LeanFmt.LanguageServer` owns only the protocol: JSON-RPC framing, clamped client coordinates,
  document lifetime, and when to analyze. Unsaved bytes share `Application.ExactRun` with batch
  fallback, never disk-state evidence or persistent cache entries, and every request gets a fresh
  bounded child.

### Exactness and coordinates

- Preserve exact ordered imports, search-path precedence, syntax effects, and validation identity.
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

### The module artifact and rule tiers

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
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a
  public descriptor, not authority by type alone; recompute its content hash and match the module and
  the full source snapshot. Filesystem presence or a raw path is not build validity.

### Measurement practice

- Do not call superset parsing exact. Say which of the four workloads a speed number came from. A
  passing test is not a measurement. Keep measured results apart from expected ones, and run the
  cheap check before you record either.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as
  distinct workloads.
- Stop memory experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Do not repeatedly run full mathlib during development. Prompt 10 uses the frozen sample and named
  stress cases; save the 8,795-file run for a plausible late candidate.

## Sharing this worktree

An agent may start subagents that edit this worktree at the same time. Keep changes you did not make.

- Do not use `git stash`.
- Do not revert another session's files.
- Commit with explicit pathspecs. Do not use a bare `git commit` or `git commit -a`.
- Do not run a command that rewrites shared state: no `git reset --hard`, no `git checkout .`, no
  force push, no branch switch.
- Scope diffs and builds to your own change to tell whether a failure predates it.
