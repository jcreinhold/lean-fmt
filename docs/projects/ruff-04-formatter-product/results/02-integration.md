# RFP-IMPL — Integrate formatter output and atomic publication

**Verified.** This records what was run, what it showed, and what changed while running it.

## The headline

**`format` formats.** RFP-SPEC's characterization test asserted the opposite — exit 0 and `clean` on a
file with `namespace     Alpha` — and existed to force this flip. It is flipped
(`evidence/04-format-now-formats.txt`):

```
$ lean-fmt format --root . --json --no-cache tests/check/Layout.lean
{"broken":0,"changed":1,"files":[{"diagnostics":[],"diff":null,"findings":[],
"formatted":"module\n\nnamespace Alpha\n\ndef layoutValue : Nat := 1\n\nend Alpha\n",
"path":"tests/check/Layout.lean","status":"would-format","written":false}],"findings":0,
"infrastructureFailures":[],"mode":"format","rejected":0,"written":0}
exit=1
```

`findings` is 0 and `changed` is 1, so the report cannot be explained by a lint fix. Only layout
moved. `check` on the same file is still `clean` at exit 0 — formatting is a canonical transformation,
not a selectable rule, so it cannot enter rule selection.

## How canonical text reaches a report

`SemanticResult` gained `canonical? : Option CanonicalText` and the schema went to
`lean-fmt.semantic-result.v2`. Rendering is application-side: the boundary pins the plugin's imports
to `ArtifactModel`/`Rules` (`tests/boundary/run.sh:45-47`), so the plugin cannot reach the printer.

**The interface, designed twice.** *Design A: render on demand, cache nothing.* `format` fetches an
artifact and renders. Simple, and it fails a test RFP-SPEC left standing: `tests/modes/run.sh` demands
a semantic-cache hit serve `format` with artifacts disabled and no analyzer running. A hit carries no
tree, so Design A must either miss or launch an extractor — exactly the ordered-miss violation the
cache exists to prevent. *Design B: cache the rendered text in the result.* Chosen. A hit already
carries everything `format` needs, and the source-only shortcut is gated so a `check`-populated entry
is a **miss** for a rendering mode rather than an under-populated hit.

`CanonicalText` holds the text **and its own findings**, which is not redundancy. RFP-SPEC §6 measured
that canonical text is not lint-clean — the printer keeps a command's trailing trivia verbatim
(`Printer.lean:208-222`), so it strips no trailing whitespace and adds no final newline. Findings index
the normalized source (`Application.lean:420-422`), and canonicalizing moves bytes: `namespace     Alpha`
loses four, so every cached finding past it is four bytes off. The two arrays are the same rules in two
coordinate systems and mixing them corrupts files. Both are selection-independent — `runRules` produces
every rule's findings and `RulePlan.findings` projects afterwards — so one entry still serves any
`--select`.

## Decisions changed during execution

**1. `officialArtifacts` could never have caught the failure it was written to catch.** Its docstring
claimed "a missing, stale, corrupt, or failing facet is an ordered miss, never an extractor launch or a
partial batch failure." That was false the whole time, and nothing was exercising it: every registry
rule is `input := .source`, so `requiresSyntax` was always `false` and no product path ever called it.
RFP-IMPL made rendering modes need a projection and called it against a stale module. The run died with
exit 3 and printed nothing.

Exit 3 is Lake's. Under `noBuild`, an out-of-date target makes `finalizeBuild` call
`IO.Process.exit noBuildCode.toUInt8` (`Lake/Build/Run.lean:368`; `noBuildCode : ExitCode := 3` at
`:275`). That is a process exit, not an exception — the `try/catch` sees only the `else` branch's
`throw`, so the one case it was written for is the one case it cannot catch. `withoutProcessOutput` was
still holding stdout and stderr in a buffer the exit never flushes, which is why it died silently.

The fix is `Workspace.checkNoBuild` (`:405-414`), which asks the same question and returns a `Bool`
without exiting — documented as "equivalent to checking whether `lake build --no-build` exits with code
0". This is Lake's own idiom, not a local invention: `lake shake` guards identically
(`Lake/CLI/Main.lean:1113`), and `Project.exactSetup` and `compilerStatus` already did. This one
operation did not. Full citations and the mutation in `evidence/03-nobuild-exits-the-process.txt`.

**2. `diff` did not emit a diff, and this claim's contract names diffs.** `unifiedDiff` never looked
for a common line: it emitted every old line as `-` and every new line as `+` under one synthesized
`@@` header. Applying it reproduces the file, so it was correct — and useless, since a one-line change
reprinted the whole file. It had only ever run on FMT001/FMT002 fixes, where it was merely bad. RFP-IMPL
points `diff` at canonical layout and makes it the surface formatting is reviewed on, so a whole-file
rewrite defeats the mode's only purpose. The roadmap names `diffs` in RFP-IMPL's contract
("Connect canonical formatting to reports, **diffs**, cache identity, …"), so it was fixed here rather
than deferred.

`Lean.Diff.diff` (`Lean/Util/Diff.lean:170`) supplies the edit script — a histogram diff, the family
`git diff --histogram` uses. Only the hunking is ours; core's `linesToString` (`:201`) prints the whole
script with no `@@` headers, which no tool consumes. This is a core module, not a new dependency and not
a reimplementation.

