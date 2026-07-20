---
kind: state
first_unresolved: none
---

# Current state

Its external prerequisite stacks are `ruff-12-rule-lifecycle` and `ruff-13-config-discovery`; both
record `first_unresolved: none`. `ruff-14-stream-range`, which froze the position encoding this stack
inherits, likewise records `first_unresolved: none`. Live code was re-read for this freeze
(`Cli.lean`, `Application.lean`, `Rules.lean`, `ArtifactModel.lean`, `LosslessSource.lean`,
`tests/check/run.sh`, `tests/boundary/run.sh`). If live code contradicts a prerequisite result, reopen
the owning prerequisite rather than patching around it.

**RRF-SPEC is verified** (`results/01-schema.md`; freeze `notes/01-report-formats.md`; baseline
`evidence/01-report-baseline.md`; compatibility golden `evidence/01-json-golden-check.json`). The CLI
surface, per-mode format admissibility, position encoding, the concise/GitHub/SARIF/JUnit mappings,
rule-metadata projection, run-failure placement, stdout/output-file behavior, and the JSON
compatibility contract are frozen precisely enough for `RRF-IMPL`. Following the `*-SPEC` convention
(`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC, `ruff-13` RCD-SPEC, `ruff-14` RSF-SPEC), no production Lean
interface, config key, or CLI surface shipped; one characterization test and its golden did.

Key frozen decisions:

- `--output-format {text,concise,json,github,sarif,junit}`, default `text`, with `text`'s bytes
  unchanged and `--json` retained as an exact alias. The four finding-shaped formats are **rejected**
  for `diff`, which was measured to carry a patch and no findings — following `ruff-14`'s precedent of
  rejecting a flag a mode cannot honor rather than emitting a misleading empty report.
- Positions are 1-based lines and 1-based **codepoint** columns, inherited from `ruff-14`'s
  `offsetOfLineColumn` rather than newly chosen. The byte-offset → (line, column) conversion **does not
  exist yet** and is RRF-IMPL's largest obligation.
- SARIF regions carry line/column only. `charOffset` is a character offset and `byteOffset` indexes the
  artifact, while ours are normalized byte offsets — §3.30.4 makes the mixed region invalid, not merely
  imprecise. The byte range rides the region's property bag. `run.columnKind: "unicodeCodePoints"` is a
  spec `SHALL` that the JSON schema does not encode, so RRF-FINAL's gate needs a conformance assertion
  beside `check-jsonschema`.
- Infrastructure failures are SARIF `toolExecutionNotifications` (and JUnit `<error>`), not results:
  a result cannot express "the analysis did not complete", which is what exit code 2 already means.
  `invocation.executionSuccessful` agrees with `reportExitCode` by construction.
- The output format never changes the exit code. `--output-file` is atomic, pre-checked, and its
  failure is an infrastructure failure rather than a silent fall back to stdout.

**RRF-IMPL is verified** (`results/02-renderers.md`; cost `evidence/02-renderer-cost.md`; suite
`tests/reporting/run.sh`, 58 assertions). `--output-format {text,concise,json,github,sarif,junit}`,
`--output-file` with pre-check and atomic replacement, and six pure `RunReport → String` renderers
ship. Two freeze sections were amended by what implementation measured — §9.3 (a broken pipe keeps the
run's own exit code; exiting 0 would let a pipe silence CI) and §8.2 (the JUnit gate is an independent
parser, because the format has no normative schema and the most-cited XSD is one flavor requiring a
`time` this report has no measurement for).

**RRF-FINAL is verified** (`results/03-acceptance.md`; scale evidence `evidence/03-report-scale.md`;
suite `tests/reporting/run.sh`, 64 assertions). Every format is checked by a validator that is not
ours where one exists — `check-jsonschema` and a conformance block for SARIF, `junitparser` and
`xmllint` for JUnit, `urllib.parse` for the URI encoding, a documented unescaper for GitHub, and the
pre-change `cmp` golden for JSON. Rendering is linear in report size across three decades: ten times
the findings costs about ten times the milliseconds in all six formats, `Lean.Json.pretty` over a
50 MB SARIF log included. The benchmark corrected an RRF-IMPL assumption — the pretty-printer is not
the cost; the two `PositionIndex` lookups per finding are, which is why position-free `text` renders
33× faster than `concise` while emitting more bytes.

The design question `RRF-SPEC` left open was resolved as **Design C**: execution resolves exactly the
offsets the finished report names and hands them to presentation as a `PositionIndex` beside the
report. Re-reading files in the renderer was rejected because `fix` publishes in place, so the bytes
would be the rewritten ones while every finding still indexes the original coordinates; adding the
index to `FileReport` was rejected because that structure is the JSON compatibility surface. Allocation
is bounded by finding count, not project size, and `execute` gained no branch.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-schema | RRF-SPEC | verified | — |
| 02-renderers | RRF-IMPL | verified | RRF-SPEC |
| 03-acceptance | RRF-FINAL | verified | RRF-IMPL |

## Blockers and prerequisites

- No blocker is recorded. The stack is complete.
- The four open items `RRF-FINAL` inherited are all closed (`results/03-acceptance.md`, freeze §12):
  the synthetic benchmark ran at 100/1,000/10,000/100,000 findings across all six formats and is
  linear in every one; SARIF `uri` percent-encoding shipped as `uriPathEncode` with an independent
  round-trip case; `helpUri` shipped after `docs/rules/` coverage was established, asserted by
  resolving every emitted link to a file in the repository; and `Lean.Json.pretty` byte stability is
  deliberately unpinned, because byte stability is promised for `--output-format json` (which uses
  `compress` and is pinned to a golden) and not for the schema-defined formats.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
