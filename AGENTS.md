# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library modules live under
`LeanFmt`.

## Current state

The production tree is a native `lake init` project on Lean's private-by-default module system. Every compiled
production, entry-point, test, and fixture source opens with `module` as its first token — a comment block may precede
it; only `lakefile.lean` is exempt. The product has one private intent-to-report operation, an atomic aggregate
semantic-result cache, preview/fix modes, and a language server. A compiler plugin writes a silent formatter record into
the successful module `.olean`; a Lake module facet extracts it into a compact content-addressed sidecar. The
application reads that facet through one private no-build Lake operation, and only when a selected rule needs syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate split, or the
`compiler status` audit — it reported coverage and bought no speed, and `compiler build` fails loudly on the one
condition it used to warn about.

## Directory guides

Read the nearest guide before working in a directory. A guide may add rules. It may not contradict this file.

- `LeanFmt/AGENTS.md` for writing Lean.
- `LeanFmt/Formatter/AGENTS.md` for the layout adapter, and what Lean's pretty-printer will not do for you.

Three procedures are codified as skills in `.claude/skills`, symlinked into `.agents/skills` so a harness that reads
neither path by default still finds them: `bump-toolchain` (moving `lean-toolchain`, and answering a red
`next-toolchain` probe), `release-lean-fmt` (version, CHANGELOG, tag — publishing happens only in CI), and `verso-docs`
(the `docs/manual` package). Read the skill before improvising one of these.

## Build and checks

```sh
lake build           # also builds LeanFmtCacheSpec; a broken proof fails the build
lake exe lean-fmt
lake exe lean-fmt-tests
lake test            # the unit tier plus every non-slow suite
lake test -- --all   # everything, including the slow suites
lake test -- --suites modes watch   # exactly these suites, slow or not
lake lint            # the formatter on itself, under lean-fmt.toml
```

`lake` is the build system; the `Makefile` is the conventional front end (`make build`, `make test`) plus the GNU
installer. It carries one thing lake does not: `make test-linux` archives `HEAD` plus your dirty files into an Ubuntu
22.04 container and runs the suites there, with cached elan and lake volumes so repeats are minutes. The 22.04 userland
is where platform-shaped failures surface (mtime granularity, cache-epoch contamination) and it is what the
release legs run. First repro for any failure that smells platform-dependent.

`docs/manual` is a second Lake package, holding the Verso manual published to GitHub Pages by
`.github/workflows/pages.yml`. None of the commands above touch it: it requires Verso, and the
`lean-fmt` package requires nothing, because cache identity folds the ordered Lake environment and a
dependency there would invalidate every entry whenever its pin moved. Build it with `lake exe docs`
from that directory. Its `lean-toolchain` and its `verso` rev must equal the root `lean-toolchain`,
and the Pages workflow fails when they do not — a bump that moves only the root leaves the manual
documenting a compiler the code no longer uses.

Suites are compiled Lean executables: `tests/Suites/<Name>.lean` builds as `suite-<name>`, and
`tests/Test/Runner.lean`'s registry enumerates them with their lane. Read the registry, not a list in prose — an
unregistered suite file fails the boundary suite's entry-point pin. `lake test -- --list` prints every suite with its
lane and slow tag.

Each suite's module docstring carries its notes: what it pins, which defect records the assertions come from, and what a
failure means. Read those first when a suite fails.

Match the checks to the change:

- While working, build the modules you touched and read every error.
- Run the suites that cover what you changed (`lake test -- --suites <name>`).
- Before handoff, run `lake build`, `lake lint`, and `lake test`; run `lake test -- --all` when you touched a slow
  suite's ground.
- `lean-fmt.toml` is this repository's own discovered configuration, and `lake lint` runs the formatter under it with no
  `--config`. Its `exclude` list keeps the fixture trees out; anything absent from that list is linted, so a new
  directory is covered until someone says otherwise.
- The slow tag marks minutes-long suites. They run under `--all`, under `--suites`, and in the `workflow_dispatch` CI
  job.
- `performance` is the durable performance gate: **counts, ratios, and digests only**, never a wall time, because one
  binary over one warm corpus varies by an order of magnitude on machine load alone — a wall time measures the load as
  much as the code. Its gates-discriminate case feeds every gate input it must accept and input it must reject. Add a
  gate there when you optimize something, stated as a quantity that does not move when the machine gets slower.
