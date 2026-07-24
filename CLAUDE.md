# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library
modules live under `LeanFmt`.

## Current state

The production tree is a native `lake init` project on Lean's private-by-default module system. Every
compiled production, entry-point, test, and fixture source opens with `module` as its first token —
a copyright block or other comment may precede it, exactly as Lean allows; only the `lakefile.lean` is
exempt. The product has one private intent-to-report operation, an atomic aggregate
semantic-result cache, preview/fix modes, read-only compiler-integration audit, and a language
server. A compiler plugin writes a silent formatter record into the successful module `.olean`; a Lake module facet extracts it into a compact content-addressed sidecar. The application
reads that facet through one private no-build Lake operation, and only when a selected rule needs
syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate
split.

## Directory guides

Read the nearest guide before working in a directory. A guide may add rules. It may not contradict
this file.

- `LeanFmt/AGENTS.md` for writing Lean.

## Build and checks

```sh
lake build           # also builds LeanFmtCacheSpec; a broken proof fails the build
lake exe lean-fmt
lake exe lean-fmt-tests
lake lint            # the formatter on itself, under lean-fmt.toml; this is what CI runs
```

Suites live in `tests/*/run.sh`. Enumerate them, do not read them off a list — this one named 20 of
36 for long enough that `tests/lsp/run.sh` went unrun and stayed red through three prompts. All 37:
application-formatter, block-formatter, boundary, cache, catalog, check, ci, collection-formatter,
command-formatter, comments, compiler, core-surface, declaration-formatter, discovery, downstream,
format-suppression, formatter, formatter-adapter, imports, incremental, layout, lossless, lsp, modes,
module-formatter, native-layout, performance, reporting, scale, semantic, stream, style, suppression,
syntax, term-formatter, validator, watch.

`tests/lsp/run.sh` is the ordinary suite and belongs in the sweep; `tests/lsp/acceptance.sh` and
`tests/lsp/editor.sh` are the two costly ones described below and do not.

Match the checks to the change:

- While working, build the modules you touched and read every error.
- Run the suites that cover what you changed.
- Before handoff, run `lake build`, `lake lint`, `lake exe lean-fmt-tests`, and every suite.
- `lean-fmt.toml` is this repository's own discovered configuration, and `lake lint` runs the
  formatter under it with no `--config`. Its `exclude` list keeps the fixture trees out; anything
  absent from that list is linted, so a new directory is covered until someone says otherwise.
- `tests/performance/run.sh` is the durable performance gate. It asserts **counts, ratios, and
  digests only** -- never a wall time, because the same binary over the same warm corpus measured
  3,977 ms and 19,968 ms depending only on machine load. It primes its own cache in-run, so it does
  not care that editing any `LeanFmt/*.lean` renames the index. Its §0 runs `negative.sh`, which
  proves each gate can fail before the suite reports that none did. Add a gate here when you
  optimize something, and state it as a quantity that does not move when the machine gets slower.
- `tests/security/bench.sh` measures the linear-time claim. It is a benchmark, not a suite. Run it
  when you touch the source scans, and record the numbers.
- `tests/ci/run.sh` gates `docs/ci.md`: it builds a consuming project that takes lean-fmt as a git
  dependency and runs all four published recipes, the cache instruction, and a `git archive` install.
  It costs about 90 s because it clones and builds the dependency twice. It reads **committed** state
  only — a `file://` clone at `HEAD` and `git archive` — so commit before running it, or it tests the
  previous commit and passes while your change is broken. Run it when you touch `docs/ci.md`, the
  reporting formats, changed-file selection, or cache identity.
- `tests/watch/run.sh` §9.6 runs `check --staged` against *this* repository, so it fails whenever a
  `.lean` file is staged. That is a defect in the suite, not in your change; re-run it with a clean
  index. `ruff-20-acceptance` owns the repair (move the assertion to a fixture repository).
- `tests/stream/run.sh` is the sweep's longest suite at about 7.5 minutes, and nearly all of that is
  one check: it streams a 20,001-declaration buffer into a reader that exits, and the
  `__analyze-exact` child it spawns runs several minutes at full CPU and reaches about 4.6 GiB RSS.
  The suite hands that child an 8 GiB limit deliberately. A single suite pinned at 100% CPU with
  multi-GiB RSS is this working, not a runaway — measured twice, 2026-07-24. Do not kill it, and do
  not read the aggregate-RSS stop rule for memory *experiments* as covering it.
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

