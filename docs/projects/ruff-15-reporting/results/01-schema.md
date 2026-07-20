# RRF-SPEC — mapping canonical reports to target formats

Claim: **RRF-SPEC** — specify concise, GitHub, SARIF 2.1.0, and JUnit mappings; line/column encoding;
artifact URIs; rule metadata; run failures; stdout/file behavior; and schema compatibility.

Freeze: `notes/01-report-formats.md`. Baseline: `evidence/01-report-baseline.md`. Compatibility golden:
`evidence/01-json-golden-check.json`.

Per the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC, `ruff-14`
RSF-SPEC), no production Lean interface, config key, or CLI surface shipped. What shipped besides
documentation is one characterization test and the golden it compares against.

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/check/run.sh
tests/boundary/run.sh
git diff --check
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

Baseline characterization (raw output in `evidence` §1):

```sh
run(){ printf '$ lean-fmt %s\n' "$*"; lake exe lean-fmt "$@" 2>&1; printf 'exit=%s\n\n' "$?"; }
```

Golden recording (`evidence` §2):

```sh
app=$(lake -q query lean-fmt --text)
"$app" check --root . --json --no-cache tests/check/Findings.lean \
  > docs/projects/ruff-15-reporting/evidence/01-json-golden-check.json
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully (44 jobs)` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` (includes the new golden `cmp`) |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved='01-schema'` |

Environment: commit `00f1825`, `leanprover/lean4:v4.33.0-rc1`, Darwin arm64. No performance figure is
recorded — this prompt ships no production code, and `RRF-FINAL` owns the large-synthetic-report
benchmark the roadmap requires.

## What the baseline established

1. **There are exactly two report renderings and neither carries a position a human can use.** `text`
   prints `path:START-STOP` in normalized **byte** offsets; `json` carries `range.start`/`range.stop`,
   the same bytes. `--output-format` and `--output-file` are both rejected by `parseFileArgs`'s
   catch-all with `unknown option`, exit 2 — measured, not inferred.

2. **Every finding-shaped format therefore needs a byte-offset → (line, column) conversion that does
   not exist.** This is the stack's largest implementation obligation and it is named in the freeze
   (§3.1, §11) rather than left to be discovered mid-implementation. The inverse direction already
   exists — `ruff-14` shipped `offsetOfLineColumn` for `--range-lines` — so the encoding is inherited,
   not chosen: 1-based lines, 1-based **codepoint** columns.

3. **`diff` carries no findings.** Measured per mode on one fixture: `check`, `fix`, and
   `format --check` all populate `files[].findings`; `diff` returns `[]` and puts a patch in
   `files[].diff`. So the finding-shaped formats have nothing to say about `diff`, which is why §2.3
   rejects them for it rather than emitting an empty report that a CI dashboard would read as "clean".

4. **Report paths are already root-relative.** An absolute argument comes back as
   `tests/check/Findings.lean`, so SARIF's `%SRCROOT%` base is well-defined and needs no path
   heuristics.

5. **The independent validators RRF-FINAL needs are reachable.** `jq`, `xmllint`, and `python3` are
   installed; `check-jsonschema`/`jsonschema` are not, but `uv` 0.11.28 reaches both with
   `uv run --with`. The roadmap's "validate with independent parsers" gate is runnable as specified,
   with no new system dependency.

## Load-bearing findings from the external sources

Each is quoted verbatim in the freeze with its section number; none is paraphrased from memory.

1. **SARIF `run.columnKind` is a `SHALL`, and the JSON schema does not encode it.** §3.14.27: "If a
   SARIF producer processes text artifacts and theRun.results is non-empty, the run object SHALL
   contain a property named columnKind". Its value `"unicodeCodePoints"` names `ruff-14`'s frozen
   convention exactly. The consequence recorded for RRF-FINAL (§8.2) is that a green
   `check-jsonschema` is **not** a conformance result — the gate needs a conformance assertion beside
   the schema check, or we would ship a schema-valid, non-conforming log and believe it validated.

2. **Byte offsets must not be emitted as SARIF `byteOffset` or `charOffset`.** Two independent
   killers: `charOffset` is a *character* offset (§3.30.9) and ours is a byte offset, so it would
   misplace every finding in a file containing one non-ASCII identifier — which Lean source routinely
   is; and `byteOffset` indexes the *artifact* while ours index the CRLF-normalized source, which
   §3.30.4 ("Independence of text and binary regions") makes an *invalid* region rather than merely an
   imprecise one. Frozen: line/column only, with the normalized byte range in the region's property
   bag, which §3.8.1 explicitly sanctions.

3. **A half-open byte range converts directly into SARIF's region, with no special cases.** §3.30.8
   defines `endColumn` as "one greater than the column number of the last character", which is exactly
   the position of an exclusive `stop`. §3.30.2 NOTE 6 confirms that a region ending at column 1 of the
   next line is how one names a line *including* its newline, and EXAMPLE 6 that
   `startColumn == endColumn` is an insertion point. So ordinary, whole-line, and zero-width findings
   all fall out of one conversion. Verified arithmetically on the fixture (`evidence` §5): the FMT005
   finding is `4:1`–`4:21` and its fix edit ends at `5:1`.

4. **GitHub rejects `col`/`endColumn` when `line != endLine`, and GitHub does not document this.** The
   workflow-commands page presents them as independent optional parameters. The constraint is recorded
   in ruff's renderer citing `astral-sh/ruff#22074`. Multi-line findings are ordinary here, so this is
   a common path, not an edge case.