- `ci` gates `docs/ci.md` and reads **committed** state only — a `file://` clone at `HEAD` and `git archive` — so commit
  before running it, or it tests the previous commit and passes while your change is broken.
- `watch`'s staged-empty case runs `check --staged` against *this* repository, so it fails whenever a `.lean` file is
  staged. Re-run it with a clean index.
- Two suites keep foreign adversaries on purpose: `validator` and `formatter` pipe through
  `tests/fixtures/formatter/candidate.py`, `style` through `tests/fixtures/style/expected_candidate.py`, and `editor`
  drives `tests/lsp/editor.lua` — the real `vim.lsp`, not a Lean model of it. Do not port those.

CI does not run one `lake test`. `.github/workflows/ci.yml` runs `--unit-only`, then a sharded matrix of `--skip-unit
--part <n> --jobs 2` under `LEAN_NUM_THREADS=2` — four concurrent suites exhaust a 16 GB runner, and the telemetry lines
exist to name the resource when one dies. A scheduled `next-toolchain` job builds against the next Lean rc; a red probe
is the `bump-toolchain` skill's trigger, not a broken `main`.

When a run fails intermittently, read `docs/flaky-tests.md` before re-running anything. A retry on a signature that is
not already in its ledger trades a bug report for a coin flip: the evidence lives on a runner that is gone.

Use the target project's exact Lean toolchain for frontend and plugin experiments. Keep experiments out of production
modules until their interface is selected and verified.

## Which record wins

When records disagree, this is the order of authority:

- Built code decides what the product does. No record outranks it.
- A suite under `tests/` decides whether a behaviour is intended. A test asserting something is the strongest surviving
  statement that it was chosen rather than stumbled into.
- Module docstrings in `LeanFmt/` carry the reasoning — why a shape was picked and what was rejected. They are prose and
  can rot; when one contradicts the code, the code wins and the docstring is wrong.
- `docs/` is the user-facing contract, with two exceptions addressed to maintainers: `docs/toolchain-upgrade.md` and
  `docs/flaky-tests.md` bind whoever is doing the work, not a consumer. `docs/ci.md` and `docs/adding-a-rule.md` are
  gated by suites; the rest is not.
- A measurement has a date, not authority — regenerate rather than argue.

If two records disagree, write down the disagreement and how you settled it. Design rationale that is not recoverable
from code or tests is gone — when you cannot find why something is the way it is, say so rather than inventing a reason.

## Design constraints

### Scope and language

- Prefer pure Lean. Add another language only for a named capability or a measured speed gain Lean cannot reach.

### What the commands do

- `check` and `format`'s previews never write source. `format` and `check --fix` publish only a complete, conflict-free
  result validated under the exact module setup, after a stale-source check: `format` publishes the canonical layout (no
  rule fix), `check --fix` publishes admitted rule fixes at original coordinates. `format --check` and `format --diff`
  are the non-writing previews. `format --no-validate` is the one authorized exception: over an admitted syntax frontier
  it publishes on the structural candidate reparse alone, skipping the second render and `Validator.admit`; the reparse
  still runs and still refuses, the bypass is recorded per file, a bypassed analysis is never cached, and every other
  mode and every non-publishing `format` form rejects the flag.
- A command whose layout no draft can get past validation is published as its own source bytes, and the rest of the file
  formats. Detection is per command, so refusal is too: the analysis blames the failure on one command through
  `ValidationFailure.source?`, re-renders with that command forced verbatim, and tries again, at most twice. Only a
  failure no command owns — the header, the terminal tail, the source map — still takes the whole file down. Every
  degradation is counted (`verbatimCommands` on the report, `verbatim_commands` under `--statistics`, one trailer line)
  and carried typed on `AnalysisEnvelope.degradations`, because the alternative to a loud hole is a silent one.
  `LEAN_FMT_STRICT_LAYOUT=1` restores whole-file refusal so a defect stays bisectable. A drop in infrastructure failures
  matched by a rise in `verbatim_commands` has moved defects, not fixed them; read both.
- Path errors name the caller's own argument, as `selected file does not exist: <arg>` does. New path-taking CLI surface
  — ranges, LSP URIs, integration entry points — pre-checks and does the same.
- Rule selection is a projection over canonical results. It must not enter execution strategy or result-cache identity.

### Module ownership

- Prefer private deep modules that hide lifecycle and cache sequencing.
- Keep CLI parsing and rendering in `LeanFmt.Cli`; semantic execution, validation, stale checking, and publication
  belong to `LeanFmt.Application` and its lower capabilities.
