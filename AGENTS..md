# lean-fmt

`lean-fmt` is a native Lean 4 application. The package and executable are named `lean-fmt`; library modules live under
`LeanFmt`.

## Current state

The production tree is a native `lake init` project on Lean's private-by-default module system. Every compiled
production, entry-point, test, and fixture source opens with `module` as its first token — a comment block may precede
it; only `lakefile.lean` is exempt. The product has one private intent-to-report operation, an atomic aggregate
semantic-result cache, preview/fix modes, a read-only compiler-integration audit, and a language server. A compiler
plugin writes a silent formatter record into the successful module `.olean`; a Lake module facet extracts it into a
compact content-addressed sidecar. The application reads that facet through one private no-build Lake operation, and
only when a selected rule needs syntax.

Do not restore the archived Rust workspace, worker protocol, `libleanshared` boundary, or seven-crate split.

## Directory guides

Read the nearest guide before working in a directory. A guide may add rules. It may not contradict this file.

- `LeanFmt/AGENTS.md` for writing Lean.

## Build and checks

```sh
lake build           # also builds LeanFmtCacheSpec; a broken proof fails the build
lake exe lean-fmt
lake exe lean-fmt-tests
lake test            # the unit tier plus every non-slow suite; CI runs this
lake test -- --all   # everything, including the slow suites
lake test -- --suites modes watch   # exactly these suites, slow or not
lake lint            # the formatter on itself, under lean-fmt.toml
```

Suites are compiled Lean executables: `tests/Suites/<Name>.lean` builds as `suite-<name>`, and
`tests/Test/Runner.lean`'s registry enumerates them with their lane. Enumerate the registry, not a list in prose — an
unregistered suite file fails the boundary suite's entry-point pin. The current set: application-formatter,
block-formatter, boundary, cache, catalog, check, ci, collection-formatter, command-formatter, comments, compiler,
declaration-formatter, discovery, downstream, editor, format-suppression, formatter, formatter-adapter, imports,
incremental, layout, lossless, lsp, lsp-acceptance, modes, module-formatter, native-layout, performance, reporting,
scale, security-bench, semantic, stream, style, suppression, syntax, term-formatter, validator, watch.

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
- The slow tag exists for minutes-long suites: stream, performance, downstream, ci, lsp-acceptance, editor,
  security-bench. They run under `--all`, under `--suites`, and in the `workflow_dispatch` CI job.
- `performance` is the durable performance gate: **counts, ratios, and digests only**, never a wall time, because the
  same binary over the same warm corpus measured 3,977 ms and 19,968 ms depending only on machine load. Its
  gates-discriminate case feeds every gate input it must accept and input it must reject. Add a gate there when you
  optimize something, stated as a quantity that does not move when the machine gets slower.
- `ci` gates `docs/ci.md` and reads **committed** state only — a `file://` clone at `HEAD` and `git archive` — so commit
  before running it, or it tests the previous commit and passes while your change is broken.
- `watch`'s staged-empty case runs `check --staged` against *this* repository, so it fails whenever a `.lean` file is
  staged. Re-run it with a clean index.
- Two suites keep foreign adversaries on purpose: `validator` and `formatter` pipe through
  `tests/formatter/candidate.py`, `style` through `tests/style/expected_candidate.py`, and `editor` drives
  `tests/lsp/editor.lua` — the real `vim.lsp`, not a Lean model of it. Do not port those.

Use the target project's exact Lean toolchain for frontend and plugin experiments. Keep experiments out of production
modules until their interface is selected and verified.

## Which record wins

When records disagree, this is the order of authority:

- Built code decides what the product does. No record outranks it.
- A suite under `tests/` decides whether a behaviour is intended. A test asserting something is the strongest surviving
  statement that it was chosen rather than stumbled into.
- Module docstrings in `LeanFmt/` carry the reasoning — why a shape was picked and what was rejected. They are prose and
  can rot; when one contradicts the code, the code wins and the docstring is wrong.
