# Plan: per-command `--help` for lean-fmt

Plan lives here during review; on approval, move it to `lean-fmt/plans/per-command-help.md` with the implementation.

## Context

`lean-fmt --help` is one global dump: a 12-form usage block, 22 "file options", 3 "stdin
options" — and `lean-fmt <command> --help` prints **the same text for every command**
(`LeanFmt/Cli.lean:1441-1446`). The parsers know constraints the help never teaches
(`--range` is format-only, finding-shaped formats are rejected for `diff`, `--watch` refuses
writers, `--check` is meaningful only for `format`, fix-selection flags matter only to
`fix`/`check`), so users learn them by tripping exit-2 errors.

Adjacent stale doc, same repair pass: `README.md:42` says "`check`, `format`, and `diff`
never write files; `fix` is the only writer" — false since `format` became a writer by
default (`RunRequest.writesFormat` doc, `Application.lean`: "`--check` … the former
default"), and contradicts the quick-start comment two lines above it. `README.md:45` also
re-lists `format` under "Other commands" as "(print formatted source)".

### What each command does exactly (ground truth from the code)

| Command | Does | Writes? | Exit |
| --- | --- | --- | --- |
| `check` | Reports selected-rule findings per file. Layout is not a finding: badly-laid-out but lint-clean is clean. Can take the source-only fast path. | no | 0 clean, 1 findings, 2 failure |
| `format` | Renders the canonical layout. **Writes files in place atomically by default**; `--check` is the non-writing CI preview (`would-format`/`clean`). With `-` target: reads stdin, prints formatted source to stdout; `--range`/`--range-lines` (format-only). | yes (unless `--check`/stdin) | 0/1/2 |
| `diff` | Prints the patch `format` would write. Rejects finding-shaped `--output-format` (concise/github/sarif/junit) — a patch carries no findings. | no | 0/1/2 |
| `fix` | Applies admitted *rule* fixes at original coordinates (like `ruff check --fix`); does **not** reflow layout (run `fix` then `format` for both). Safe fixes only unless `--unsafe-fixes`. | yes | 0/1/2 |
| `lsp` | Language server on stdio: formatting, range formatting, code actions, diagnostics alongside Lean's server. | (via edits) | service |
| `organize` | Canonicalizes import headers (pure rewrite), validates changed files through the frontend, writes them. `--check` previews (`would-organize`). | yes (unless `--check`) | 0/1/2 |
| `rules` | Dumps the rule registry: TSV rows (code, category, lifecycle, fixable, enabled, summary); `--json` for the array. | no | 0 |
| `explain RULE` | One rule's full text. Live rule → `explainText`; retired code → disposition; meta (`FMT900/901`) → description. All exit 0 (discovery); only unemittable tokens exit 2. | no | 0/2 |
| `docs` | Regenerates `docs/rules/{index,FMT###}.md` from the registry; `--check` verifies no drift (the undocumented-rule invariant, for CI). | yes (unless `--check`) | 0/1 |
| `clean` | Removes `.lean-fmt-cache/` under the root. | deletes cache | 0/2 |
| `compiler setup` | Prints plugin setup guidance (schema, package, plugin target, facet, toolchain, numbered steps). | no | 0 |
| `compiler status` | Per-module artifact status (ready/missing/unbuilt) + totals. | no | 0/2 |
| `compiler build` | Builds every workspace module's `leanFmtArtifact` facet in one Lake invocation. `--json` rejected. | build artifacts | Lake's |
| `config show PATH` | Prints the effective config for one file and each setting's provenance. | no | 0/2 |

## Approach

Data-driven per-command help specs in one new internal module; rendering machinery moves
unchanged; dispatch looks up the spec by first token.

Module-design lens: the help *content* is a volatile decision (text churns as flags change)
and the *renderer* is stable — separate them, hide both behind a two-function surface. Do
**not** refactor the hand-written parsers into declarative specs (parse-table-driven CLI):
that is the drift-proof-by-construction end state, but it touches every parser for a help
improvement. Instead, pin the coupling with a drift test (below).

### Root help (overview, cargo-style)

- `usage: lean-fmt <command> [OPTIONS] [FILE...]` plus the stdin form.
- A commands table: 12 rows, name + one-line summary (from the spec table — one source).
- Global notes: exit-code convention (0 clean / 1 findings-or-drift / 2 failure); color/TTY,
  `NO_COLOR`, `COLUMNS`; pointer: `lean-fmt <command> --help`.
- No global option dump.

### Per-command help

One `CommandHelp` per first-token command (`compiler` covers setup/status/build; `config`
covers show):

- one-line summary + a short "what it does / what it writes" paragraph (from the table
  above, incl. exit codes);
- its own usage line(s);
- option sections listing **only flags that command's parser accepts and that mean something
  for it**, grouped: target / rule selection / fix selection / output / execution / stdin;
- notes for the constraints the parser enforces (diff vs finding-shaped formats; fix vs
  `--watch`; `--range` format-only; `--check` = format's preview; `--unsafe-fixes` is a
  display-only count for format/diff).

Shared file-command options stay one *data* table, sliced per mode (check: no `--check`,
no `--range`; diff: no `--check`/`--range` + format note; fix: no `--watch`/`--range`/
`--check`; format: all) so the text has one home and the views differ.

## Files to modify

- **New `LeanFmt/CliHelp.lean`** — `HelpEntry`/wrap/paint/render machinery moved from
  `Cli.lean` unchanged; `CommandHelp` structure + the 12-spec table; surface is two
  functions: `overviewHelp (color : Bool) (width : Nat) : String` and
  `commandHelp? (command : String) : Option (Bool → Nat → String)`.
- **`LeanFmt/Cli.lean`** — delete the moved help block (~120 lines: `helpUsageLines`,
  `helpFileOptions`, `helpStdinOptions`, `usage`, `printUsage` body); dispatch: root
  `--help` → overview; `<cmd> --help` → `commandHelp?` (unknown command → overview to
  stderr, exit 2 — unchanged). Keep TTY/COLUMNS detection in `Cli.lean`, pass values in.
- **`README.md`** — fix line 42 (only `check`/`diff` never write; `format` writes unless
  `--check`; `fix` applies rule fixes) and drop the duplicated `format` entry at line 45.
- **`tests/Suites/Check.lean`** — extend `testFlagSurface` (or a sibling test) with the
  drift pins below.

## Reuse

- `renderHelpEntry`/`renderHelpSection`/`wrapHelp`/`paint*` (`Cli.lean:264-290`) — moved,
  not rewritten.
- `checkRaw` harness + the `--check-elab` negative pattern in `tests/Suites/Check.lean:88-92`.
- `RunMode.toString`, the parsers' own error messages (drift test asserts *acceptance* of
  documented flags; parsers already exit 2 on unknown options).

