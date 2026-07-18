# RIR-FINAL — Differentially verify import changes

**Verified.** The header-rewrite invariants the roadmap names (`roadmap.md` §19: "Import rewrites
preserve header comments, attributes/modifiers, blank-group policy, and file-local syntax behavior")
are measured against the shipped `RIR-IMPL` code, not argued. The differentials — comment/modifier/
prelude/blank-group preservation, order-significance, suppression, fix conflicts, and frozen-sample
performance — all hold, and the withholding count is recorded. This note records what was run, what it
showed, and what changed while running it.

## The headline

**Every rewrite the import layer performs is either safe by construction or validated by
re-elaboration before it touches disk, and the one place it could silently lose information — a
comment inside the header — it does not.** A comment (leading, trailing, or standalone) is a group
boundary, so the organizer sorts *within* groups and copies the gaps between them verbatim; the
default `fix` never reorders (order is elaboration-significant); a duplicate-removal fix and a text
fix compose to a valid file; and 18 redundancy candidates on the project's own tree are withheld
rather than reported because they carry exposure reachability cannot reason about.

## What was run

All commands from the repository root; `FB` = `env LEAN_FMT_DISABLE_ARTIFACT=1
LEAN_FMT_TEST_DISABLE_MODULE_EVIDENCE=1 <lean-fmt>` (the exact-frontend fallback, since the import
layer is orthogonal to the analyzer).

### Header-rewrite invariants — `evidence/03-acceptance.lean` (transcript `03-acceptance.txt`)

`lake env lean docs/projects/ruff-09-import-rules/evidence/03-acceptance.lean` runs the actual
`Imports.organize` / `duplicateFindings` / `orderFindings` / `redundantFindings` over crafted headers
and checks each against a written expectation. All 18 checks print `ok`:

- **comment-delimits-groups** — `import Delta / import Alpha / -- middle / import Zeta / import Beta`
  organizes to each group sorted with the comment preserved verbatim between them.
- **trailing-comment-no-reorder** — `import Bravo -- note / import Alpha` is left unchanged: the
  trailing comment forces a group boundary, so the two are not reordered and the comment survives.
- **modifier-preserved-on-reorder** — `import all Bravo / import Alpha` → `import Alpha / import all
  Bravo`; the `all` modifier rides the sliced statement bytes.
- **prelude-preserved**, **blank-group-preserved** — the `module` marker, `prelude`, and blank-line
  boundaries are copied verbatim; only within-group order changes.
- **duplicate-removed**, **duplicate-with-comment-keeps-comment** — a duplicate is dropped; when the
  dropped line carried a trailing comment, the comment survives in the tail (no comment is lost; the
  surviving line inherits it — documented behavior).
- Diagnostics: FMT005 fires once with a safe fix (report-only when the line carries a comment); FMT007
  fires within a group and never across a comment/blank boundary and never carries a fix; FMT006
  withholds an `import all` line and counts it.

These are also pinned as persistent unit guards in `LeanFmtTest.lean` (`testImports`: the two-group
sort, trailing-comment no-reorder, and modifier-through-reorder cases).

### CLI-pipeline differentials — `tests/imports/run.sh` (persistent guards added)

- **Suppression composes with the import layer.** A trailing `-- lean-fmt: ignore[FMT005]` on the
  duplicate line suppresses the import finding through the same post-cache projection every rule flows
  through: `status clean`, `suppressed 1`, no FMT005. (`tests/imports/Suppressed.lean`.) An
  `ignore-file` at the top of the file likewise suppresses import findings, confirmed manually
  (`suppressed 1`).
- **Order is never touched by `fix`.** `fix` on the out-of-order `Ordering.lean` leaves the written
  order (`Digest`, `Basic`) unchanged — FMT007 carries no fix, and only `organize` rewrites.
- **Fix conflict / composition.** A file with both a duplicate import (FMT005, canonical-coordinate
  patch) and a trailing-whitespace text finding (FMT001) is fixed to a deduped, trimmed, valid file —
  both edits compose and the result is validated by re-elaboration before write.

### Withholding on the project's own tree — the stop-rule number

`FB <lean-fmt> check --root . --json` over the 75 workspace modules reports:

| code | count | | code | count |
| --- | --- | --- | --- | --- |
| FMT007 (order) | 16 | | FMT005 (duplicate) | 1 |
| FMT006 (redundant) | 1 reported | | FMT003/FMT004 (security) | 1 / 1 |
| FMT001 (trailing ws) | 3 | | FMT900/FMT901 (directives) | 2 / 1 |

**`withheldRedundant = 18`.** Eighteen redundancy candidates are withheld and only counted, never
reported, because they carry `import all` / `meta import` / a re-exported `public import` — exposure
that transitive reachability cannot prove removable (`notes/01-semantics.md` §5,
`redundancyEligible`). The project imports its own modules with `import all` pervasively, which is
exactly the population the conservative rule is built to decline. One plain redundancy survives to a
report (FMT006). The 16 FMT007 are real out-of-order headers in the project's own source (e.g.
`LeanFmt/Config.lean` places `import Lake.Toml.Load` after `LeanFmt.Rules`) — report-only, correctly
never auto-reordered.

