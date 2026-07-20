# RRF-IMPL — pure deterministic renderers

Claim: **RRF-IMPL** — add `--output-format`, optional output files with atomic replacement,
format-specific golden tests, and rule metadata embedding without adding branches to application
execution.

Freeze: `notes/01-report-formats.md`. Cost evidence: `evidence/02-renderer-cost.md`, probe
`evidence/02-append-growth-probe.lean`. Suite: `tests/reporting/run.sh` (58 assertions; recorded as "50 cases" here originally, which counted call sites rather than the assertions the loops emit — corrected by `RRF-FINAL`).

## Commands

```sh
LEAN_NUM_THREADS=1 lake build
lake exe lean-fmt-tests
tests/reporting/run.sh
tests/check/run.sh
tests/modes/run.sh
tests/suppression/run.sh
tests/stream/run.sh
tests/syntax/run.sh
tests/compiler/run.sh
tests/lossless/run.sh
tests/scale/run.sh
tests/service/run.sh
tests/discovery/run.sh
tests/boundary/run.sh
git diff --check
lake env lean --run docs/projects/ruff-15-reporting/evidence/02-append-growth-probe.lean
uv run --with pyyaml .claude/skills/lean-plan/scripts/check_stack.py <workspace> --structural  # from kan-proofs
uv run --with pyyaml .claude/skills/lean-plan/scripts/write_next.py <workspace> --check        # from kan-proofs
```

## Results read

| Check | Result |
| --- | --- |
| `lake build` | `Build completed successfully` |
| `lean-fmt-tests` | `lean-fmt module-artifact tests passed` |
| `tests/reporting/run.sh` | `lean-fmt reporting format tests passed` (58 assertions, 0 failures) |
| `tests/check/run.sh` | `lean-fmt check integration tests passed` |
| `tests/modes/run.sh` | `lean-fmt product mode integration tests passed` |
| `tests/suppression/run.sh` | `lean-fmt suppression acceptance tests passed` |
| `tests/stream/run.sh` | `failures=0` |
| `tests/syntax/run.sh` | `lean-fmt syntax-tier rule integration tests passed` |
| `tests/compiler/run.sh` | `lean-fmt compiler facet tests passed` |
| `tests/lossless/run.sh` | `lean-fmt lossless projection corpus passed` |
| `tests/scale/run.sh` | `lean-fmt complete-selection and module-evidence tests passed` |
| `tests/service/run.sh` | `lean-fmt editor service integration tests passed` |
| `tests/discovery/run.sh` | `lean-fmt configuration discovery acceptance tests passed` |
| `tests/boundary/run.sh` | `lean-fmt native module and dependency boundary passed` |
| `git diff --check` | no output |
| structural checker | `OK: 3 prompt(s), 0 warning(s), no errors.` |
| `write_next.py --check` | `OK: state/next.md matches first_unresolved=…` |

## The interface decision the freeze left open

`notes/01-report-formats.md` §11 named one unresolved item and called it the largest in the stack: the
renderers must be pure over `RunReport`, but a line/column conversion needs source text the report does
not carry. Three designs were compared before one was chosen.

**Design A — the renderer re-reads each file.** Rejected on two counts. It puts IO inside a renderer
the roadmap requires to be pure, and — decisively — it races the run itself. `fix` and `format` publish
in place, so by the time the renderer ran, the bytes on disk would be the *rewritten* ones while every
finding still indexes the original coordinates. Every position would be silently wrong exactly on the
runs that changed something. This is not a corner case; it is the normal `fix` path.

**Design B — `FileReport` gains a line index.** Rejected: that structure is the canonical report and
its derived `ToJson` is the compatibility surface §8.1 promises not to touch. A rendering aid in the
canonical semantic report is the contamination the roadmap's goal statement forbids by name. A variant
— keep the field but hand-write `ToJson` to omit it — was also rejected: it trades a structural
guarantee for an instance that must be remembered.

**Design C — execution resolves the offsets the report mentions, and hands them over beside it.**
Chosen. `Application.execute` returns a `RunOutcome { report, positions }`; `PositionIndex` maps
`(path, byte offset) → Position` for *exactly* the offsets the finished report names.

Compared on the prompt's own axes:

