# FIP-SPEC — the in-place-format interface (frozen)

`format` becomes a writer. Running `lean-fmt format` over a project publishes the canonical layout in
place for every included file, exactly like `ruff format`. `format --check` keeps today's non-writing
CI preview; `diff` stays `ruff format --diff`; `check` and `diff` never write. This note freezes the
interface before any code change (FIP-IMPL implements exactly this, no more surface).

This is a **default-flip**, not new machinery: the layout patch already exists (`ruff-11c`), the
guarded publish already exists (`ruff-06`), no-arg project selection already exists (`Project.load`).
The only additions are a writing wrapper analogous to `fixFile`, a `--check` flag, and a rewritten
`Cli.lean` output arm.

## 1. The write

For each resolved snapshot, writing `format`:

1. **Render the layout patch.** `prepareFile plan (renderCanonical := true) …` produces
   `PreparedFile` whose `patch.formatted = canonical.text` (the reflowed normalized bytes) and whose
   fix edits are empty — the `ruff-11c` layout patch (`Application.lean:821-827`, the `renderCanonical`
   arm returns `(canonical.text, #[])`). No rule fix rides `format`; it publishes only layout. This is
   invariant with today's `previewFile .format`, which reads the same `prepared.output`.
2. **`prepared.changed`?** `prepared.patch.formatted != prepared.normalized` (`Application.lean:679`).
   If unchanged → status `clean`, `written := false`, no write, no validator (parity with `fixFile`'s
   `unless prepared.changed` short-circuit, `Application.lean:903-904`; a clean project constructs no
   child).
3. **Validate under the exact module setup.** `run.analyzeSnapshot (snapshot.withSource output)
   (renderCanonical := false) (validator := true)` — re-elaborate exactly the bytes a write would
   publish, no canonical render (identical call to `fixFile`, `Application.lean:909-911`). If
   `validationReport` fires (`result?.isNone`) → status `rejected`, no write.
   - **Validation is REQUIRED, not elided.** Default and frozen. Justification: (a) parity with `fix`
     and `organize`, the other writers, both of which re-elaborate before publish; (b) the CLAUDE.md
     invariant this stack installs reads "format and fix publish only … validated under the exact
     module setup"; (c) `Printer.format` is not *proven* to preserve elaboration — `RLF-REFLOW` made it
     emit `group`/`nest`/`line` that move bytes across lines (`Application.lean:335-359`), and a
     reflow that breaks an application across an indent-sensitive boundary is exactly the class of bug
     the validator exists to catch. A pure-reflow "it must still elaborate" assumption is the kind of
     unproven shortcut this repo rejects. The cost is one frontend child per *changed* file — the same
     child `fix` pays, and `format` already owed one `analyzeExact` render pass anyway (it demands
     `.semantic`, so it never took the artifact fast path; §5).
