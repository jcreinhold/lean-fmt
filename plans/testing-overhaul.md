# Testing system overhaul

## Context

The repo's testing is a two-tier patchwork that has grown ad hoc:

1. **`LeanFmtTest.lean`** (root, 2,892 lines): one monolithic exe, ~30 `private def testX : IO Unit`
   functions run sequentially by `main`, plus ~12 argv-dispatched subcommand modes
   (`artifact-projection`, `incremental-analyzer`, `doc-bench`, …) that exist only so shell scripts
   can call back into Lean. Registered as Lake `testDriver`, so `lake test` covers only this unit
   tier — none of the 36 suites.
2. **36 `tests/*/run.sh` bash suites** (9,145 lines of bash), orchestrated serially by
   `tests/run-all.sh`. Every suite re-runs `lake build` + `lake -q query` itself; ~231 inline
   `python3` heredocs do JSON assertions, hashing, and LSP client simulation; 4 standalone `.py`
   files. Per-suite boilerplate (tempdir traps, `run_expect`, snapshot restore) is copy-pasted;
   `tests/modes/run.sh` alone is 1,104 lines and mutates tracked fixture files in place.
3. **Out-of-sweep stragglers**: `tests/lsp/acceptance.sh`, `tests/lsp/editor.sh`,
   `tests/security/bench.sh` — documented only in CLAUDE.md prose.

Measured pain: ~30-minute serial sweep; `lake test` runs a fraction of the corpus; Python is a
third implementation language doing pure assertion work (against CLAUDE.md §Scope: "Prefer pure
Lean"); CI (`.github/workflows/lean_action_ci.yml`) runs build+lint only — the sweep has zero CI
coverage.

### Constraints any design must respect (from CLAUDE.md / suite comments)

- `tests/modes` fails if a concurrent `lake build` touches the main `.lake` under it; several
  suites rebuild fixture artifacts mid-run. Some suites are genuinely exclusive.
- stream/watch suites are timing-sensitive; performance gates assert counts/ratios/digests, never
  wall time (machine-load variance measured 3,977 ms vs 19,968 ms on identical work).
- `tests/ci/run.sh` reads **committed** state (git clone at HEAD, `git archive`) — must stay a
  deliberate, separately-invoked gate.
- Suites under `tests/` are the strongest surviving statement of intended behavior — ports must
  preserve assertion coverage 1:1, never rewrite semantics.
- `tests/formatter/candidate.py` is deliberately a *foreign* adversarial candidate — being non-Lean
  is the property under test. It stays Python.
- The cache root is `workspace.root / ".lean-fmt-cache"` (`LeanFmt/Cache.lean:598`): suites sharing
  the main workspace share one cache directory. Parallelism design must account for this.

### Established patterns to build on

- `scripts/CheckModules.lean` + its `lean_exe «check-modules»` (`srcDir := "scripts"`, imports
  Lake): the repo already runs structural checks as native Lean exes wired into the lakefile.
- `tests/lsp/Acceptance.lean` (driven via `lake env lean --run`): a native LSP client test already
  exists and works.
- `tests/incremental/run.sh` (17 lines): build test exe → call native subcommand → assert output.
  The seam this plan generalizes into per-suite exes.
- Fixture `lean_lib`s in the lakefile (CheckFixtures, CompilerFixtures, NativeLayoutFixtures, …)
  with the compiler plugin applied — already Lake-native.
- `tests/performance/negative.sh`: the discipline of proving each gate can fail. Ports keep it.

## Approach

Three layers: a shared native harness library, a reworked unit tier, and per-suite Lake exe targets
with a tagging orchestrator that becomes the `testDriver`.

### Layer 0 — native test harness (`tests/Test/`)

A `lean_lib TestSupport` (`srcDir := "tests"`, globs `Test.*`; in no product link closure):

- **`Test.Harness`** — test registration (`#[]` of named `IO Unit` cases or a small `TestM`
  DSL), the `ensure`/`ensureEq`/`ensureRejected` assertion family lifted from `LeanFmtTest.lean`,
  per-test failure isolation (one failure no longer aborts the run; failures collect and report by
  name), timing per test, `--list`/`--filter <substring>`/`--shard i/n` CLI handling shared by all
  test exes.
- **`Test.Proc`** — `IO.Process` wrappers: spawn with env/stdin/capture, `expectExit : UInt32 → …`,
  timeout via `IO.asTask` + cancel, stdout/stderr golden-string and regex asserts. Replaces
  `run_expect` and the `check` helpers duplicated across suites.
- **`Test.Golden`** — golden-file byte compare with an opt-in `UPDATE_GOLDEN=1` rewrite mode
  (replaces `cmp "$out" tests/reporting/golden/json-check.json` and friends).
- **`Test.Json`** — field-projection assertions over `Lean.Json` (replaces the python heredocs:
  `assert data["files"][0]["findings"] == …`).
- **`Test.Fixture`** — tempdir lifecycle (`IO.FS.createTempDir` + deterministic cleanup),
  temp-copy of tracked fixtures into scratch trees (the modes/check mutation replacement),
  in-workspace scratch files under a git-ignored `tests/.scratch/` with a cleanup registry
  replacing the per-suite trap-and-restore blocks.
- **`Test.LspClient`** — native LSP client (framing, request/response matching, notification
  waits) factored from `tests/lsp/Acceptance.lean`'s proven code; replaces the python LSP heredoc
  in `tests/lsp/run.sh`.

### Layer 1 — unit tier split (`tests/Unit/`)

Split `LeanFmtTest.lean`'s ~30 test functions into per-domain modules (`tests/Unit/Digest.lean`,
`…/Imports.lean`, `…/Config.lean`, `…/Edit.lean`, …) registered with the harness. The unit runner:

