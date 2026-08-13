# Changelog

**Audience: anyone running lean-fmt.**

Notable changes in each release, and what you have to do about them. Versions before 0.4.0 predate
this file; their notes are on the
[releases page](https://github.com/jcreinhold/lean-fmt/releases).

lean-fmt is pre-1.0. Breaking changes raise the minor version.

## 0.7.0 — 2026-08-13

### Upgrading

**One command lean-fmt cannot lay out no longer takes the whole file down.** Detection was already
per command; refusal was per file, so a single command Lean's pretty-printer could not spell made
the file an infrastructure failure and exit 2. That command now keeps its original bytes, the rest
of the file formats, and the exit code is whatever the rest of the run earned. A whole-project run
over mathlib4 refused 92 files this way; it now refuses none.

If your CI treated exit 2 as "this file cannot be checked", it will now see those files pass with
holes in them. The run says so three ways — a trailer line, `verbatim_commands=` under
`--statistics`, and `verbatimCommands` on the JSON report and on each file — so assert
`verbatimCommands` is `0` if you would rather they still fail. `docs/ci.md` has the shape of that
job. Only a failure no command owns — the header, the terminal tail, the source map — still exits 2.

**Two layout changes reformat code that was clean before.** Run `lean-fmt format` once after
upgrading; `check` flags both until you do.

- **A multi-item `where` body moves one column left,** onto the column the item list itself picked —
  where its own docstring sits, and where `docs/style.md` always said it goes. Every `where` clause
  with more than one binding, in every project, at every width, was one column right of it. A
  one-item clause is unchanged.
- **An empty structure instance is spelled `{}` instead of `{ }`.** This is now the
  `empty-structure-instance` setting, and the default `"compact"` is what hand-written code in the
  projects we format actually spells. Set `empty-structure-instance = "spaced"` under `[format]` to
  keep Lean's own `{ }`. Neither spelling changes how the term parses.

### Added

- **`empty-structure-instance`**, `"compact"` (default) or `"spaced"`. See `docs/configuration.md`.
- **`degradations` on the JSON report.** One entry per command that kept its original layout, with
  the 1-based `line`, the syntax `kind`, the `gate` that refused the layout, and the `detail` it
  refused with. The count says a file lost a layout; `kind` says which shape could not be spelled,
  which is what a bug report needs. JSON only — SARIF results are findings about your code, and a
  degradation is not one.
- **`docs/upstream-defects.md`**, nine Lean pretty-printer defects with toolchain-only
  reproductions, addressed to whoever files or fixes them rather than to anyone running lean-fmt.

### Fixed

- **Files a run could not format at all now format.** A whole-project run over mathlib4 (8,862
  files) is down to one. One cause was a token whose leading whitespace the parser attributed to no
  leaf at all, reached through `optBinderIdent`; `Mathlib/Tactic/Have.lean` and
  `Mathlib/Tactic/Replace.lean` were two of the eight files that failed on it.
- **A run of comments between the same two tokens stays in source order.** Ownership was decided one
  comment at a time, so a run of three could come back with the middle one hoisted above the other
  two — and a file whose commented-out `local notation` was written that way was refused whole.
- **A comment inside a region emitted verbatim no longer refuses the command.** The region's own
  bytes already spell it.
- **Commands carrying a `tok%$x` positional capture format instead of degrading.** Lean's formatter
  cannot spell one — `tokenWithAntiquot.formatter` runs the token formatter on the antiquotation
  expression, and the mismatch escapes as `uncaught backtrack exception` — so any command containing
  one kept its original layout. lean-fmt now renders the smallest enclosing node from its source
  bytes and formats the rest of the command. `%$` is idiomatic in tactic frontends
  (`with_reducible%$tk`, `using%$u`, `says%$tk`), and it is not confined to quotations:
  `by exact%$t trivial` was enough.
- **Commands carrying a `$[…]?` or `$x*` splice format instead of degrading.** lean-fmt protected
  every antiquotation splice as a verbatim island, but only `sepBy`'s splices need it — `optional`,
  `many`, and `many1` build their wrapper inside the parser they return, so Lean's formatter spells
  them correctly, and standing a placeholder in the way is what made them fail. A command spelling
  `$[: $t]?` no longer keeps its original layout for that reason.
- **`register_simp_attr`, `register_label_attr` and `register_grind_attr` lay out** instead of
  keeping their original bytes. Their parsers declare a syntax node kind that names no constant, so
  the lookup Lean's formatter does threw.
- **A `syntax` command declaring a nested element list keeps its spaces.** Two separators the
  grammar forgets made the formatted command declare a different grammar than the source did, which
  the compiler noticed and lean-fmt then degraded.
- **A file with several unspellable commands converges instead of being refused.** The validation
  gates and the reparse each reported one site per attempt, so a file with three needed more rounds
  than the retry bound allows.
- **`format-ignore-next` covers a comment written above the directive.** The protected region used
  to start at the directive itself, so an ordinary comment above it fell in a range nothing emitted.
- **A degraded command is counted once**, however many gates named it. The count was always right;
  the list a person reads carried duplicates.

## 0.6.0 — 2026-08-11

### Upgrading

**This release targets Lean `v4.34.0-rc1`.** A lean-fmt build serves one toolchain, so it will
refuse a project still on `v4.33.0` and say so. Move the project, or take the Lake dependency,
which moves it for you.

**One construct reformats: `for … in #[…] do` keeps its space.** Lean v4.34's pretty-printer no
longer drops the space between a bracketed collection and `do`
([leanprover/lean4#14389](https://github.com/leanprover/lean4/pull/14389)), so canonical layout
changes from `for x in #[1, 2, 3]do` to `for x in #[1, 2, 3] do`. Nothing else moves. Run
`lean-fmt format` once after upgrading to land the space; `check` flags it until you do.

**Integrated builds extract module artifacts correctly again.** If you use the compiler plugin,
the `leanFmtArtifact` facet could serve a stale artifact after an edit that changed only source
bytes outside the compiled interface (a comment, a proof), because Lean v4.34 moved the payload
out of the base `.olean` and the facet's rebuild trace did not follow it. It now traces the parts
that carry the payload. No action needed beyond upgrading.

### Changed

- **lean-fmt now targets Lean `v4.34.0-rc1`** instead of `v4.33.0`. The artifact facet and its
  extractor read the plugin payload from the `.olean.server` part, where v4.34's olean split put
  it, and the facet builds that part when an ordinary build has not.
- **Canonical layout of a `for` loop over a bracketed collection keeps the space before `do`,**
  matching the upstream fix. A loop over a plain identifier (`for x in xs do`) was always spaced
  and is unchanged.

## 0.5.0 — 2026-08-10

### Upgrading

**This release targets Lean `v4.33.0`.** A lean-fmt build serves one toolchain, so it will refuse a
project still on `v4.33.0-rc2` and say so. Move the project, or take the Lake dependency, which
moves it for you. Formatted output is unchanged across the two toolchains, so there is no reformat
to land first.

**If a script reads lean-fmt's stdout, read `--statistics` or `--json` instead.** The default output
no longer ends in a row of `key=value` totals. Both of those carry the same numbers and neither
changed.

### Changed

- **lean-fmt now targets Lean `v4.33.0`** instead of `v4.33.0-rc2`. One build serves one toolchain,
  so this release will refuse a project still on the release candidate: move the project to
  `v4.33.0`, or take the Lake dependency, which moves it for you. Nothing you format changes —
  canonical layout over this repository's own 105 files is byte-identical across the two.
- **The default output says what happened instead of listing counters.** A run ended in a row of
  eleven `key=value` totals; it now ends in a sentence — `6 of 128 files would be reformatted.`
  — followed by one line for each thing that needs attention, and only when it happened:
  `2 files rejected: lean-fmt could not verify its own output.` The counters gave the numbers you
  must not miss the same weight as the nine that are almost always zero. If you were parsing that
  line, `--statistics` prints exactly those fields to stderr, and `--json` carries the whole
  report; neither changed.
- `lean-fmt --version` now reports the Lean it targets as well as its own version, as
  `lean-fmt 0.4.1 (Lean 4.33.0-rc2)`. That second number is the one that decides whether a binary
  can run against your project, and it was the one you could not ask for.
- **Running outside a Lean project says so.** It used to fail with an operating-system error code
  and the path it had tried, naming neither the cause nor what to do; it now names the directory
  and points at `--root`.
- **A toolchain mismatch now names the remedy.** The message said to install lean-fmt for your
  toolchain, which is not something you can always act on — for most toolchains no such release
  exists. It now explains that one build serves one toolchain, and offers the two things that do
  work: move the project, or take the Lake dependency, which moves it for you.
- `install.sh` reports which Lean the binary it just installed is for, and warns when the
  `lean-toolchain` in the working directory disagrees — at install time rather than on first run.

### Fixed

- **A chain of command embeddings no longer drifts right.** `set_option A in set_option B in @[simp]
  theorem …` indented every embedding after the first by one level, and its body with them. Lean
  accepts the result, but mathlib's `linter.style.whitespace` reported 3,445 rows over 8,845 files
  for it. A single embedding was always correct, which is why this survived. Seven files that
  previously failed validation now format.

## 0.4.1 — 2026-08-08

Same formatter, same linter, same output as 0.4.0 — this release exists because 0.4.0's prebuilt
binaries do not. Its release build failed on two of the four platforms, both times in lean-fmt's own
test suite rather than in anything the tool does, so no tarballs were ever published. If you took
0.4.0 as a Lake dependency, nothing here changes for you and you need not move. If you wanted the
binary or the install script, use this version.

### Fixed

- The release build's macOS arm64 leg no longer hangs. A test fixture built to exhaust a small task
  pool was itself compiled with a pool sized from the machine's core count, so on a three-core
  runner it deadlocked before the test began.
- The release build's Linux x86-64 leg no longer fails at random. A test asserted that two files
  written microseconds apart carry different timestamps, which no filesystem promises; it now
  measures how far apart two writes must be to be told apart, and only fails if that is further than
  half a second.

## 0.4.0 — 2026-08-08

### Upgrading

Two things in this release need action.

**`lean-fmt diff` and `lean-fmt fix` are gone.** They are now flags on the command they belonged
to. Replace `lean-fmt diff` with `lean-fmt format --diff`, and `lean-fmt fix` with
`lean-fmt check --fix`. Nothing else about them changed — the same work runs, with the same exit
codes and the same cache behaviour.

**Formatted output moves.** Operator chains and `where` clauses lay out differently, so the first
run after upgrading will reformat files that were already clean. A project whose CI runs
`format --check` will fail until it reformats once. Run `lean-fmt format` and commit the result as
its own change, so the reformat does not hide inside a real one.

### Removed

- The `diff` and `fix` commands. Two commands now name the two workloads and a flag names what to
  do about them: `format` publishes the canonical layout, with `--check` for the status and
  `--diff` for the patch; `check` reports rule findings, with `--fix` to apply them.

### Added

- `FMT016` reports any line wider than the configured width. It is off by default, because rows
  that cannot be broken — imports, long literals, URLs, single identifiers — are the common case,
  and a rule that mostly fires on things you cannot fix is one people learn to ignore. Turn it on
  with `--select FMT016`.
- `declaration-where` chooses where `where` goes in a structure-instance declaration. The default,
  `"same-line"`, keeps it on the signature line whenever that line still fits the width;
  `"next-line"` always moves it down.
- A manual at <https://www.jcreinhold.com/lean-fmt/>, covering the canonical layout, the rules, and
  configuration. Its Lean examples are compiled as the site builds.

### Changed

- Operator chains no longer step further right with each link. A chain built from `infixl` or
  `infixr` notation used to inherit one level of indentation per link, so every break landed a
  column deeper than the last: a 64-operand chain reached column 122 and rows 145 characters wide.
  Every break in one chain now lands in the same column, whatever its length and whichever way it
  associates.
- Comment reflow under `reflow-comments` now decides at the column a block actually occupies. The
  packing decision — margin, column, pinned phrases — is made while the line is rendered rather
  than beforehand, so a comment that fits where it was written is repacked when canonical layout
  indents its construct deeper.
- Failure messages have been rewritten to say what happened and what to do about it, without
  internal vocabulary.

### Fixed

- The `kind` enum in the SARIF schema no longer disagrees with what the tool emits.
