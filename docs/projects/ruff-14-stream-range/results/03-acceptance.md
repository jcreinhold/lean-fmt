# RSF-FINAL — boundary stability and pipeline behavior

Claim: **RSF-FINAL** — test UTF-8 positions, empty ranges, comments, custom syntax, nested nodes,
malformed input, pipes, broken stdout, full-range equivalence, reflow-expanded ranges, and repeated
range idempotence.

Owning suite: `tests/stream/run.sh`, now 61 assertions (30 from `RSF-IMPL`, 31 added here).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
lake exe lean-fmt-tests
tests/stream/run.sh
experiments/run-range-unit-census.sh          # frozen mathlib sample, 62 modules
tests/printer/run.sh  tests/layout/run.sh  tests/check/run.sh  tests/modes/run.sh
tests/service/run.sh  tests/discovery/run.sh  tests/boundary/run.sh  tests/suppression/run.sh
tests/lossless/run.sh  tests/scale/run.sh  tests/syntax/run.sh  tests/compiler/run.sh
git diff --check
experiments/run-projection-shape.sh && python3 experiments/check-quoted-figures.py
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (47 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/stream/run.sh` | `failures=0` (61 assertions) |
| `tests/printer/run.sh` | `failures=0` |
| `tests/layout/run.sh` | `failures=0` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/discovery/run.sh` | `failures=0` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/lossless/run.sh` | `the oracle rejected all 13 mutations` |
| `tests/scale/run.sh` | `lean-fmt complete-selection and module-evidence tests passed` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `tests/compiler/run.sh` | `lean-fmt compiler facet tests passed` |
| `git diff --check` | no output |
| quoted-figure gate | `quoted figures agree … (33 checked)` |

## The measurement this prompt existed for

**The forward extension never fires on the frozen mathlib sample: 2,854 layout units across 62
modules, 0 of them extending** (`evidence/03-range-unit-census.txt`, `experiments/run-range-unit-census.sh`,
`lean-fmt-tests range-units`). Every unit with something after it ends at a line boundary.

That is not an argument for deleting the clause — it is the strongest available argument for keeping
it. The clause exists because `Doc.fits` walks the *tail* of the work list, so a unit not ending in
newline-bearing trivia can be rebroken by what follows it. The census says idiomatic Lean never puts a
range in that position, which means the clause costs nothing on real source; it also means the only
inputs that reach it are the ones nobody writes and nobody would think to test — exactly where a range
would silently rewrite bytes it reported as untouched. It is now fixtured on real source rather than
on a `Doc` probe: `def a := 1 def b := 2` is four units, a range over `8:18` reports `8-30`, and the
suite additionally asserts *why* — the first unit's last rendered byte is a space.

The census instrument reads the count off the product's own `Printer.formatWithMap`, not a
reimplementation of the rule, so a drift in the printer moves the number.

## Cost

`evidence/03-stream-cost.txt`. **A range costs what the whole buffer costs** — the spread between the
two is inside the run-to-run spread of either. The cost of a stream request is one exact frontend run
over the whole buffer, which a range cannot avoid without giving up exactness. Range formatting is a
precision feature, not a speed one, and nothing in the product says otherwise.

A stream request also costs about what the batch path costs for the same single file with the cache
cleared (1.6s against 1.7s on `LeanFmt/Doc.lean`): `loadWorkspaceOnly` buys back what a one-file batch
run spends selecting the project, and does not make the frontend cheaper. Net of 0.44s `lake exe`
overhead, 13.9 KB costs ~1.1s and 96 KB ~3.6s — 6.9× the bytes for 3.2× the time, because the work is
elaboration rather than layout.

## What the acceptance cases found

- **Custom syntax survives a range that excludes its declaration.** A `notation` command and a later
  command using it: formatting only the user keeps `1 ⊕ 2` and leaves the command after it untouched.
  This is the exactness property a range must not break, and it holds for the structural reason —
  the whole buffer is analyzed and only the slice is emitted.
- **The `#exit` tail is a unit like any other.** `0-8 8-25 25-56`: the modelled region ends where the
  terminal *begins*, and `this is not lean at all` streams back verbatim.
- **`normalizeEof` at the tail, now measured.** A 23-byte buffer with no final newline, ranged over its
  last unit, streams back `b'module\n\ndef x   :=   1\n'` — the newline appears because the selection
  includes the tail, which is the only condition under which it may.
- **An empty range is a cursor**: `--range 30:30` selects the one unit containing the position and
  reports `30-51`.
- **A range inside a nested node widens to its command.** Six bytes naming `x := 0` inside a structure
  instance report `51-99`. The lattice is command-granular by construction; there is no finer unit.
- **Header-only ranges work on a real header**: `--range 0:20` reports `0-51`, formats both imports,
  and leaves the body alone.
- **Comment ownership, asserted rather than left to be rediscovered.** `0-8 8-54 54-70 70-70`: the
  comment written *above* `def b` is inside `def a`'s unit. That is the frozen `RLC-SPEC`
  trailing-greedy verdict, it surprises people, and it means a range over `def b` does not include the
  comment a reader would say belongs to it.
- **Piping the tool into itself is a fixed point.**

## Decisions changed during execution

- **Invalid UTF-8 on stdin was emitting the Lean runtime's wording, not the frozen one.** §6 fixes the
  message at `stdin is not valid UTF-8`; `IO.FS.Stream.readToEnd` was throwing
  `Tried to read from stream containing non UTF-8 data` into the generic handler. `runStreamCommand`
  now reads bytes and decodes explicitly. A diagnostic the contract fixes must not be an incidental
  runtime phrase — this is a real freeze violation that shipped in `RSF-IMPL` and no test caught,
  because `RSF-IMPL` never tested it.

- **The `fix -` assertion was asserting `format`.** The first draft expected `fix - ` to canonicalize
  the layout. It does not, and must not: `fix` publishes admitted rule fixes at *original* coordinates
  (`AGENTS.md`), so a buffer with no admitted fix streams back unchanged. The suite now asserts that.

- **`--range` was accepted and silently disregarded by `check`, `diff`, and `fix`.** The help text
  already said "format only"; the parser did not enforce it, so `diff - --range 30:49` produced a
  whole-file diff with no sign the flag had been dropped. `format` is the only mode that emits a
  layout — `check` reports findings over the whole buffer, `fix` applies admitted fixes at original
  coordinates — so there is nothing for the others to narrow, and accepting the flag answered a
  narrower question than the caller asked. `validateStdin` now takes the mode and rejects it. Found by
  the audit pass, not by any earlier test.

- **Broken stdout is exit 2 with a `broken pipe` diagnostic**, which is what §6's "infrastructure"
  column already says. Characterized rather than changed: with a ~500 KB buffer and a reader that exits
  after one line, the run reports `lean-fmt: resource vanished (error code: 32, broken pipe)` and exits
  2 — not a crash, and not a silent 0 that would tell a caller its bytes were delivered when they were
  not.

## Files changed

| File | Change |
| --- | --- |
| `LeanFmt/Cli.lean` | explicit stdin decode for §6's UTF-8 message; `--range` rejected for non-`format` modes |
| `README.md` | new "Streaming and ranges" section |
| `LeanFmtTest.lean` | `range-units` census subcommand |
| `tests/stream/run.sh` | +31 acceptance assertions |
| `experiments/run-range-unit-census.sh` | new — the frozen-sample census driver |
| `docs/projects/ruff-14-stream-range/evidence/03-range-unit-census.txt` | new |
| `docs/projects/ruff-14-stream-range/evidence/03-stream-cost.txt` | new |
| `LeanFmt/Printer.lean`, `docs/projects/ruff-03-language-formatting/*` | corpus figures reconciled |

## Remaining uncertainty

- **The census is one width (80) and one corpus.** A narrower margin makes more units end mid-line in
  principle; the number 0 is a fact about the frozen sample at the default width, not a theorem. The
  driver takes the width as an argument, so re-running it is the way to answer that rather than
  reasoning about it.
- **The census counts unit boundaries, not requests.** It says how many places a range *could* trigger
  the extension, not how often editors will. Nothing in this product can answer the second question
  yet; `ruff-17-lsp` is where real request traffic first exists.
- **UTF-16 positions are still `ruff-17-lsp`'s.** The codepoint-column path is fixtured here; no
  UTF-16 code path exists to test.
- **Timings are single-machine, three runs, wall clock.** They are the right shape to support "a range
  is not cheaper" and too coarse to support anything finer.