- runs tests with per-test names, isolation, timing, and `--filter`;
- can run independent tests concurrently (`IO.asTask`, pure tests only);
- keeps the argv subcommand utilities the suites call (`artifact-projection`,
  `verify-plugin-artifact`, …) — but each moves to the suite exe that actually uses it (Layer 2),
  so `lean-fmt-tests` shrinks to the pure unit tier.

`LeanFmtTest.lean` at root is deleted; its content lives in `tests/Unit/`.

### Layer 2 — per-suite exes + orchestrator

Each suite becomes a `lean_exe «suite-<name>»` with `srcDir := "tests"`, root
`Suites.<Name>` (`tests/Suites/<Name>.lean`), importing `Test.*`. Suites keep testing through the
real product binary (found as a sibling of `IO.appPath`: `.lake/build/bin/lean-fmt`) and keep
spawning `lake`/`git`/foreign tools where that *is* the surface under test — the change is that
the driver logic is Lean, not bash+python.

**`lean_exe «test-suites»`** is the orchestrator and the new `testDriver`:

- imports the unit tier and runs it in-process first (fast feedback);
- builds the selected suite exes in **one** up-front `lake build` invocation (removes both the
  per-suite rebuild overhead and the concurrent-build hazard `tests/modes` documents);
- executes suites by tag with bounded parallelism (`--jobs N`, default ≈ cores):
  - `parallel` — suites whose world is temp dirs / fixture projects with their own `.lake`
    (cache, downstream, catalog-with-temp-roots, …). Run concurrently.
  - `workspace` — suites that build fixtures or write scratch inside the main package workspace
    (compiler, check, native-layout, formatter, …). Serialized among themselves on a lock, but may
    overlap `parallel` suites. Mid-run `lake build` against the main package only happens here,
    one at a time.
  - `exclusive` — modes (`.lake` sensitivity), watch (this repo's git index). Run alone.
  - `slow` — stream (~7.5 min), performance, ci (committed-state), downstream, lsp-acceptance,
    editor, security-bench. Excluded from the default set.
- prints the one-line-per-suite PASS/FAIL + seconds summary and the "slowest suites" tail
  (run-all.sh's UX, kept); per-suite full logs under a scratch dir printed on failure.

**`lake test` runs the default set** = unit tier + all non-`slow` suites.
`lake exe test-suites -- --all` adds the slow set; `--suites check cache` selects;
`--list` enumerates. Direct iteration stays possible: `lake exe suite-check -- --filter layout`.

### lakefile.lean changes

- `testDriver := "lean-fmt"` → `testDriver := "test-suites"` (the guillemet note stays accurate).
- Add `lean_lib TestSupport` and one `lean_exe` per suite. The lakefile stays the single registry
  of what a suite is — run-all.sh's filesystem enumeration disappears.
- Suite fixture `lean_lib`s stay as they are.

### Python fate

- Port `tests/formatter/oracle.py` (256 lines) into `Suites/Formatter.lean` as the admission
  oracle; it still drives the candidate as a subprocess.
- Port `tests/lossless/check_projection.py` (271) and `tests/style/expected_candidate.py` (26)
  into their suites.
- Port all inline heredocs to `Test.Json` / `Test.Golden` / hash helpers (`LeanFmt.Digest` is
  already the tested SHA-256).
- **Keep `tests/formatter/candidate.py`** (foreign adversary) and `tests/lsp/editor.lua` (Neovim's
  client; the editor suite becomes a Lean driver that spawns `nvim`).

### Fixture hygiene

Ports never mutate tracked files. Suites that today copy-restore via traps (modes, check,
application-formatter, cache, compiler, imports, native-layout, scale) copy fixtures to temp
scratch instead (or generate the scratch variants they already generate). Where in-place mutation
of a *fixture-project* file is the test (cache invalidation), the fixture project is copied to a
temp tree first. `tests/watch`'s §9.6 staged-file defect (fails on any staged `.lean` in this
repo) is fixed by pointing it at a temp fixture repository — the repair CLAUDE.md already assigns
to `ruff-20-acceptance`.

### CI

Add to `.github/workflows/lean_action_ci.yml` after lean-action: `lake test` (default set). Add a
`workflow_dispatch`-only job running `lake exe test-suites -- --all` for the slow set. (Nightly
scheduling can be a follow-up; manual trigger is the honest start given runner-minute costs.)

### Compatibility during migration

Until a suite's port lands and passes, its `tests/<name>/run.sh` stays authoritative. Each landed
port replaces `run.sh` with a 3-line shim (`exec lake exe suite-<name> -- "$@"`) so `run-all.sh`
and muscle memory keep working; shims and `run-all.sh` are deleted in the final step, and
CLAUDE.md/README/`docs/` testing references are updated in the same commit.

## Suite classification (initial; each port confirms its lane)

| lane | suites |
| --- | --- |
| `parallel` (temp worlds) | boundary, discovery, imports, lossless, style, syntax, suppression, format-suppression, validator, reporting, catalog, incremental, block-/collection-/command-/declaration-/term-/module-/application-formatter, layout, comments, cache, downstream† |
| `workspace` (serial in main pkg) | check, compiler, semantic, formatter, formatter-adapter, native-layout, scale, lsp |
| `exclusive` | modes, watch |
| `slow` (also tagged by lane) | stream, performance, ci, lsp-acceptance, editor, security-bench, downstream† |

† downstream is parallel-safe but slow (builds a second workspace) — `parallel`+`slow`.

## Files to modify

- `lakefile.lean` — testDriver, `TestSupport` lib, ~37 `lean_exe` suite/orchestrator declarations.
- **New** `tests/Test/{Harness,Proc,Golden,Json,Fixture,LspClient}.lean` — harness library.
- **New** `tests/Unit/*.lean` — split of `LeanFmtTest.lean`; root `LeanFmtTest.lean` deleted.
- **New** `tests/Suites/*.lean` — one module per suite.
- **Delete** (final step): `tests/run-all.sh`, all `tests/*/run.sh`, `tests/lsp/{acceptance,editor}.sh`
  (as scripts — their logic moves to Lean), `tests/security/bench.sh`,
  `tests/formatter/oracle.py`, `tests/lossless/check_projection.py`,
  `tests/style/expected_candidate.py`. Keep `tests/formatter/candidate.py`, `tests/lsp/editor.lua`.
- `.github/workflows/lean_action_ci.yml` — add `lake test` step + manual slow-set job.
- `CLAUDE.md`, `README.md`, `docs/` — replace run.sh enumeration/invocation docs with the new
  commands; the "enumerate, don't list" rule becomes `lake exe test-suites -- --list`.
- `LeanFmt/AGENTS.md` — if it references test invocation (check during step 1).

## Steps

### Phase 1 — infrastructure + unit split

- [ ] Write `Test.Harness` (registration, assertions, isolation, `--list/--filter/--shard`),
      `Test.Proc`, `Test.Golden`, `Test.Json`, `Test.Fixture`.
- [ ] Split `LeanFmtTest.lean` into `tests/Unit/*.lean`; unit runner exe keeps the name
      `«lean-fmt-tests»` for now; delete the root file. `lake test` still green.
- [ ] Move argv subcommand helpers out of the unit exe toward their consuming suites
      (each moves with its suite in Phase 3; until then they stay callable).

### Phase 2 — orchestrator + pilots

- [ ] `Test.LspClient` factored from `tests/lsp/Acceptance.lean`.
- [ ] `lean_exe «test-suites»` orchestrator (tags, lanes, `--jobs`, one up-front build, summary
      UX); becomes `testDriver`.
- [ ] Pilot ports, one per kind:
  - [ ] `boundary` — pure repo-hygiene logic (validates harness + git spawning).
  - [ ] `incremental` — already near-native (validates the subcommand-absorption path).
  - [ ] `block-formatter` — simple CLI-assertion suite with a fixture file.
  - [ ] `cache` — temp/fixture-project lane (validates `parallel` lane + own-`.lake` builds).
  - [ ] `compiler` — fixture-lib + `leanFmtArtifact` facet rebuilds (validates `workspace` lane).
- [ ] Each pilot: old run.sh kept as shim; new exe's pass/fail compared against the old script on
      the same tree; one deliberate product breakage per pilot to confirm the port still fails.

### Phase 3 — batches (each batch: port, shim, verify, commit)

- [ ] Batch A (`parallel`, mechanical): block/collection/command/declaration/term/module/
      application-formatter, layout, comments, style, syntax, imports, suppression,
      format-suppression, validator, boundary… (remainder), lossless (port `check_projection.py`),
      reporting (golden JSON via `Test.Golden`), catalog, discovery, incremental.
- [ ] Batch B (`workspace`): check, semantic, formatter (port `oracle.py`; keep `candidate.py`),
      formatter-adapter, native-layout, scale, lsp (python client → `Test.LspClient`).
- [ ] Batch C (`exclusive`): modes (temp-copy fixtures; largest single port), watch (temp fixture
      repository; fixes the staged-file defect).
- [ ] Batch D (`slow`): stream, performance (incl. `negative.sh` → native gate-failure proofs),
      downstream, ci (stays committed-state; Lean driver for clone/archive recipes),
      lsp-acceptance, editor (Lean driver spawning nvim), security-bench.

### Phase 4 — cleanup + CI

- [ ] Delete run-all.sh and all shims; delete ported `.py` files.
- [ ] CI: `lake test` step; `workflow_dispatch` slow-set job.
- [ ] Update CLAUDE.md (suite enumeration, per-suite notes move into the relevant
      `tests/Suites/<Name>.lean` docstrings), README.md test section, `docs/` references.

## Verification

- **Per-suite parity** (the core gate): for every ported suite, (1) the new exe passes on the
  unchanged tree where the old script passed; (2) assertion inventory is preserved — each `ok`/
  `assert`/`run_expect`/python-assert in the bash maps to a named test, and the port's `--list`
  count is compared against the old script's check count during review; (3) mutation spot-check —
  deliberately break one behavior the suite guards (the `negative.sh` discipline, already repo
  practice) and confirm the port fails.
- **Gate semantics**: `lake test` green on a clean tree; `lake exe test-suites -- --all` green;
  `lake exe test-suites -- --list` enumerates exactly the suites; a suite name typo errors.
- **Parallelism honesty**: `--jobs 1` vs `--jobs 8` produce identical pass/fail and identical
  golden bytes; no `.lake` or `.lean-fmt-cache` corruption after repeated parallel runs (run the
  sweep 3× at `--jobs 8`).
- **Timing**: record default-set wall time before/after on the same machine; the slowest-suites
  tail is printed by the orchestrator for the record.
- **CI**: the new `lake test` step runs green on the PR that lands Phase 4.
