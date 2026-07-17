# RFX-FINAL — Adversarial fix-all verification

**Verified.** This is the acceptance prompt for the fix-safety stack. It adds persistent adversarial
regression tests and changed **no production module** — the correct footprint for a verification prompt.
The applicability model built under `RFX-IMPL` holds against mixed insert/delete/replace conflicts,
multi-edit transactions, UTF-8 boundaries, comment preservation, promoted/demoted applicability, stale
files, and a crash between validation and the committing rename.

## The headline

**Every applied edit still carries rule provenance and validation evidence, and no adversarial input
gets past the transaction.** The two verified invariants (`prompts/03-acceptance.md` Stop):

- *Provenance.* A conflict now names the two rule codes and finding ranges; an intra-fix conflict names
  the same fix on both sides (`LeanFmtTest.lean:testFixAllAdversarial`). No applied edit is anonymous.
- *Validation evidence.* `preparePatch` validates ranges, UTF-8 boundaries, and conflicts as one
  transaction before any output exists; `publishAtomic` re-reads the source and commits only at
  `rename`. Nothing half-applies.

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                       # exit 0 (36 jobs)
LEAN_NUM_THREADS=1 lake build lean-fmt-tests        # exit 0
.lake/build/bin/lean-fmt-tests                      # "module-artifact tests passed"
bash tests/modes/run.sh                             # "product mode integration tests passed"
bash tests/boundary/run.sh                          # "native module and dependency boundary passed"
git diff --check                                    # no output
check_stack.py    docs/projects/ruff-06-fix-safety --structural   # OK: 3 prompts, 0 warnings
write_next.py --check docs/projects/ruff-06-fix-safety            # matches first_unresolved=none
```

Environment: base commit `0700017`, `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No performance
claim: the additions are tests. `tests/check`/`tests/service` were not rerun as gates — no module they
cover changed under this prompt (only `LeanFmtTest.lean` and `tests/modes/run.sh`), and both were green
under `RFX-IMPL` one commit earlier. Complete mathlib was not run, per the Stop rule.

## What was exercised

**1. Mixed insert / delete / replace (`testFixAllAdversarial`).** An insertion strictly inside a
replacement range is a `conflict`; an insertion at a replacement's exact end boundary composes
(`X!c`); a deletion beside a replacement composes (`Xcd`). This closes the gap `testEdits` left: it had
replace-vs-replace overlap and insert-vs-insert, but not insert-vs-replace or the delete/replace mix.

**2. Multi-edit fixes as one transaction.** A single `Fix` with two disjoint edits applies together
(`XbYd`) and reverts exactly; a single `Fix` with two overlapping edits is rejected, and the conflict
names that fix (`MULTI`) on both sides — proving intra-fix edits share the one validation/conflict
transaction rather than being trusted because they came from one rule.

**3. Applicability is never an edit property.** The same edit under `.safe` and under `.unsafe`
assembles to byte-identical output. Promotion/demotion changes admission (which `fix` applies),
upstream of the assembler; it cannot change what an applied fix produces. `.displayOnly` admission is
covered in `testApplicability` (never admitted, even promoted).

**4. Comment loss.** FMT001 on `def x := 1 -- c  \n` strips the trailing whitespace that trails the
comment but leaves `-- c` intact. A safe fix edits trivia even when trivia sits after comment text; it
never eats the comment. This is the byte-level meaning of "safe" from `notes/01-model.md` §1, tested on
a comment rather than asserted.

**5. UTF-8 boundaries.** The `testEdits` reversibility sweep over `aαβz` at every codepoint boundary
with `""`/`"x"`/`"λ"` replacements already covers single-edit boundary safety; the new multi-edit and
mixed cases run on ASCII where the conflict geometry is the variable under test. Non-boundary offsets
are rejected (`invalidBoundary`), unchanged from `RFX-IMPL`.

**6. Stale files and crash-before-rename (`tests/modes/run.sh`).** The existing stale-hook (concurrent
append → `source changed after analysis`, no write) is joined by a crash-hook that fails after the temp
file is written but before `rename`, standing in for a process death at that instant. The target keeps
its exact bytes/mtime/mode, the run is an infrastructure failure (exit 2), and no `.lean-fmt-tmp-*` file
is orphaned beside the source — because `rename` is the single atomic commit point and the `catch`
removes the temp.

## Decisions changed during execution

**No production code changed, and that was the correct outcome to confirm rather than a shortfall.**
The plan step 3 ("implement the smallest deep capability… remove superseded paths") had nothing to
implement: `RFX-IMPL` already threaded provenance and validation through the one transaction, so
`RFX-FINAL`'s job was to *attack* it. Every adversarial case passed against the existing code on first
run; none exposed a gap needing a production fix. The evidence is the new tests, which fail if any of
those properties regress.

**Formatter composition for syntax-tier fixes was not fabricated.** The note §3 specifies that a
syntax-tier fix composes by re-projecting canonical text, but no shipped rule is syntax-tier. Writing a
fake syntax rule to "exercise" composition would be a shim the stack's stop rules forbid; the canonical-
coordinate path is already proven for text-tier fixes by the layout/findings cases in `tests/modes`.
This is carried as uncertainty, not claimed as verified.

## Files changed

```
LeanFmtTest.lean         testFixAllAdversarial; findingWithEdits helper
tests/modes/run.sh       crash-before-rename case
docs/projects/ruff-06-fix-safety/{results/03,prompts/03,state/current,state/next}
```

## Checks read

Every suite above passed. `git diff --check` is silent. The structural checker reports 3 prompts, 0
warnings, no errors, and `write_next.py --check` matches with the stack complete
(`first_unresolved: none`). With this prompt verified, all three claims (`RFX-SPEC`, `RFX-IMPL`,
`RFX-FINAL`) are verified and the fix-safety stack is closed.

## Remaining uncertainty

- **Syntax-tier fix composition** stays specified and unexercised until a syntax-tier rule ships (a
  future stack). Its adversarial cases — a fix moving tokens under formatter re-projection — belong to
  that stack, with a real rule to drive them.
- **Multi-edit producers.** The multi-edit transaction is now attacked from tests, but no shipped rule
  emits more than one edit per fix; the first real producer (plausibly `ruff-09`) should add a rule-
  level case beside these synthetic ones.
