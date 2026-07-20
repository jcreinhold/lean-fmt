# RSF-SPEC — stream identity and range expansion

Claim: **RSF-SPEC** — specify CLI forms, filename requirements, position encoding, enclosing-node
selection, comment ownership at boundaries, diagnostics, exit codes, and cache/write policy.

Freeze: `notes/01-stream-range.md`. Baseline: `evidence/01-stream-range-baseline.md`. Probe:
`evidence/01-unit-independence-probe.lean`.

Per the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC), no production
Lean interface, config key, or CLI surface shipped. What shipped besides documentation is one
characterization test.

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/layout/run.sh
tests/boundary/run.sh
git diff --check
lake env lean --run docs/projects/ruff-14-stream-range/evidence/01-unit-independence-probe.lean
uv run .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural   # from kan-proofs
uv run .claude/skills/lean-plan/scripts/write_next.py <workspace> --check         # from kan-proofs
```

Baseline characterization (raw output in `evidence` §1):

```sh
run() { out=$(lake exe lean-fmt "$@" 2>&1 >/dev/null); code=$?; \
        printf '$ lean-fmt %s\nstderr(first line)=%s\nexit=%s\n\n' "$*" "$(printf '%s' "$out" | head -1)" "$code"; }
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (44 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` (includes `testDoc`, `LeanFmtTest.lean:2405`) |
| `tests/layout/run.sh` | `failures=0`; `modules_checked=22 comments_attached=549 dangling=0` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved=…` |

## What the baseline established

1. **There is no stdin or range surface at all.** `format -`, `format --stdin-filename X.lean`,
   `format --range 0:10`, and `check -` are each rejected by `parseFileArgs`'s catch-all with
   `unknown option: …` and exit 2. Measured, not inferred.

2. **The layout source map is sound and never populated in production.** `Doc.mark`/`Mark`/`Doc.render`
   all work and are unit-tested, but `Printer` emits no `.mark` anywhere and `Printer.format` calls
   `renderText`, which discards the map. The roadmap tells RSF-IMPL to "reuse the layout source map";
   the accurate statement is that RSF-IMPL must **populate** it first. Recorded as an explicit
   interface obligation (`notes` §8) rather than left to be discovered mid-implementation.

3. **Reflow stability is a property of `Doc.fits`, not of commands.** This is the load-bearing finding.
   `fits` walks the *tail* of the work list, so a group at the end of a unit measures itself against
   what follows and can be rebroken by it. Exactly one construct stops the walk: a `verbatim` holding a
   newline, which `fits` treats like `hard` (`Doc.lean:174-176`). Measured at margin 10:
   a newline-terminated unit's bytes survive a 16-character tail; a space-terminated unit is rebroken
   by a **one-character** tail (`"aaaa bbbb "` → `"aaaa\nbbbb x"`).

   So the frozen expansion rule is not "expand to the enclosing command". It is "expand to the
   enclosing command, **then keep extending while the last unit does not end in newline-bearing
   trivia**". Without that second clause, `def a := 1 def b := 2` would let a range request rewrite
   bytes it reported as untouched.

4. **Comment ownership at extent boundaries is trailing-greedy**, from `RLC-SPEC`'s parser measurement
   (`nonempty_leading=0`, `verdict=trailing-greedy`). Trivia between two commands — including a comment
   block written *above* the next declaration — is inside the **earlier** command's extent.

## Decisions changed during execution

- **`--stdin-filename` is required, not optional.** Initially modelled on `ruff format -`, which falls
  back to defaults. Rejected after re-reading `ruff-13`: the effective configuration is a per-file fact
  resolved from the file's location, so a buffer with no location would silently get a different answer
  than the same bytes on disk. Requiring identity keeps stdin from becoming a second configuration path.

- **`--range` is stdin-only.** The roadmap's contract forbids reintroducing a file-target stdout escape
  hatch, and a partial in-place write would be a new write surface with new stale-check semantics and
  no named caller. `ruff-17-lsp` is the consumer that would want file-target ranges and it goes through
  the service. Recorded as a deliberate narrowing (`notes` §7.4), not an oversight.

- **§4.3 was rewritten after running `tests/layout/run.sh`.** That suite prints `own-line comments lead
  the next token`, which contradicted the first draft's ownership claim. It does not actually conflict:
  `Comments.partitions` re-splits the raw trailing run at the first newline for *placement*, while
  `Tree.commands` uses the unsplit run for *extents*. Both are true at different granularities. The
  note now says so explicitly and tells RSF-IMPL not to "reconcile" them by changing either — an
  apparent contradiction left unexplained is how one of them would later get edited.

- **Codepoint columns, not UTF-16.** Matches `Doc.width`'s frozen policy; UTF-16 is `ruff-17-lsp`'s to
  negotiate. Two entry encodings converging on one internal byte encoding is not two encodings.

- **A broken buffer streams nothing.** Not the input echoed back — a shell redirect would then write a
  broken buffer over a good file.

## Files changed

| File | Change |
| --- | --- |
| `docs/projects/ruff-14-stream-range/notes/01-stream-range.md` | new — the freeze |
| `docs/projects/ruff-14-stream-range/evidence/01-stream-range-baseline.md` | new — baseline + probe output |
| `docs/projects/ruff-14-stream-range/evidence/01-unit-independence-probe.lean` | new — the `fits`/tail probe |
| `LeanFmtTest.lean` | characterization test pinning the §4 boundary condition |
| `docs/projects/ruff-14-stream-range/prompts/03-acceptance.md` | repair — restored the roadmap's `reflow-expanded ranges` case |
| `docs/projects/ruff-14-stream-range/state/current.md` | repair — prerequisite list now matches the roadmap; RSF-SPEC verified |

## Remaining uncertainty

- **The unit lattice is frozen from `Tree.commands`' documented tiling property**, which
  `structurallyValid` enforces. It has not been re-measured on the frozen mathlib sample *for range
  purposes* — `RSF-IMPL` should confirm that the header/command/tail split reconstructs the file byte
  for byte on the sample before it splices anything.
- **Step 3's forward extension is unbounded in principle.** A file that is one long chain of same-line
  commands expands every range to the file end. Expected from the mechanism, and terminating (the tail
  always ends the chain), but no sample has been checked for how often step 3 fires at all. `RSF-FINAL`
  should report the count on the frozen sample.
- **`normalizeEof` applying only at the tail is a frozen decision, not a measured one.** No current
  caller renders a partial file, so there is nothing to characterize against; `RSF-IMPL` is the first
  code that can test it.
- **Header-only ranges on a recovering header** report an actual range and change nothing, because
  `headerDoc?` refuses on any parser message. Correct, and it needs a fixture in `RSF-FINAL`.
