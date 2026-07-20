# RSF-IMPL — stdin/stdout and syntax-aware ranges

Claim: **RSF-IMPL** — reuse snapshot analysis and the layout source map to add stdin/stdout and range
formatting, exact validation, actual-range reporting, and deterministic errors.

Freeze followed: `notes/01-stream-range.md`. Owning suite: `tests/stream/run.sh` (30 assertions).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/stream/run.sh
tests/printer/run.sh
tests/layout/run.sh   tests/check/run.sh   tests/modes/run.sh
tests/service/run.sh  tests/discovery/run.sh   tests/boundary/run.sh
git diff --check
experiments/run-projection-shape.sh && python3 experiments/check-quoted-figures.py
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (44 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/stream/run.sh` | `failures=0` (30 assertions) |
| `tests/printer/run.sh` | `failures=0` — including the byte-for-byte corpus round trip |
| `tests/layout/run.sh` | `failures=0` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/discovery/run.sh` | `failures=0` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `git diff --check` | no output |
| quoted-figure gate | `quoted figures agree … (33 checked)` |

## What shipped

Four pieces, in dependency order, each a separate commit.

1. **`1d71424` — the source map is populated.** `Tree.document` wraps each layout unit — the header,
   each command, the tail — in a `Doc.mark`; `Printer.formatWithMap` keeps the map `Doc.render` already
   returned, and `format` becomes the text-only façade over it. One render, two accessors, not a second
   printer path. `mark` carries no width, so no output byte moves; `tests/printer/run.sh`'s corpus round
   trip is what says so rather than the claim itself. `normalizeEof` rewrites the output's tail alone,
   so only the final mark needs its output end clamped.

2. **`fc3d62b` — `Application.sliceRange`.** Unit selection, the forward extension, the actual range,
   and the splice. Nothing in it parses: the bytes emitted for a unit are the bytes whole-file `format`
   produced for that unit, sliced out of one whole-file render. The roadmap's "never slice arbitrary
   bytes and parse them as an exact module" is therefore unreachable here, not merely obeyed.

3. **`Project.unsavedTarget` and `Project.loadWorkspaceOnly`.** The freeze's §8.3 obligation: bytes and
   a path in, `SourceTarget` out, every `snapshotTarget` gate applied in the same order with the same
   messages naming the caller's own argument, and no filesystem read for content. `loadWorkspaceOnly`
   exists because `ExactRun` reads only `workspace`/`root` from a `Snapshot`: a one-shot stdin request
   must not pay to select the whole project the way the service does once per session.

4. **`Application.stream` and the CLI surface.** `-`, `--stdin-filename`, `--range`, `--range-lines`,
   `renderStream`, `streamExitCode`. `stream` is a separate operation from `execute` rather than a flag
   on it, because almost every clause of a batch run is wrong for one unsaved buffer — no selection to
   discover, no cache to consult, no file to publish, one target.

## Evidence for the frozen claims

Each of these was run by hand first and is now an assertion in `tests/stream/run.sh`:

- **Writes nothing.** Naming a real tracked file (`tests/check/Layout.lean`) leaves its digest
  unchanged, and no `.lean-fmt-cache` directory appears. `publishAtomic` and `ResultCache` are not
  reachable from `stream`.
- **Identity gates hold through the pipe.** `../evil.lean`, `.lake/build/x.lean`, and `notes.txt` are
  each rejected with the message the file path form gives, naming the caller's own argument.
- **Range expansion reports wider than asked.** `--range 30:49` over the fixture reports
  `formatted range 30-51`: the unit owns its trailing trivia through the blank line (§4.3).
- **Full-range equivalence.** `--range 0:78` is byte-identical to the whole-buffer format.
- **A broken buffer streams zero bytes** and exits 1 — not partial bytes, not the input echoed back.
- **CRLF round-trips**; **codepoint columns** resolve past multibyte text (`3:18` over
  `namespace     αβγ` → byte 28, the clamped end of a 17-codepoint/20-byte line).

## Decisions changed during execution

- **`--json` gained `formatted`/`diff`.** The first cut put the bytes only on the bare stdout path, so
  a `--json` consumer received a source map describing text it had not been given and would have had to
  run the command twice. The field is named to match `FileReport.formatted`.

- **The idempotence assertion was wrong on first run, and the failure was real.** Re-running the
  *requested* range over the output is not a fixed point: formatting changes the unit's length, so byte
  30:49 of the output names a different region than it named in the input — here it reaches into the
  next command and formats that too. The freeze already said this (§5); the suite had asserted the
  convenient version anyway. It now asserts the true one, in the coordinates where it holds: re-running
  the range the source map reports the unit *now* occupies, which is what an editor holding that map
  would send. The false assertion is documented in the suite so it is not reintroduced.

- **`--stdin-filename` resolves `module?` from the real path when the file exists.** A saved-but-edited
  buffer then keeps its on-disk twin's module identity and gets the same exact Lake setup; a path with
  nothing behind it takes the standalone route `diagnosticSetup` already served.

- **`resolveLexically` drops a `..` that would escape an absolute root** rather than letting it climb,
  so `insideRoot` stays meaningful on `<root>/../etc` without a `realPath` that an unsaved path cannot
  have.

## Files changed

| File | Change |
| --- | --- |
| `LeanFmt/Printer.lean` | unit marks in `Tree.document`; `formatWithMap`; `format` as façade |
| `LeanFmt/Application.lean` | `sliceRange` + selection; `StreamRequest`/`StreamReport`/`stream` |
| `LeanFmt/Project.lean` | `resolveLexically`, `unsavedTarget`, `loadWorkspaceOnly` |
| `LeanFmt/Cli.lean` | `RangeSpec` parsing, `-`/`--stdin-filename`/`--range*`, `validateStdin`, `renderStream`, `streamExitCode` |
| `LeanFmtTest.lean` | `testRangeSelection`; the §4 boundary characterization (RSF-SPEC) |
| `tests/stream/run.sh` | new — the owning acceptance suite |
| `CLAUDE.md` (`AGENTS.md` symlink) | the new suite in the build list |
| `docs/projects/ruff-03-language-formatting/*` | corpus figures regenerated (see below) |

## Remaining uncertainty

- **The forward extension has not been observed firing on real code.** It is exercised by the synthetic
  selection test and reasoned from the measured `fits` behavior, but no fixture in the suite is a
  same-line command pair. `RSF-FINAL` owes one, plus a count of how often it fires on the frozen sample.
- **`normalizeEof`-at-the-tail is still only argued, not measured.** The suite covers full-range and
  mid-file ranges but not a range that ends exactly at the last unit boundary of a file lacking a final
  newline. `RSF-FINAL` owes that fixture.
- **No custom-syntax or `#exit`-tail fixture goes through the range path yet.** The tail is a unit like
  any other in `Tree.document`, but that is untested here; `RSF-FINAL` names both.
- **Header-only ranges** on a file whose header does not parse cleanly report an actual range and change
  nothing (`headerDoc?` refuses on any parser message). Still unfixtured.
- **No scale measurement.** A stdin request loads the workspace and runs one exact frontend child; the
  cost is one file's, but it has not been timed against the batch path. `RSF-FINAL` should record it.

## Standing tax

This repository is the printer's own corpus, so **every** production edit shifts
`ruff-03/evidence/01-projection-shape.txt` and the 33 prose figures `experiments/check-quoted-figures.py`
holds to it. It fired twice during this prompt. Regenerate with `experiments/run-projection-shape.sh`
and reconcile before `tests/printer/run.sh`, or the suite fails on stale evidence rather than on
anything this stack did.