5. **GitHub property escaping is stricter than message escaping.** From `actions/toolkit`'s
   `command.ts`: property values additionally escape `:` → `%3A` and `,` → `%2C`. A path containing
   either — legal on macOS and Linux — would otherwise terminate the property list and corrupt the
   annotation stream. `%` is replaced first in both functions, or the `%` introduced by the `\r`/`\n`
   replacements would be double-escaped.

6. **There is no JUnit specification.** `testmoapp/junitxml`: "There is no official specification for
   the JUnit XML file format and various tools generate and support different flavors". The freeze
   therefore targets that documented common subset and says so, and RRF-FINAL validates
   well-formedness plus a community XSD — never "conforms to the JUnit spec", which would be an
   unsourced conformance claim.

## Decisions changed during execution

- **`text` keeps its name; `concise` is additive.** The first draft followed ruff and renamed the
  default to `full`. Rejected on two grounds: lean-fmt's text report renders no source excerpt, so
  `full` would promise a rendering this stack is not building; and the rename would break every golden
  in `tests/check`, `tests/modes`, `tests/suppression`, and `tests/syntax` for no user-visible gain.

- **`--json` is retained, not deprecated.** It is also the flag on `rules`, `explain`, `clean`,
  `compiler`, `organize`, and `config show`, none of which gain `--output-format` — deprecating it on
  run commands alone would leave one spelling meaning two things depending on the subcommand.
  Conflicting `--json --output-format github` is an error, not a precedence rule; silently letting one
  win is how a pipeline emits the wrong format for a year.

- **Infrastructure failures are SARIF *notifications*, not *results*.** Initially modelled as results
  with a synthetic rule id. Rejected after reading §3.20.21, which says a consumer "SHALL NOT assume
  that a failed run contains a complete set of analysis results" — a `result` cannot express "the
  analysis did not complete", and that distinction is exactly what exit code 2 already means.
  `invocation.executionSuccessful` now agrees with `reportExitCode` by construction. The same
  distinction drives JUnit `<error>` vs `<failure>` (§7.2).

- **SARIF `result.fixes` is deliberately not emitted.** Tempting and rejected: a SARIF fix names
  regions in character or line/column terms, our edits are normalized byte ranges, and §3.30.4 forbids
  the mixed region that would let us state both. Emitting them correctly means re-deriving replacement
  text against the artifact's on-disk encoding — a second write-shaped surface with no named consumer,
  when `--output-format json` already carries exact edits. Recorded as a narrowing with
  `ruff-18-integrations` as the stack that would reopen it.

- **Suppressed findings do not appear in SARIF.** SARIF has a `suppressions` property (§3.35) and it
  looks like the right home. But the canonical report carries `FileReport.suppressed` as a **count**,
  not a list, so there is no data to put there — populating it would be inventing a semantic field the
  report does not have, which is this prompt's stop rule. The count travels in `run.properties`.

- **No schema version field is added to the JSON report.** Adding one *is itself* a breaking change to
  every consumer that compares the object, and the roadmap's contract is satisfied by backward
  compatibility, which this stack achieves without one.

- **Broken-pipe handling was found to be a pre-existing hole, not a new-format concern.** Nothing in
  `Cli.lean` handles `EPIPE` today, so `check --json | head -1` currently does whatever the Lean
  runtime does with the raised `IO.Error`. The freeze (§9.3) makes it RRF-IMPL's to establish
  deliberately for **all six** formats — `text` and `json` are as pipeable as the new ones — rather
  than scoping it to the four being added.

## Files changed

| File | Change |
| --- | --- |
| `docs/projects/ruff-15-reporting/notes/01-report-formats.md` | new — the freeze |
| `docs/projects/ruff-15-reporting/evidence/01-report-baseline.md` | new — measured baseline, position arithmetic, validator availability, source index |
| `docs/projects/ruff-15-reporting/evidence/01-json-golden-check.json` | new — the pre-change `--json` compatibility golden |
| `tests/check/run.sh` | characterization test: `check --json` must still `cmp` equal to the golden |
| `docs/projects/ruff-15-reporting/state/current.md` | RRF-SPEC verified |
| `docs/projects/ruff-15-reporting/state/next.md` | regenerated for `02-renderers` |

## Remaining uncertainty

- **Where the line/column conversion gets its source text is unresolved, and it is the largest open
  item.** The renderers must be pure over `RunReport` (the roadmap's completion contract), but
  `FileReport` carries `path` and `formatted?` — not the original normalized bytes a conversion needs.
  Re-reading each file inside the renderer would put IO in a "pure renderer" *and* race against `fix`
  having just rewritten it; adding a line index to `FileReport` is a report shape change that §8.1
  forbids. The likely resolution is a private non-serialized side table computed during execution and
  handed to the renderer, but this has **not** been designed. RRF-IMPL must design it twice per its
  Plan step 2 before choosing.
- **The `format` pseudo-rule identity is not yet checked against the live registry.** §4/§6 use
  `format` as the id for "would be reformatted". RRF-IMPL must confirm it collides with neither the
  `FMT###` catalog nor `ruff-12`'s reserved and retired codes before shipping it.
- **`helpUri` coverage was not re-verified.** `docs/rules/` has pages for FMT003–FMT017; whether the
  import family has them was not checked here. RRF-IMPL emits `helpUri` only where the page exists.
- **`Lean.Json`'s pretty printer is assumed byte-stable across toolchain bumps.** If it is not, the
  SARIF golden becomes a toolchain tripwire rather than a format test. RRF-IMPL should record whether
  it pins the rendering itself.
- **The JUnit community XSD to validate against is named by role, not by URL.** RRF-FINAL picks one and
  records which, since the format has no normative schema to appeal to.