- `LeanFmt.Project` owns complete non-`.lake` source selection, exact Lake setup, and one shared typed no-build graph.
  Do not replace it with per-file Lake runs or module-only selection.
- `LeanFmt.LanguageServer` owns only the protocol: JSON-RPC framing, clamped client coordinates, document lifetime, and
  when to analyze. Unsaved bytes share `Application.ExactRun` with batch fallback, never disk-state evidence or
  persistent cache entries, and every request gets a fresh bounded child.

### Exactness and coordinates

- Preserve exact ordered imports, search-path precedence, syntax effects, and validation identity.
- Every compiler-produced offset and digest indexes the normalized source, `raw.crlfToLf`, because
  `Parser.mkInputContext` normalizes before it assigns any position. Projections, rule findings, and artifact identity
  share that one coordinate system; a module linter sees already-normalized text and never the raw bytes. Only file read
  and publish touch raw bytes, through `LosslessSource.normalize`/`denormalize`. Digesting raw bytes against a
  compiler-produced identity compares two different strings.
- A `Syntax` leaf walk is not a linear cover of the source. A `choice` node holds several parses of one byte range, so
  only one alternative spells those bytes; walking all of them reads the tokens out of order. Terminal commands (`eoi`,
  `#exit`) never appear in the command stream, so the region a projection models ends where the terminal *begins*, and
  the rest is verbatim tail. Both matter on ordinary files, not just edge cases: `choice` turns up in routine mathlib
  modules, and `#exit` in every file that contains one.

### The module artifact and rule tiers

- A current ordinary `.olean` is successful-compilation evidence for source-tier rules, not a serialized syntax
  projection. Syntax-tier rules need the compiler artifact or the exact frontend.
- A rule's tier is its `RuleImpl` constructor, never a field; a declared tier field goes unenforced and rots.
- The module artifact holds the projection and nothing else — facts, never findings. Rules run outside the compiler,
  from those facts, in the process that reports them. `LeanFmt.Rules` is absent from both
  `LeanFmt/CompilerPlugin.lean`'s imports and `lean_lib LeanFmtCompilerPlugin`'s globs, and both absences matter: Lake
  links every module a library globs, imported or not. When the rules were reachable, editing one rule's message string
  invalidated every integrated module's Lake trace. See `docs/adding-a-rule.md`.
- Size the module artifact per element, not per source byte: roughly 24 B × (tokens + nodes), stored in the `.olean` at
  that size. Element density varies several-fold across a corpus, so a small source need not mean a small artifact, and
  a size predicted from source bytes will be wrong by that much. Re-fit before you rely on the coefficient.
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a public descriptor,
  not authority by type alone; recompute its content hash and match the module and the full source snapshot. Filesystem
  presence or a raw path is not build validity.

### Measurement practice

- Do not call superset parsing exact. Say which of the four workloads a speed number came from. A passing test is not a
  measurement. Keep measured results apart from expected ones, and run the cheap check before you record either.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as distinct workloads.
- Stop a memory experiment, which measures footprint, at 8 GiB aggregate RSS or abnormal pressure. A functional run,
  which asks whether the product works on a corpus, stops only on distress: free memory under 10%. A report prints at
  the end, so an early kill loses the whole run.
- Two memory readings look like footprint and are not. Summed RSS over a worker tree double-counts the same mmapped
  `.olean` pages every worker shares. And macOS grows the swap file on demand and reports the growth as *used*, so
  swap-used climbs alike whether one worker is running or four; gate on it and it stops a healthy run at any
  concurrency, which is indistinguishable from having found real pressure. Free memory is the reading that
  discriminates. Compare runs with the other two if you like; never gate on them.
- Do not repeatedly run full mathlib. Use the frozen sample and named stress cases; save the full-corpus run for a late
  candidate.
- Whole-project selection and named files are different workloads, minutes and gigabytes apart. Say which.

## Sharing this worktree

An agent may start subagents that edit this worktree at the same time. Keep changes you did not make.

- Do not use `git stash`.
- Do not revert another session's files.
- Commit with explicit pathspecs. Do not use a bare `git commit` or `git commit -a`.
- Do not run a command that rewrites shared state: no `git reset --hard`, no `git checkout .`, no force push, no branch
  switch.
- Scope diffs and builds to your own change to tell whether a failure predates it.
