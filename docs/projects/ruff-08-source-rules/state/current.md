---
kind: state
first_unresolved: 02-implementation
---

# Current state

`RSR-SPEC` is **verified**. The frozen catalog is `notes/01-catalog.md`; what was run is
`results/01-catalog.md`; the acceptance boundary the catalog rests on is measured in
`evidence/01-acceptance.lean` and its transcript `evidence/01-acceptance.txt`
(`leanprover/lean4:v4.32.0`). No product behavior changed — the correct footprint for a spec prompt.
The external prerequisite stacks `ruff-05-rule-engine` and `ruff-06-fix-safety` are verified; their
live implementation (`LeanFmt/Rules.lean`, `LeanFmt/LosslessSource.lean`) was re-read against this
work.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-catalog | RSR-SPEC | verified | — |
| 02-implementation | RSR-IMPL | planned | RSR-SPEC |
| 03-acceptance | RSR-FINAL | planned | RSR-IMPL |

## Known evidence

- **A source rule reads `raw.crlfToLf` and nothing else, and that decides the catalog.** BOM and
  isolated `\r` never reach accepted source (parse errors; `ruff-01` §5, re-measured); LF/CRLF
  intermixing is accepted but `crlfToLf` erases the endings. So BOM and mixed-line-endings are
  **rejected** as rules — invisible to any source rule, and owned by the read boundary / formatter.
- **The two accepted rules need no token context.** A bare control or bidi byte is a parse error, so
  every such byte in accepted source is already inside a string or comment — acceptance supplies the
  context. `FMT003` (forbidden control byte) and `FMT004` (suspicious bidirectional control) are
  linear byte scans, report-only, default-enabled, category `security`. Sets/ranges/messages frozen
  in `notes/01-catalog.md` §3.
- **`RSR-IMPL` implements those two rules** into `LeanFmt/Rules.lean`'s registry, with the
  fixture/suppression/JSON/documentation obligations in `notes/01-catalog.md` §5, and writes the
  persistent regression suite (this spec's characterization ships only as evidence).

## Blockers and prerequisites

- **`ruff-01` precision gap (non-blocking, handed off).** LF/CRLF-intermixed files are accepted yet
  classified `.crlf` by `normalize`; write safety holds via `ruff-01` round-trip invariant 4. See
  `notes/01-catalog.md` §4. Not this stack's to fix.
- If live code contradicts prerequisite results, reopen the owning prerequisite rather than patching
  around it.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