## Steps

- [ ] Create `LeanFmt/CliHelp.lean`: move machinery; define `CommandHelp`; author the 12
      specs (summary, paragraph, usage, sections, notes) from the ground-truth table.
- [ ] Wire `Cli.lean` dispatch to the new module; delete the old block; `import all
      LeanFmt.CliHelp`.
- [ ] Root overview: commands table generated from the same spec array (one source of
      truth for name + summary).
- [ ] Drift test: (a) every first-token command in `runCli`'s dispatch has a spec and its
      `--help` exits 0; (b) root help names every command; (c) every flag in each command's
      help is accepted by that command's parser (invoke with dummy values; expect not
      "unknown option"); (d) mode-excluded flags absent (`--range` not in check/diff/fix
      help; `--watch` not in fix help); (e) keep the `--check-elab` negative.
- [ ] Fix `README.md:42,45`.
- [ ] Move this plan to `lean-fmt/plans/per-command-help.md`.

## Verification

1. `lake build`; `lake test -- --suites check` (suite holding the help assertions); then
   `lake test`; `lake lint`.
2. Manual review: `lean-fmt --help` and each `lean-fmt <cmd> --help` at COLUMNS=80/100/120,
   TTY color and `NO_COLOR` — wrapping intact, no irrelevant flags, exit codes stated.
3. Spot-check truthfulness against the parsers: `lean-fmt diff --output-format sarif` still
   errors as the help now documents; `lean-fmt fix --watch` ditto; `lean-fmt check --range`
   ditto.
4. Confirm root help fits one screen at 80 cols (overview, not dump).