- `docs/` is the user-facing contract. `docs/ci.md` and `docs/adding-a-rule.md` are gated by suites; the rest is not.
- A measurement has a date, not authority — regenerate rather than argue.

If two records disagree, write down the disagreement and how you settled it. Design rationale that is not recoverable
from code or tests is gone — when you cannot find why something is the way it is, say so rather than inventing a reason.

## Design constraints

### Scope and language

- Prefer pure Lean. Add another language only for a named capability or a measured speed gain Lean cannot reach.

### What the commands do

- `check` and `diff` never write source. `format` and `fix` publish only a complete, conflict-free result validated
  under the exact module setup, after a stale-source check: `format` publishes the canonical layout (no rule fix), `fix`
  publishes admitted rule fixes at original coordinates. `format --check` and `diff` are the non-writing previews.
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
  the rest is verbatim tail. Both matter on ordinary files, not just edge cases: `choice` hit 1 of 5 sampled mathlib
  modules, and `#exit` every file that contains it.

### Lean's pretty-printer is a printer, not a re-printer

Lean ships both endpoints of the layout/fidelity axis and nothing in between. `Lean.Syntax.reprint`
(`Lean/Syntax.lean:400`) emits `lead ++ val ++ trail` from each leaf's `SourceInfo`: exact source bytes, zero layout
decisions. `Lean.PrettyPrinter` renders syntax the *elaborator* produced, for error messages, `#print`, and infoview
hovers: every layout decision, no source fidelity — there is no original to be faithful to and nobody can diff the
output against source.

A formatter is the missing third row: full layout *and* exact fidelity. `LeanFmt/Formatter/NativeLayout.lean` is that
row written out by hand, and most difficulty in it is a guarantee a printer has no reason to make. Each one already
costs a mechanism there. Before adding a new mechanism, decide which of these you are paying for; if it is none of them,
you have found a ninth and it goes in this list.

- **It can silently drop a leaf.** The combinators backtrack, so a subtree the formatter cannot format is omitted rather
  than reported. `dbg_trace s!"…"` with the interpolated string replaced by a marker formats to
  `grp[nest2[T"dbg_trace"]]` — no marker, no `line`, no diagnostic. A missing marker in the native document is expected;
  the adapter owns what surrounds a dropped island, including the separator, because the document holds no decision
  about a leaf it never emitted.