- **Caller knowledge.** One caller (`Cli.lean:runFileCommand`) destructures a pair. `PositionIndex`'s
  constructor is private and its only query is "what line and column is this offset the report already
  named?" — a caller cannot ask about an offset the report never mentioned, which is what keeps the
  abstraction from becoming a general-purpose file index.
- **Invariants hidden.** That findings index the *pre-publication* normalized source. The renderer
  never learns this, and cannot get it wrong.
- **Error surface.** None. There is no IO and no failure mode; an unknown offset is `none`.
- **Exactness.** The positions come from the same bytes the analysis read, resolved by the inverse of
  `ruff-14`'s `offsetOfLineColumn`, so a caller's `--range-lines` input and a report's output are one
  encoding.
- **Cache identity.** Untouched. `PositionIndex` is derived after the fact from data already in hand
  and enters no cache key; the result cache stores `SemanticResult`, which is unchanged.
- **Critical path.** One extra pass over the sources of files that have findings. A clean file is
  skipped entirely, which in a CI run is nearly all of them.
- **Memory enforceability.** Bounded by the **number of findings**, not by project size: two positions
  per finding, not a line table per file. This is the axis that decided it against a per-file line
  index, which would have been ~8 bytes per source line across the whole project.

`execute` gained no branch. The index is built once at each of the three return sites from data those
sites already hold, so per-file execution paths are untouched — the prompt's "without adding branches
to application execution".

## What shipped

- `LeanFmt/Application.lean`: `Position`, `PositionIndex` (private constructor, one query),
  `positionsOf` (one sorted forward pass, codepoint columns), `resolvePositions`,
  `PositionIndex.ofSource` for the stdin surface, and `RunOutcome`.
- `LeanFmt/Cli.lean`: `ReportFormat` widened to six; `--output-format` and `--output-file` parsing with
  conflict and per-mode admissibility checks; six pure `RunReport → String` renderers; `emitReport` as
  the single IO boundary; atomic `writeReportFile`; `streamAsRunReport` so the stdin surface reuses all
  four renderers rather than reimplementing any.
- `tests/reporting/`: the suite, the `Unicode.lean` fixture, the vendored SARIF schema, and a README
  recording the schema's provenance.
- `tests/check/run.sh`: unchanged from RRF-SPEC — it still pins `--json` to the pre-change golden, and
  it still passes, which is the compatibility claim discharged rather than asserted.

## Decisions changed during execution

- **§9.3 was wrong about broken pipes, and the implementation is what showed it.** The freeze said a
  closed stdout makes the run "exit 0". Exiting 0 would mean `lean-fmt check … | head` reports *success*
  on a run that found a violation — the pipe would become a way to silence CI. The pipe closing says
  nothing about what the analysis found. Corrected in the note and implemented as: swallow the message,
  keep the verdict. Measured across all six formats (`tests/reporting/run.sh`): exit 1, no diagnostic.

- **§8.2's JUnit gate became a consumer instead of an XSD.** The freeze named `xmllint --schema`
  against "a community XSD". Measured against the most-cited one (windyroad `JUnit.xsd`, the Apache Ant
  flavor), our output is rejected for a missing `time` attribute and a missing `<properties>` child.
  Both are Ant-flavor requirements that the `testmoapp` reference documents as optional, and the format
  has no normative schema at all (§7.1) — so "fails one flavor's XSD" is a flavor difference, while
  calling it a pass would be worse. The gate became what the roadmap actually asked for, an independent
  *parser*: `junitparser` reads back every suite, case, result type, and aggregate count. §7.2's refusal
  to emit a fabricated `time="0"` stands. Both amendments are recorded in the note itself, not only
  here.

- **The vendored SARIF schema replaced a network fetch.** The URL the specification names (§3.13.3,
  NOTE 2) now 404s. `json.schemastore.org` serves the schema, and it is vendored into
  `tests/reporting/` so the suite validates offline and an upstream revision cannot silently change
  what this repository claims to have verified. The `$schema` our renderer emits still points at the
  specification's URI, because that is the format's identifier and not a promise the URL resolves.

