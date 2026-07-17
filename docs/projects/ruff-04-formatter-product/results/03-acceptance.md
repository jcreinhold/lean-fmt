# RFP-FINAL — Establish stable formatter behavior

**Verified.** This records what was run, what it showed, and what changed while running it.

## The headline

**The product and the printer agree byte for byte on foreign Lean.** Over the frozen mathlib sample,
the printer harness (test binary, width 80) reformats 12 modules and the product (product binary,
width 100) reports 12 `would-format`. The sets are identical, and the outputs are **12 byte-identical,
0 differing** (`evidence/06-frozen-sample.txt`).

That is not a restatement of RFP-IMPL's wiring test. The two reach a syntax tree by different routes —
the harness parses the tree directly, the product goes through the exact frontend, because mathlib
registers no `leanFmtArtifact` facet — and they run at different widths. Agreement across both is the
first evidence from Lean nobody wrote for this project that **RFP-SPEC's margin proof holds in
practice**: `Doc.go` reads the margin only at the `.group`/`.brk` fit test and `Printer.lean` builds no
`group`, so 80 and 100 must produce the same bytes. On this repository that prediction is cheap — the
corpus is already canonical, so most files do not move. On 12 mathlib modules the printer actually
rewrites, it is not cheap, and it holds.

## The contract, item by item

| RFP-FINAL requires | where | result |
| --- | --- | --- |
| command matrices | `evidence/07-command-matrix.txt` | 3 fixtures × 4 modes, 12 cells, every one a run |
| formatting goldens | `tests/modes/run.sh` | exact JSON and exact diff text, persistent |
| idempotence | `evidence/06` | 12/12 at width 100 on the product's own mathlib output |
| syntax/elaboration validation | `evidence/06`, `tests/modes/run.sh:278` | frontend accepted 12/12; rejection path tested |
| cache invalidation | `tests/modes/run.sh:200-222` | a `check`-populated entry is a miss for `format` |
| frozen-sample timing | `evidence/06` | 250.97 s real, 1.58 GB max RSS, 62 modules |
| stable style policy + migration | `notes/02-stability.md` | published |

**Idempotence is measured, not argued.** `format(format(x)) = format(x)` — each of the 12 outputs was
re-analyzed from scratch and re-formatted: `idempotent = 12, not = 0`. No mathlib file was written to;
`__analyze-exact`'s separate source and display paths let the product's output be analyzed while
resolving as the original module. `git status` in mathlib4 is clean and the `.lean-fmt-cache/` these
runs left there was removed.

**The frontend accepting all 12 is the syntax check.** Printer output that did not parse would fail
there, not pass quietly. That is a real check on real output, and it is stronger than the golden.

## Decisions changed during execution

**1. The command matrix asks a question the goldens do not, and it changed what the policy note says.**
Running all 12 cells rather than the 3 the modes suite pins put `Layout.lean check = 0` next to
`Layout.lean format = 1` in the same table, on the same bytes. Read as a matrix that looks like an
inconsistency, and it is the thing a user hits first. It is not one — formatting is not a rule, so it
cannot make `check` exit 1 — but "not a bug" is not an answer to someone whose CI just went red.
`notes/02-stability.md §4` now leads with it: the migration is `check`, which cannot move under this
change and is stricter besides. The matrix is what turned a defensible design into an instruction.

**2. `cacheHitServes` was a single point of failure with no test.** Found by asking what the cache does
with an entry `check` wrote, which nothing in the suite covered. `check` takes the source-only shortcut
and stores no canonical text. Serve that entry to `format` and `prepareFile` lands on the
`renderCanonical = true`, `canonical? = none` path, where it silently bases the patch on the file's own
bytes and consults no layout — **RFP-SPEC's "format does not format", reintroduced through the cache**,
reporting `clean` at exit 0. Indistinguishable from a file that needs nothing. `cacheHitServes`
(`Application.lean:371`) was the only thing standing there and had no persistent test; it does now
(`tests/modes/run.sh:200-222`).