- **Failure is unstructured when it does escape.** The same mismatch inside `` `(…) `` surfaces as the bare string
  `uncaught backtrack exception`: no node, no range, no expected shape.
- **There is no leaf-to-source correspondence.** `withMaybeTag` tags with `getExprPos?`, populated for delaborated
  syntax and not for syntax parsed from source, so a parsed command yields zero `Format.tag` nodes. Correspondence is
  positional; a divergence is a refusal, not a lookup.
- **Parser-significant columns are not in the document.** See the `align`/`sepByIndent` note under *Exactness and
  coordinates* above and in the module docstring.
- **A parser-significant column cannot be expressed even where it is known.** The note above says the document does not
  say which columns matter; this one says knowing one does not help. `nest n` is relative to the current *indent* and
  `align force` pads *to* that indent, so no constructor means "indent this subtree's continuations to the column where
  it starts" — which is what `many1Indent` saves and `checkColGe` measures against. A break that has to land at such a
  column cannot be *placed*, so `collectGuardBailouts`/`flattenNative` *remove* it instead, under a source precondition
  that makes removal total. Refuse rather than emit a break you cannot position.
- **Comments are not in the algebra**, there is **no verbatim leaf** (`Format.text` re-indents embedded newlines), and
  there is **no protocol for source-sensitive syntax** — hence trivia stripping, the cancelling `nest`, and marker
  substitution respectively.
- **Output nobody can see is not output to a printer.** A `line` in front of a `text` carrying its own newline is a
  space at the end of a line when its group flattens and a blank line when it does not. Lean's `doIf` spells one before
  every indented `doSeq` body. It costs a printer nothing — a trailing space is invisible in an error message and a
  re-print is never diffed against source — so nothing upstream removes it and no gate here would catch it: the
  validator reparses, and a space before a newline changes no token. A formatter's output is read as text, so the
  adapter drops the break, and only the one *in front of* the newline. The mirror rule moves columns: `sepByIndent`
  spells its first item after an `align` and the rest after a `text "\n"`.
- Ordinary upstream bugs, each repaired against the mechanism rather than the parser: `def ctor` puts the newline inside
  the `"\n| "` atom *after* `optional docComment`, so a constructor docstring renders as `where/-- doc -/` and reparses
  onto the wrong owner; `parserOfStack.formatter` reads one stack slot short of the `ident`, so `` `(cat| body) `` dies
  as ``Unknown constant «|»``; `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has.

Do not reimplement what Lean does do. `pushToken` inserts a discretionary space exactly when concatenation would re-lex
as one token, using the real tokenizer; an adapter-side merge rule over-fires. Read `format.indent` through
`Lean.Std.Format.getIndent`, never as a literal `2`. And `reprint` handles `choice` by reprinting every alternative and
checking they agree. Four walks in `NativeLayout.lean` take `children[0]?` and would each *assume* it — `terminalsFrom`,
`selectedLeafRanges`, `containsAtom`, `collectRecordUpdateFieldStarts` — so one gate at `NativeLayout.command` compares
every alternative's ordered `(range, sourceSpelling)` sequence and refuses with the node and range named, making the
assumption true for all four rather than repeating the comparison. Do the same for a fifth walk: verify once at the
entry point, not per walk. The handwritten `Formatter.Command` header path still assumes, and is the remaining place it
is unchecked.

### The module artifact and rule tiers

- A current ordinary `.olean` is successful-compilation evidence for source-tier rules, not a serialized syntax
  projection. Syntax-tier rules need the compiler artifact or the exact frontend.
- A rule's tier is its `RuleImpl` constructor, never a field; a declared tier field goes unenforced and rots.
- The module artifact holds the projection and nothing else — facts, never findings. Rules run outside the compiler,
  from those facts, in the process that reports them. `LeanFmt.Rules` is absent from both
  `LeanFmt/CompilerPlugin.lean`'s imports and `lean_lib LeanFmtCompilerPlugin`'s globs, and both absences matter: Lake
  links every module a library globs, imported or not. When the rules were reachable, editing one rule's message string
  invalidated every integrated module's Lake trace. See `docs/adding-a-rule.md`.
- Size the module artifact per element, not per source byte: about 25 B × (tokens + nodes), stored in the `.olean` at
  that size. On the frozen mathlib sample the artifact runs 10.26× the source, 660 KB for the largest module. The ratio
  tracks token density, which varies 16×, so a small source need not mean a small artifact.
- Fetch and consume `leanFmtArtifact` inside one private Lake-owning operation. `Lake.Artifact` is a public descriptor,
  not authority by type alone; recompute its content hash and match the module and the full source snapshot. Filesystem
  presence or a raw path is not build validity.

### Measurement practice

- Do not call superset parsing exact. Say which of the four workloads a speed number came from. A passing test is not a
  measurement. Keep measured results apart from expected ones, and run the cheap check before you record either.
- Treat formatter-cache cold, ordinary-project-built, formatter-integrated-built, and cache-warm as distinct workloads.
- Stop memory experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Do not repeatedly run full mathlib during development. Use the frozen sample and named stress cases; save the
  8,795-file run for a plausible late candidate.

## Sharing this worktree

An agent may start subagents that edit this worktree at the same time. Keep changes you did not make.

- Do not use `git stash`.
- Do not revert another session's files.
- Commit with explicit pathspecs. Do not use a bare `git commit` or `git commit -a`.
- Do not run a command that rewrites shared state: no `git reset --hard`, no `git checkout .`, no force push, no branch
  switch.
- Scope diffs and builds to your own change to tell whether a failure predates it.