4. **Publish atomically, losslessly.** `publishAtomic snapshot.path snapshot.source output`
   (`Application.lean:625-640`), where `output = prepared.output =
   LosslessSource.denormalize prepared.patch.formatted prepared.lineEndings` (`Application.lean:669`).
   `publishAtomic` writes a temp sibling, copies the source's access mode, re-reads the original and
   **refuses the write if the source changed after analysis** ("source changed after analysis;
   refusing stale write"), then `rename`s. This is the stale-source guard — identical to `fix`. A
   partial write is impossible: the rename is atomic and the temp is removed on any failure.
5. **Report.** On write → status `formatted`, `written := true`, `formatted := some output` (mirrors
   `fixFile`'s `fixed`/`written`/`formatted`, but the verb's own status string). Per the report
   aggregation (`summarize`, `Application.lean:932-948`) `written` counts `file.written`, and
   `formatted` (the status) must be added to the `changed` predicate alongside `would-format`/`fixed`.

A file that does not elaborate is `broken` (`prepareFile`'s `result?.isNone` throw,
`Application.lean:808`) and is never written — the write path is never reached. Same as `fix`.

## 2. `format --check`

The non-writing preview — ruff's CI mode. When `--check` is set, `format` runs the identical render
(steps 1–2) but **writes nothing and runs no validator**: it reports `would-format` for a file that
would change and `clean` otherwise — i.e. today's exact `previewFile .format` behavior
(`Application.lean:876-880`). This *is* the current default, demoted to an opt-in flag.

- No file is written; the fixture is byte-identical afterward.
- Exit non-zero (1) if **any** file would change; 0 if all clean; 2 on infrastructure failure.
- `--check` matches `ruff format --check` precisely: "does not write, exits non-zero if any file
  would be reformatted."

`--check` is parsed only for `format` (like `--check-elab` is `fix`-only, `Cli.lean:88-92`); it is an
error for `check`/`diff`/`fix`. (The `organize` verb already owns its own `--check`; this is the
`format` verb's, parsed in `parseFileArgs` and gated on `mode == .format`.)

## 3. Exit codes and report status (pinned)

| Run | changed a file | all clean | infra fail |
| --- | --- | --- | --- |
| `format` (writing) | **0** (status `formatted`, `written++`) | 0 (`clean`) | 2 |
| `format --check` | **1** (status `would-format`) | 0 (`clean`) | 2 |
| `fix` | 0 (`fixed`) — unchanged | 0 | 2 |
| `check` | 1 (`findings`) — unchanged | 0 | 2 |
| `diff` | 1 (`would-diff`) — unchanged | 0 | 2 |

The only exit-code change is writing `format`: it moves from the `mode != .fix && changed>0 → 1`
branch to the 0-on-change side. `reportExitCode` (`Cli.lean:211-214`) must treat writing `format`
like `fix` (0 on change) but `format --check` like `check` (1 on change). Because the exit rule keys
on `mode`, it needs the `--check`/write disposition too. Frozen shape:

```
reportExitCode:
  infra → 2
  broken>0 || rejected>0 → 1
  (mode is writing-format OR mode==fix) → 0     -- writers exit 0 on a change they published
  changed>0 → 1                                  -- check, diff, format --check
  else → 0
```

JSON report shape is unchanged from today's `RunReport`/`FileReport` (`Application.lean:66-100`): a
written file is `{"status":"formatted","written":true,"formatted":"<bytes>", …}` (top-level
`written` incremented); `format --check` is `{"status":"would-format","written":false,
"formatted":"<bytes>"}`. No new JSON field. `formatted` (the field) still carries the canonical text
in both, so `--json` consumers keep working; the `written` bool distinguishes a publish from a
preview.

## 4. The CLAUDE.md invariant change

Rewrite the live product invariant (`CLAUDE.md:52-54`), from:

> `check`, `format`, and `diff` never write source. `fix` publishes only a complete, conflict-free
> patch validated under the exact module setup, after a stale-source check.

to:

> `check` and `diff` never write source. `format` and `fix` publish only a complete, conflict-free
> result validated under the exact module setup, after a stale-source check. `format` publishes the
> canonical layout (no rule fix); `fix` publishes admitted rule fixes at original coordinates.
> `format --check` and `diff` are the non-writing previews.

### Grep list — every repetition of "format never writes", with disposition

| Site | Disposition |
| --- | --- |
| `CLAUDE.md:52` | **Rewrite** (above). The live product policy. FIP-IMPL. |
| `tests/modes/run.sh:704,712,716` | **Migrate.** Confluence-test comments ("Because format never writes, its preview is captured to…"): FIP-IMPL rewrites the confluence block so `format` actually writes order A's file (prompt 02 Target). |
| `LeanFmt/Application.lean:788` | **Rewrite comment.** "`format` prints `output`" → format *publishes* `output` (the layout patch) through the guarded path; `diff` diffs it. The `prepareFile` layout-patch docstring. |
| `LeanFmt/Application.lean:59` | **Light touch.** "so `format`/`diff` preview exactly what `fix` would write" — still true of `--check`/`diff`; clarify that plain `format` now publishes the layout, not a rule fix. |
| `LeanFmt/Semantic.lean:10` | **Rewrite comment.** `CanonicalText.text` "is what `format` prints" → what `format` publishes and `diff` diffs against. |
| `LeanFmt/Application.lean:1064` | **Code change** (not a comment): the driver `.format => previewFile .format` dispatch becomes the writing seam (`formatFile`) unless `--check`. §6. |
| `docs/projects/execution-core-v2/roadmap.md:114` | **Leave — frozen, and still true at its layer.** Governs the execution *core*; the statement is about the mode *primitive* `previewFile .format`, which still renders-only and never writes. The product `format` *verb* now composes render+publish on top (§6). Rewriting a completed stack's roadmap would falsify its record. |
| `docs/projects/execution-core-v2/prompts/09-modes.md:82` | **Leave — frozen prompt.** A completed prompt's Target is history; do not rewrite. True of the primitive. |
| `docs/projects/ruff-11b/roadmap.md:68`, `ruff-11c/notes/01-model.md:141`, `ruff-11c/prompts/03-impl.md:62`, `ruff-11c/roadmap.md:139`, `ruff-11c/results/04-final.md:75`, `ruff-10b/results/03-final.md:76` | **Leave — frozen history.** Result notes, completed-stack roadmaps, and executed prompts record point-in-time state and were true when written. This repo does not rewrite frozen history; the current policy lives in the CLAUDE.md invariant this stack changes and in the `ruff-class-roadmap` 11d row. |

Rationale for the frozen/live split: the *core mode primitive* (`previewFile .format`) genuinely
still renders-and-does-not-write — it is what `format --check` and `diff` ride. What changes is the
*product `format` verb*, which now routes the default (no `--check`) through a `formatFile` publish
wrapper. So the execution-core-v2 statements remain literally true of the layer they govern; only the
product-surface policy (CLAUDE.md) flips.

## 5. Why `format` already pays for the frontend (no new run for the write)

Writing `format` needs an `ExactRun` (the validator child, §1 step 3). It already needs one for
rendering: `RulePlan.demandedTier renderCanonical := requiredTier.max (if renderCanonical then
.semantic else .source)` (`Config.lean`, cited in `Application.lean:1007`), so a rendering run always
demands `.semantic`. The plugin artifact carries no `semantic` (`ruff-05b`), so the driver fetches no
artifact for `format` (`Application.lean:1029-1030`) and it takes its single `analyzeExact` render
pass through `withExactRun`. That same `ExactRun` hosts the validator. Net new frontend cost of the
write over today's preview: **one validator child per changed file** — exactly `fix`'s cost, and only
on files that change.

One consequence to preserve: writing `format` can no longer be served from the **cache-only preview
fast paths** (`Application.lean:1011-1018`, `1040-1047`), which return without an `ExactRun`. Those
paths are gated on `request.mode.preview?`. Writing `format` must NOT be a `preview?` (it needs the
validator child), so it falls through to `withExactRun` like `fix`. `format --check` **stays** a
`preview?` and keeps the cache-only fast path (it writes nothing, needs no validator). This is the
one place the `--check` disposition must reach the driver, not just `Cli.lean`.

## 6. Reuse-vs-new inventory

### Reused unchanged (the entire publish path — do NOT duplicate)

| Helper | Location | Role for `format` |
| --- | --- | --- |
| `prepareFile … (renderCanonical := true)` | `Application.lean:804` | Builds the layout patch (`patch.formatted = canonical.text`, empty fixes). Already exists; `previewFile .format` calls it today. |
| `PreparedFile.output` / `.changed` | `Application.lean:669`, `679` | Denormalized write bytes; change test. Unchanged. |
| `ExactRun.analyzeSnapshot … (validator := true)` | `Application.lean:399` | Re-elaborates the candidate. Identical call to `fixFile`. |
| `validationReport` | `Application.lean:646` | Turns a failed validation into a `rejected` report. Unchanged. |
| `publishAtomic` | `Application.lean:625` | Stale-source check + atomic lossless write. Unchanged. |
| `LosslessSource.denormalize` | via `PreparedFile.output` | CRLF/line-ending round-trip on write. Unchanged. |
| `withExactRun` driver block | `Application.lean:1048-1078` | Already the home of `fix`; writing `format` joins it. |
| `Project.load` no-arg discovery | `Project.lean` (`discoverPaths` + `config.includesPath`) | Selects the written set. Unchanged — this stack changes what happens *to* each file, not *which*. |

### New surface (minimal — this is the whole delta)

1. **`formatFile`** — a writer analogous to `fixFile` (`Application.lean:889`), differing only in
   `renderCanonical := true` at the `prepareFile` call and the `formatted` status string. It renders
   the layout patch, short-circuits `clean` when unchanged, validates, `publishAtomic`s, reports
   `formatted`/`written`. ~25 lines, structurally a copy of `fixFile` with the layout base. (If the
   two collapse cleanly into one parameterized helper, fine — but do not fold the publish path into
   two copies.)
2. **`--check` flag** — a `RunRequest`/command field (e.g. `formatCheck : Bool`), parsed in
   `parseFileArgs` gated on `mode == .format`; error otherwise.
3. **Driver disposition** — writing `format` (mode `.format`, `!formatCheck`) dispatches to
   `formatFile` in the `withExactRun` loop and is excluded from the cache-only `preview?` fast paths;
   `format --check` keeps `previewFile .format` on every path (unchanged). The seam is: "is this run a
   writer?" = `mode == .fix || (mode == .format && !formatCheck)`.
4. **`Cli.lean` output** — replace the `"format"` arm of `renderText` (`Cli.lean:163-171`, the
   `=== path (bytes) ===` dump): writing `format` prints a concise per-file summary (path,
   written/unchanged), not the body; `format --check` prints what would change (path: would-format).
   `--json` is unchanged (§3). `reportExitCode` gains the writing-format branch (§3).

## 7. Boundaries

- **Config-scoped file selection / formatter+linter config sections → `ruff-13-config-discovery`.**
  This stack uses the existing `Project.load` discovery (`discoverPaths` + `config.includesPath`)
  unchanged. It does not add glob config, `exclude`, or a `[format]` section.
- **stdin/stdout single-stream and range formatting → `ruff-14-stream-range`.** No stdin path, no
  `--stdin-filename`, no range. The user reviews with `format --check`/`diff` and writes with
  `format`.
- **No stdout escape hatch is introduced.** The old stdout dump is *removed*, not preserved behind a
  flag: `format --check` (report of what would change) and `diff` (the unified diff) already cover
  every non-writing need, and `--json` still carries `formatted` for a programmatic consumer. If a
  raw-body-to-stdout mode is ever wanted it is `ruff-14`'s stdin/stdout surface, not a stopgap here.

## 8. What must NOT change (stop conditions carried into FIP-IMPL/FINAL)

- No `format` write skips a `ruff-06` guard (stale-source check + validation). No partial write.
- `format` applies **no** rule fix — only layout (the `ruff-11c` split). A written file shows no
  FMT01x/FMT014 rename; those ride `fix`.
- `check` and `diff` still never write.
- Lossless: original line endings preserved on write (`denormalize`); no in-string byte changes
  (`ruff-11c` RDF-LAYOUT trivia-only trim).
- The `ruff-11c` format+fix confluence still holds, now with `format` actually writing.
</content>