**3. Every toolchain citation in this stack was checked against the wrong toolchain.** `find
~/.elan/toolchains ... | head -1` returns v4.31.0; this project is pinned to **v4.32.0**. Every Lake
claim was re-read in v4.32.0. The three load-bearing ones survive — `Run.lean:275` (`noBuildCode`),
`:368` (`IO.Process.exit`), `:405-414` (`checkNoBuild`) are identical in both. One did not:
`lake shake`'s guard is `Lake/CLI/Main.lean:1057` in v4.31.0 and **`:1113`** in v4.32.0.
`evidence/03-nobuild-exits-the-process.txt` was regenerated against the correct toolchain, and
`results/02-integration.md` and `state/current.md` corrected. RFP-IMPL's commit message still carries
`:1057` and cannot be rewritten; the correction is recorded rather than quietly fixed.

## Commands run

```
$ LEAN_NUM_THREADS=1 lake build                # Build completed successfully (36 jobs)
$ bash tests/modes/run.sh                      # lean-fmt product mode integration tests passed
$ bash tests/check/run.sh                      # lean-fmt check integration tests passed
$ bash tests/boundary/run.sh                   # native module and dependency boundary passed
$ bash tests/printer/run.sh                    # failures=0
$ python3 experiments/check-quoted-figures.py  # quoted figures agree with evidence (33 checked)
$ git diff --check                             # (silent)
```

The frozen-sample run was one `format --root . --json --no-cache` invocation over all 62 paths from
`experiments/workloads/mathlib-v4.32.0-sample.txt`, under `/usr/bin/time -l`, against a prebuilt
mathlib `.olean` tree. Full provenance — machine, toolchain, lean-fmt and mathlib commits, cache and
build state — is the header of `evidence/06-frozen-sample.txt`; it is the locator rather than a
reconstruction here because that file recorded the run and this note did not.

```
changed=12  findings=0  broken=0  rejected=0  files=62  infrastructureFailures=[]  exit=1
250.97 real  204.12 user  143.41 sys   1584070656 maximum resident set size
```

**251 s is the slow path by construction, not a regression.** mathlib registers no `leanFmtArtifact`
facet, so `officialArtifacts` finds no facet config, misses in order, and all 62 modules are parsed by
the exact-frontend fallback. The printer is not the cost; the frontend is. RFP-IMPL's open question
about `Lean.Diff.diff`'s envelope is answered by the same run — it is not visible in either number.

## The checks are non-vacuous

Asserted by mutation, per the house standard. **One mutation was run for this prompt** — the check this
prompt added:

| mutation | result |
| --- | --- |
| make `cacheHitServes` return `true` unconditionally | **caught** — `expected exit 1, got 0` |

It reproduces the exact failure described in decision 2, and its symptom is worth naming: the mutated
build reports `clean` at exit 0 — a **silent** wrong answer, not a crash. That is why the test asserts
on `changed`, `status`, and the exact `formatted` bytes rather than on the exit code alone.

RFP-IMPL's mutations (`checkNoBuild`, `unifiedDiff`, `DiffLine`, fixture canonicalization) are recorded
in `results/02-integration.md` and were **not** re-run here. The suites they guard pass, which shows the
tests still exist and still pass — not that they would still catch those mutations. Re-asserting that
would mean re-running them, and this note does not claim it.

## Remaining uncertainty

- **The sample is a frozen list of paths, not frozen content.** `mathlib-v4.32.0-sample.txt` was pinned
  by `RLS-FINAL` and all 62 paths resolve (`skipped=0`), so the sample is intact and the measurements
  are real — but they were taken against a `master-2026-07-14` checkout (`783ccda4ee5`), so they
  measure that commit. Nothing in this repository pins mathlib's content.
- **62 modules, not 8,795.** Full mathlib is forbidden by this prompt and was not run. Whether 12/62
  (19%) generalizes is unmeasured, and this stack did not re-audit why `RLS-FINAL` chose these 62.
- **Whether `fix` can take a cache hit.** Open since RFP-SPEC and still unmeasured. `--no-cache` was
  used for the frozen-sample run to isolate the measurement, and the new cache test covers `format`.
- **`format` has never been observed rejecting its own output.** The elaboration-rejection path is
  tested with a stub validator (`LEAN_FMT_TEST_VALIDATOR`) because the printer has never produced text
  that fails. The path works; that it is needed is not something anyone has evidence for.
- **Whether the non-overlap of FMT rules and layout survives a third rule.** Unchanged from RFP-SPEC.
  Nothing enforces that a future rule stays out of the printer's way.
