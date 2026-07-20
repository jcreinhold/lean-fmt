---
kind: state
first_unresolved: 02-renderers
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

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-schema | RRF-SPEC | verified | — |
| 02-renderers | RRF-IMPL | planned | RRF-SPEC |
| 03-acceptance | RRF-FINAL | planned | RRF-IMPL |

## Blockers and prerequisites

- No blocker is currently recorded beyond the named prerequisite stacks.
- `RRF-IMPL` inherits one unresolved design question, recorded in `notes/01-report-formats.md` §11 and
  `results/01-schema.md`: the renderers must be pure over `RunReport`, but the line/column conversion
  needs source text the report does not carry. It must be designed twice before one is chosen.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
