# Changelog

**Audience: anyone running lean-fmt.**

Notable changes in each release, and what you have to do about them. Versions before 0.4.0 predate
this file; their notes are on the
[releases page](https://github.com/jcreinhold/lean-fmt/releases).

lean-fmt is pre-1.0. Breaking changes raise the minor version.

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