- **`--output-format` for `diff` is rejected at parse time, before the run.** The freeze specified the
  rejection but not when. Doing it in `parseFileArgs` means the error costs nothing, matching the
  `--output-file` pre-check for the same reason.

## Measurements

Cache-warm, 109 files / 109 findings, `--select all --preview`, whole `lean-fmt` project
(`evidence/02-renderer-cost.md`):

| Format | Bytes | Wall (s) | Peak aggregate RSS (MiB) |
| --- | --- | --- | --- |
| `text` | 16,050 | 0.51 | 674 |
| `concise` | 16,159 | 0.50 | 674 |
| `github` | 30,079 | 0.51 | 674 |
| `sarif` | 74,575 | 0.52 | 675 |
| `junit` | 64,022 | 0.51 | 675 |

SARIF emits 4.6× the bytes of `text` for +0.01 s and +1 MiB. The cold run of the same workload took
87.16 s at 4,758 MiB — the analysis, not the renderer, and inside the 8 GiB envelope. No pressure, no
swap delta.

The stop rule "renderer allocation must be bounded for project-scale reports" was checked against its
actual failure mode rather than by inspection. Every renderer accumulates with `out := out ++ …`, which
is O(bytes²) if `String.append` copies. Measured
(`evidence/02-append-growth-probe.lean`): 400,000 appended finding lines producing 29 MB register 0 ms,
with total process time of 0.62 s including elaboration. Lean extends a uniquely-referenced string in
place with amortized growth, so the pattern is linear.

## Files changed

| File | Change |
| --- | --- |
| `LeanFmt/Application.lean` | `Position`/`PositionIndex`/`RunOutcome`; `execute` returns positions beside the report |
| `LeanFmt/Cli.lean` | six formats, `--output-format`, `--output-file`, six pure renderers, atomic write, broken-pipe handling |
| `tests/reporting/run.sh` | new — 50-case suite with independent SARIF and JUnit parsers |
| `tests/reporting/Unicode.lean` | new — fixture where byte and codepoint columns disagree |
| `tests/reporting/sarif-schema-2.1.0.json` | new — vendored SARIF 2.1.0 schema |
| `tests/reporting/README.md` | new — schema provenance and fixture rationale |
| `docs/projects/ruff-15-reporting/evidence/02-renderer-cost.md` | new — per-format cost and the append-growth result |
| `docs/projects/ruff-15-reporting/evidence/02-append-growth-probe.lean` | new — the probe |
| `docs/projects/ruff-15-reporting/notes/01-report-formats.md` | amended §8.2 and §9.3 with what implementation measured |
| `CLAUDE.md` (`AGENTS.md` symlink) | registers `tests/reporting/run.sh` |

## Remaining uncertainty

- **The large synthetic report benchmark is still owed.** `evidence/02-renderer-cost.md` measures 109
  findings and the append pattern in isolation; neither exercises `Lean.Json.pretty` — SARIF's
  serializer — at scale. RRF-FINAL owns the roadmap's "benchmark large synthetic reports" and must put
  that serializer in the path.
- **`Lean.Json.pretty`'s output stability across toolchain bumps is still unpinned.** The SARIF golden
  in `tests/reporting/run.sh` is structural (parsed assertions), not byte-for-byte, which sidesteps the
  question rather than answering it. If a bump reflows the JSON, nothing currently notices. RRF-FINAL
  should decide whether that matters.
- **SARIF `uri` percent-encoding is not exercised.** §6.4 specifies RFC 3986 path-segment encoding; the
  implementation emits the report path verbatim, and no fixture has a path needing encoding — a space
  or a `#` in a filename would currently produce a malformed URI reference. Named rather than assumed
  safe. RRF-FINAL should add the fixture and the encoder, or record why the case cannot arise.
- **`helpUri` is not emitted at all.** §6.2 specified it from `docs/rules/`, and coverage for the import
  family was never verified (a `RRF-SPEC` uncertainty). Rather than emit a link that might 404, the
  descriptor omits it. RRF-FINAL should either establish coverage and add it, or record the omission as
  intended.
- **The `format` pseudo-rule id was checked against the live registry by construction** (it is outside
  the `FMT` namespace, which every live, reserved, and retired code inhabits) but not by a test. A
  cheap assertion in RRF-FINAL would close it.