The prompt stacks that built this product (`docs/projects/`) were deleted once it shipped. What
remains is the record, in this order:

- Built code decides what the product does. No record outranks it.
- A suite under `tests/` decides whether a behaviour is intended. A test asserting something is the
  strongest surviving statement that it was chosen rather than stumbled into.
- Module docstrings in `LeanFmt/` carry the reasoning — why a shape was picked and what was rejected.
  They are prose and can rot; when one contradicts the code, the code wins and the docstring is wrong.
- `docs/` is the user-facing contract. `docs/ci.md` and `docs/adding-a-rule.md` are gated by suites;
  the rest is not.
- Committed evidence under `experiments/evidence/` is a measurement
  with a date, not a decision. Regenerate it rather than arguing with it.

If two records disagree, write down the disagreement and how you settled it. The design rationale that
is *not* recoverable from code or tests is gone with the stacks — when you cannot find why something is
the way it is, say so rather than inventing a reason.

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

### Lean's pretty-printer is a printer, not a re-printer

Lean ships both endpoints of the layout/fidelity axis and nothing in between. `Lean.Syntax.reprint`
(`Lean/Syntax.lean:400`) emits `lead ++ val ++ trail` from each leaf's `SourceInfo`: exact source bytes,
zero layout decisions. `Lean.PrettyPrinter` renders syntax the *elaborator* produced, for error
messages, `#print`, and infoview hovers: every layout decision, no source fidelity — there is no
original to be faithful to and nobody can diff the output against source.

A formatter is the missing third row: full layout *and* exact fidelity.
`LeanFmt/Formatter/NativeLayout.lean` is that row written out by hand, and most difficulty in it is a
guarantee a printer has no reason to make. Each one already costs a mechanism there. Before adding a
new mechanism, decide which of these you are paying for; if it is none of them, you have found a
ninth and it goes in this list.

- **It can silently drop a leaf.** The combinators backtrack, so a subtree the formatter cannot format
  is omitted rather than reported. `dbg_trace s!"…"` with the interpolated string replaced by a marker
  formats to `grp[nest2[T"dbg_trace"]]` — no marker, no `line`, no diagnostic. A missing marker in the
  native document is expected; the adapter owns what surrounds a dropped island, including the
  separator, because the document holds no decision about a leaf it never emitted.
- **Failure is unstructured when it does escape.** The same mismatch inside `` `(…) `` surfaces as the
  bare string `uncaught backtrack exception`: no node, no range, no expected shape.
- **There is no leaf-to-source correspondence.** `withMaybeTag` tags with `getExprPos?`, populated for
  delaborated syntax and not for syntax parsed from source, so a parsed command yields zero
  `Format.tag` nodes. Correspondence is positional; a divergence is a refusal, not a lookup.
- **Parser-significant columns are not in the document.** See the `align`/`sepByIndent` note under
  *Exactness and coordinates* below and in the module docstring.
- **A parser-significant column cannot be expressed even where it is known.** The one above is that the
  document does not say which columns matter; this is that knowing one does not help. `nest n` is
  relative to the current *indent* and `align force` pads *to* that indent, so no constructor means
  "indent this subtree's continuations to the column where it starts" — which is what `many1Indent`
  saves and `checkColGe` measures against. A break that has to land at such a column cannot be *placed*,
  so `collectGuardBailouts`/`flattenNative` *remove* it instead, under a source precondition that makes
  removal total. Refuse rather than emit a break you cannot position.
- **Comments are not in the algebra**, there is **no verbatim leaf** (`Format.text` re-indents embedded
  newlines), and there is **no protocol for source-sensitive syntax** — hence trivia stripping, the
  cancelling `nest`, and marker substitution respectively.
- One ordinary upstream bug: `def ctor` puts the newline inside the `"\n| "` atom *after*
  `optional docComment`, so a constructor docstring renders as `where/-- doc -/` and reparses onto the
  wrong owner.

Do not reimplement what Lean does do. `pushToken` inserts a discretionary space exactly when
concatenation would re-lex as one token, using the real tokenizer; an adapter-side merge rule
over-fires. Read `format.indent` through `Lean.Std.Format.getIndent`, never as a literal `2`. And
`reprint` handles `choice` by reprinting every alternative and checking they agree, where
`terminalsFrom` takes `children[0]?` — lean-fmt currently *assumes* what `reprint` *verifies*, on a
node CLAUDE.md records hitting 1 of 5 sampled mathlib modules.

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