**3. A diff over bare strings would have silently dropped FMT002.** Found while designing the above, not
by a test. `diffSource` reads the terminator into `finalNewline` and drops it from `lines`, so `"a\n"`
and `"a"` both project to `["a"]`. A line diff pairs them as unchanged and emits **no hunk** — printing
nothing while reporting `changed=1`, for the single edit FMT002 exists to make. `DiffLine = String × Bool`
carries the terminator into the compared element so the two stay unequal; the `\ No newline at end of
file` marker then lands correctly for free, since it belongs to whichever side holds the flag.

## What makes the diff believable

Not "it looks right". A hand-written `@@` header that git rejects is worth nothing:

```
$ lean-fmt diff --root . --no-cache tests/check/Layout.lean | git apply --check -
  ACCEPTED
$ ... | git apply -
  APPLIED   -> result byte-identical to what `format` reports as `formatted`
```

Both shapes were checked this way — the layout change and the final-newline-only change
(`evidence/05-diff-is-a-diff.txt`). The second renders as GNU diff does:

```
@@ -4,4 +4,4 @@
 
 def layoutValue : Nat := 1
 
-end Alpha
\ No newline at end of file
+end Alpha
```

## Measurements

| property | result |
| --- | --- |
| `format` on `tests/check/Layout.lean` | `would-format`, `changed=1`, `findings=0`, exit 1 |
| `check` on the same file | `clean`, `changed=0`, exit 0 |
| product idempotence: `fix` then `format` | `fixed`/`written=1`, then `clean` at exit 0 |
| `format` on a **stale** module (source edited, olean not rebuilt) | formats correctly, picks up the edit |
| diff for a 1-line change in a 7-line file | 1 hunk, `@@ -1,6 +1,6 @@`, one `-`, one `+` |

The stale-module row is the one worth reading twice. It is the case a user hits every time they edit a
file and run `format`, and it is the case that died at exit 3 before decision 1. The guard turns it into
an ordered miss, and the analyzer fallback parses fresh source — so the answer is correct, not merely
non-fatal.

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

Exit codes were read directly, not through a pipe. An earlier `... | tail -18; echo $?` in this session
reported `0` for a suite that was failing — that was `tail`'s status, and it hid the exit-3 bug for a
while.

**The printer suite failed twice, correctly, and both times it was the corpus gate.** This repository is
the printer's own corpus (`git ls-files 'LeanFmt/*.lean' 'LeanFmt.lean' 'Main.lean'`), so adding
`CanonicalText` and rewriting `unifiedDiff` moved the measured shape: 458 → 468 commands, 42,599 →
43,840 nodes, and the empty-node share from 35.8% to 35.7%. `tests/printer/run.sh:137-145` caught the
stale evidence and named its own remedy; `experiments/run-projection-shape.sh` regenerated it, and the
figures quoted in `Printer.lean`, ruff-03's `notes/01` and its `state/current.md` were updated to match.
Every qualitative figure held — 0 contiguity violations, 0 out-of-source-order, 97.2% of declarations
structurally claimed, 0 collapsible member shells — so ruff-03's arguments survive unchanged; only the
counts moved. Re-measuring after the prose edit confirmed a fixed point (comment text carries no nodes).

## The checks are non-vacuous

Asserted by mutation, per the house standard:

| mutation | result |
| --- | --- |
| remove the `checkNoBuild` guard from `officialArtifacts` | **caught** — `expected exit 0, got 3` |
| revert `unifiedDiff` to reprinting the file | **caught** — golden has ` ` context lines a whole-file rewrite cannot produce |
| drop the terminator flag from `DiffLine` | **caught** — the final-newline test's hunk list goes empty |
| canonicalize the fixture's spacing | **caught** — `fixture lost its non-canonical spacing` (RFP-SPEC's guard, still standing) |

The first is the one that matters: it reproduces the exact original failure, and it shows the modes
suite is this fix's regression test rather than something new being needed. The suite's last case is a
second `fix` over an already-fixed fixture, which leaves the module stale — that is what reaches the
out-of-date path.

## Remaining uncertainty

- **Whether `fix` can take a cache hit.** Unchanged from RFP-SPEC and still unmeasured. A full hit
  returns from `previewFile` before `officialArtifacts`, so a hit carries no tree; with Design B a hit
  now carries canonical *text*, which is what `fix` actually needs, so the answer may have improved.
  Not measured here — `--no-cache` was used throughout to isolate the wiring.
- **Diff quality on scattered changes.** Every diff measured here has one hunk. A file where the printer
  canonicalizes many commands produces many hunks, and whether the histogram diff pairs lines the way a
  reader expects on real Lean is unmeasured. RFP-FINAL sees it on the frozen sample first.
- **`Lean.Diff.diff`'s resource envelope is inherited, not measured.** It is core's, used by Lean itself,
  but this stack has not run it on a large file. RFP-FINAL's frozen-sample timing is where that shows up.
- **Whether the non-overlap of FMT rules and layout survives a third rule.** Unchanged from RFP-SPEC.
  Both current rules are `category := "text"`, about bytes `Doc` cannot represent; nothing enforces that
  a future rule stays out of the printer's way.
