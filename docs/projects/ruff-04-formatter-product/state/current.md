---
kind: state
first_unresolved: 03-acceptance
---

# Current state

`RFP-SPEC` and `RFP-IMPL` are verified. The policy is `notes/01-policy.md`; what was run is
`results/01-policy.md` and `results/02-integration.md`. The external prerequisite stack
`ruff-03-language-formatting` is verified and its live implementation was re-read here rather than
trusted: every claim below cites the code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-policy | RFP-SPEC | verified | — |
| 02-integration | RFP-IMPL | verified | RFP-SPEC |
| 03-acceptance | RFP-FINAL | planned | RFP-IMPL |

## What the product does now

**`format` formats.** `tests/check/Layout.lean` holds `namespace     Alpha`; `format` reports
`would-format` with `changed=1` and `findings=0` at exit 1 (`evidence/04-format-now-formats.txt`).
`findings=0` is what makes it layout rather than a lint fix. `check` on the same file is `clean` at
exit 0: formatting is a canonical transformation, not a selectable rule, so it cannot enter rule
selection.

RFP-SPEC found the opposite and recorded why it was structural rather than an oversight
(`evidence/01-format-does-not-format.txt`, kept as the before-picture). `RFP-IMPL` closed it:
`RunMode.rendersCanonical` (`Application.lean:40`) decides which modes need a projection,
`renderCanonicalText` (`:324`) renders it at `canonicalWidth := 100` (`:315`), and the result is
carried on `SemanticResult.canonical?` (`Semantic.lean:34`) under schema
`lean-fmt.semantic-result.v2` (`:46`). Rendering is application-side because the boundary pins the
plugin's imports to `ArtifactModel`/`Rules` (`tests/boundary/run.sh:46`), so the plugin cannot reach
the printer.

**Canonical text carries its own findings, and that is not redundancy.** `CanonicalText`
(`Semantic.lean:20`) holds text *and* findings because canonical text is not lint-clean and
canonicalizing moves the bytes findings index. See the blocker below, which `RFP-IMPL` implemented
rather than removed.

**`diff` emits a diff.** `unifiedDiff` (`Application.lean:436`) hunks the edit script from
`Lean.Diff.diff` (`Lean/Util/Diff.lean:170`), core's histogram diff. It replaced a version that
reprinted the whole file to change one line — correct output, useless for review. Verified by `git
apply`, not by inspection (`evidence/05-diff-is-a-diff.txt`). `DiffLine` (`:415`) carries the line
terminator into the compared element; without it a file differing only in its final newline diffs to
an empty hunk list while reporting `changed=1`, which is exactly FMT002's edit.

**The stable style surface is empty, by proof rather than deferral.** `Doc.go` reads the margin at
exactly one place — the `.group`/`.brk` case (`Doc.lean:219-229`) — and `LeanFmt/Printer.lean` emits
only `Doc.text`, `Doc.hard`, and `Doc.verbatim`. No `group` means the margin is **never read**, so
every margin produces identical bytes. `line-width` would be a knob that cannot change one, and
`indent-*` the same against `nest`. Line endings are frozen as "preserve", which
`LosslessSource.normalize`/`denormalize` already guarantees. `RFP-IMPL` passes width 100 as an
internal constant.

**Formatter policy is out of semantic cache identity, and holds by construction.** `CacheIdentity`
(`Cache.lean:29-37`) keys findings only (`Semantic.lean:7-12`); style cannot change a finding; the
empty surface keeps `configuration` free of style.

## Blockers and prerequisites

- **Never reach `runBuild` under `noBuild` without `checkNoBuild` first.** Lake's no-build policy does
  not throw on an out-of-date target — `finalizeBuild` calls `IO.Process.exit noBuildCode.toUInt8`
  (`Lake/Build/Run.lean:368`; `noBuildCode : ExitCode := 3` at `:275`). A `try/catch` cannot intercept
  a process exit, and under `withoutProcessOutput` the buffered stdout/stderr is never flushed, so the
  run dies silently. `Workspace.checkNoBuild` (`:405-414`) asks the same question and returns a `Bool`.
  Lake guards this way itself (`Lake/CLI/Main.lean:1057`); so do `Project.exactSetup`, `compilerStatus`,
  and now `officialArtifacts` (`Application.lean:154`). This bit `RFP-IMPL` the first time any product
  path built a tree (`evidence/03-nobuild-exits-the-process.txt`).
- **Findings cannot be reused across a format.** Canonical text still violates FMT001/FMT002 — the
  printer keeps trailing trivia verbatim (`Printer.lean:208-222`,
  `evidence/02-canonical-text-still-lints.txt`) — and canonicalizing shifts the offsets findings
  index (`Application.lean:420-422`). The composition is forced: format first, then **re-derive**.
  `RFP-IMPL` implemented this as `CanonicalText.findings`; it remains a constraint on anything that
  edits canonical text.
- **`PreparedFile.changed` is not `Patch.changed`.** With a canonical base, "are there fix edits?"
  (`Edit.lean:44`) answers `false` for a layout-only change, so `format` would call a file clean while
  printing a different body. `PreparedFile.changed` (`Application.lean:578`) compares the formatted
  text to the normalized source instead. Every caller must keep using it.
- **A cache hit carries no tree.** `previewFile` returns before `officialArtifacts`, so a hit cannot
  build one. A hit now carries canonical *text*, which is what a rendering mode needs, and
  `cacheHitServes` (`Application.lean:371`) makes a `check`-populated entry a **miss** for a rendering
  mode rather than an under-populated hit. Whether `fix` can take a hit is still open and unmeasured:
  `RFP-IMPL` used `--no-cache` throughout to isolate the wiring.
- **The first `group` in `Printer.lean` must add `line-width` and its cache-identity component in the
  same commit.** Today's identity is accidentally correct; a `group` makes the margin observable and
  existing entries stale under an identity that never mentioned it — consistent and wrong.
- **This repository is the printer's own corpus, so editing `LeanFmt/` moves the gated figures.**
  `tests/printer/run.sh:137-145` fails on stale shape evidence; the remedy is
  `experiments/run-projection-shape.sh` and then `experiments/check-quoted-figures.py`, which checks
  percentages as well as counts. `RFP-IMPL` moved 458 → 468 commands and 42,599 → 43,840 nodes.
  Comment text carries no nodes, so updating the quoted prose is a fixed point.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
