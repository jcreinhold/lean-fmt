---
kind: state
first_unresolved: none
---

# Current state

**This stack is complete.** `RFP-SPEC`, `RFP-IMPL`, and `RFP-FINAL` are verified. The policy is
`notes/01-policy.md` and is published as `notes/02-stability.md`; what was run is `results/01-policy.md`,
`results/02-integration.md`, and `results/03-acceptance.md`. The external prerequisite stack
`ruff-03-language-formatting` is verified and its live implementation was re-read here rather than
trusted: every claim below cites the code.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-policy | RFP-SPEC | verified | — |
| 02-integration | RFP-IMPL | verified | RFP-SPEC |
| 03-acceptance | RFP-FINAL | verified | RFP-IMPL |

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

**The stable style surface is empty — at ship time by the no-group proof, now because the margin is a
compile-time constant.** When `RFP-FINAL` shipped, `LeanFmt/Printer.lean` emitted only `Doc.text`,
`Doc.hard`, and `Doc.verbatim`, so `Doc.go`'s single margin read — the `.group`/`.brk` fit test
(`Doc.lean:219-229`) — never fired and every margin produced identical bytes. **03 phase-2
(`RLF-REFLOW` onward) fired the trigger this stack named:** `Printer.termDoc` now emits
`group`/`nest`/`line`, the margin *is* read, and over-margin input reflows, so the general "every
margin is identical" proof is retired (`Application.lean:316-320`). The surface stays empty for a
narrower reason: the margin is the compile-time constant `canonicalWidth := 100`
(`Application.lean:339`), not a runtime key, so no `line-width` knob is exposed and none is needed
yet; `indent-*` is still a no-op against `nest`. Line endings are frozen as "preserve", which
`LosslessSource.normalize`/`denormalize` already guarantees. `RFP-IMPL` passes width 100 as an
internal constant.

**Formatter policy is out of semantic cache identity, and holds by construction.** `CacheIdentity`
(`Cache.lean:29-37`) keys findings only (`Semantic.lean:7-12`); style cannot change a finding; the
empty surface keeps `configuration` free of style.

**The margin proof holds on foreign Lean, measured.** `RFP-FINAL` formatted the frozen mathlib sample
(62 modules) two ways: the printer harness at width 80 reformats 12, the product at width 100 reports
12 `would-format`, the sets are identical, and the outputs are **12 byte-identical, 0 differing**
(`evidence/06-frozen-sample.txt`). Different binaries, different tree-acquisition paths, different
widths, same bytes. Idempotence is 12/12 at width 100 on the product's own output. `format` moves 12 of
62 modules (19%) with `findings=0` throughout, so on real Lean this change is entirely layout.
Under 03 phase-2 "different widths, same bytes" survives as an *empirical* sample property, not a
structural guarantee: `RLF-REFLOW-ACCEPT` re-ran the frozen sample and found the reflow breaks a no-op
on it even at the stricter margin 80 (so a fortiori at 100), because no foreign construct in the sample
is wide enough to break. A re-measurement of this table under the reflow printer is therefore expected
to reproduce it, but has not been re-run in this stack.

**Timing: 250.97 s and 1.58 GB for 62 modules, and it is the frontend, not the printer.** mathlib
registers no `leanFmtArtifact` facet, so `officialArtifacts` misses in order and every module is parsed
by the exact-frontend fallback — the slow path by construction. `Lean.Diff.diff` is not visible in
either number.

**The command matrix is the interface.** 3 fixtures × 4 modes, every cell a run
(`evidence/07-command-matrix.txt`). Exit codes are two rules: `check` exits 1 on findings and layout
cannot move it; `format`/`diff` exit 1 on `changed > 0`; `fix` exits 0 when it succeeds. So
`Layout.lean check = 0` beside `Layout.lean format = 1` on the same bytes is not an inconsistency —
it is the migration path, and `notes/02-stability.md §4` is where a user is told so.

## Blockers and prerequisites

- **Never reach `runBuild` under `noBuild` without `checkNoBuild` first.** Lake's no-build policy does
  not throw on an out-of-date target — `finalizeBuild` calls `IO.Process.exit noBuildCode.toUInt8`
  (`Lake/Build/Run.lean:368`; `noBuildCode : ExitCode := 3` at `:275`). A `try/catch` cannot intercept
  a process exit, and under `withoutProcessOutput` the buffered stdout/stderr is never flushed, so the
  run dies silently. `Workspace.checkNoBuild` (`:405-414`) asks the same question and returns a `Bool`.
  Lake guards this way itself (`Lake/CLI/Main.lean:1113`); so do `Project.exactSetup`, `compilerStatus`,
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
  mode rather than an under-populated hit. This is a single point of failure and it fails *silently*:
  break it and `prepareFile` takes the `renderCanonical = true`, `canonical? = none` path, bases the
  patch on the file's own bytes, and reports `clean` at exit 0 — "format does not format" resurrected
  through the cache. `RFP-FINAL` pinned it (`tests/modes/run.sh:200-222`); the test asserts on
  `changed`, `status`, and the exact bytes, because the exit code alone cannot see this. Whether `fix`
  can take a hit is still open and unmeasured.
- **Cite Lake and Lean against v4.32.0.** `find ~/.elan/toolchains ... | head -1` returns v4.31.0 and
  every citation in this stack was first taken from it. The load-bearing ones survived — `Run.lean:275`,
  `:368`, `:405-414` are identical in both — but `lake shake`'s guard moved from
  `Lake/CLI/Main.lean:1057` to **`:1113`**. `RFP-IMPL`'s commit message still carries the stale number
  and cannot be rewritten; `evidence/03` records the correction rather than hiding it.
- **The group trigger fired in 03 phase-2, and the compile-time constant kept cache identity sound.**
  `Printer.lean` now emits `group`, so the margin is observable — but `canonicalWidth` is compiled into
  the binary and the `formatter` cache-identity component already hashes the binary (`Cache.lean:258`),
  so a margin change recompiles, changes the digest, and invalidates every stale `CanonicalText`
  (`Application.lean:322-329`). The remaining, *unfired* trigger is a **runtime** project-overridable
  `line-width` key: it changes output without changing the binary, so whoever adds it must fold the
  resolved margin into the `configuration` digest (`Project.configurationIdentity`, `Cache.lean:207`)
  in the same commit. That work is owned by `ruff-13-config-discovery`'s `[format]` section.
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