### Performance — the frozen sample

The whole-project scan (75 workspace modules, the natural frozen sample for this repository; the
execution-core-v2 62-file external sample is another stack's fixture and not present here) with all
rules including the import family:

- warm wall-clock **3.63 s real / 3.38 s user**, **peak RSS ≈ 1.0 GiB** — analyzer-dominated.

The import layer's marginal cost is negligible: it adds one linear header parse per file and **one
shared `importClosures` graph fetch for the entire batch** (`Application.computeImportReports` collects
every written import name across all files and calls `Project.importClosures` once), never a per-file
Lake subprocess — the `RIR-IMPL` stop rule, confirmed by code and by the flat cost.

## Decisions changed / characterized during execution

1. **`ignore-next` and leading line directives in the header target the next *command*, not the next
   import — and that is honest, not silent.** The suppression model scopes `.nextItem` to the next
   command-root and `.line` to the comment's own physical line (`Suppression.directiveScope`). An
   `ignore-next` written above an import therefore scopes past the header to the first command, does
   not suppress the import finding, and is reported as an unused directive (`FMT900`) with the import
   finding still shown. A user who wants to suppress an import finding writes a *trailing* directive on
   the import line (verified working). Extending `.nextItem` to treat imports as items is a
   suppression-model change (the RSP stack's territory), out of scope here; the current behavior loses
   nothing silently. Characterized, not changed.
2. **Persistent guards over a one-shot experiment.** The evidence experiment reproduces the invariants
   but is not gated, so the load-bearing cases were folded into `testImports` (organize
   comment/modifier preservation) and `tests/imports/run.sh` (suppression, fix-no-reorder,
   fix-conflict), which the build and boundary gates run.

## Remaining uncertainty / observations

- **A "multi-module `check` fails" observation was chased down and proved to be a shell artifact, not
  a harness bug — the record is corrected here.** The original note read that passing ~20 real
  workspace modules as an explicit file list to `check` fails with `no such file or directory`. It does
  not. `check --root . --select FMT001 <21 modules>` passed as genuinely separate arguments reports
  `files=21` and exits clean. The failing repro passed the modules through an *unquoted* `$mods`
  variable under **zsh**, which — unlike bash — does not word-split unquoted expansions, so the whole
  space-joined list arrived as a *single* path argument; `check` correctly reported that one (non-
  existent) path as missing. The tell was that the error's `file:` field preserved the caller's own
  separator (spaces or newlines) — impossible if the paths had arrived as separate `argv`. Verified:
  `${=mods}` (forced zsh split) makes all 21 modules pass; bare `$mods` reproduces the "failure". The
  follow-up fix improves the diagnostic so the mistake is legible: `Project.load` now pre-checks
  existence and throws `selected file does not exist: <path>` naming the caller's own argument
  (consistent with the outside-root / not-a-Lean-source siblings) instead of letting `realPath` emit a
  partially-resolved, absolutized buffer. Guarded in `tests/check/run.sh` (single-missing and
  joined-list cases). The companion "`LeanFmt/Analysis.lean` is a tracked-but-unglobbed orphan" claim
  from this same note was also wrong and is retracted: it *is* globbed (`lakefile.lean` `LeanFmtApplication`,
  `Glob.one \`LeanFmt.Analysis`), built, and imported by `LeanFmt.Semantic`, `LeanFmtTest`, and
  `LeanFmtArtifactExtract`. It just sorts first in `ls LeanFmt/*.lean`, so it led the mis-joined path
  list and looked singled out. There is no orphan.
- **The duplicate-with-comment organizer behavior** (the surviving line inherits the dropped
  duplicate's trailing comment) is preservation, not loss, but is mildly surprising; it is pinned so a
  future change to comment placement is a conscious one.
- FMT006's conservatism is intended: 18/19 candidates withheld on this tree is the rule declining
  exactly where it cannot prove safety, which is the point.
