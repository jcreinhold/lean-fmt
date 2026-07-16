# Prompt 09 product-contract repair

Date: 2026-07-15

## Classification

The first unfinished prompt was under-scoped. Its named modes did not determine output, exit,
configuration, compiler-integration, cache-projection, or write-transaction semantics, leaving
several architecture-changing choices hidden from execution.

## Repair

- Kept `09-modes` as the first unfinished prompt and retained its dependency on verified `08-cache`.
- Defined each command's observable output, mutation scope, and exit behavior.
- Defined a private all-or-nothing patch capability and the ordering of exact validation,
  stale-source detection, permission-preserving atomic publication, and cache handling.
- Made rule selection a strategy-independent projection over canonical semantic results.
- Rejected automatic rewriting of executable `lakefile.lean`; compiler setup emits integration
  guidance and status performs a read-only module-artifact audit.
- Added configuration schema, precedence, deterministic pattern semantics, statistics channel, and
  focused test obligations.
- Preserved Prompt 10 as the owner of sampled scale work and late full-mathlib acceptance.

No production source or verified claim changed in this repair.

## Verification

| Gate | Result |
| --- | --- |
| `check_stack.py --structural` | pass; 12 prompts, 0 warnings |
| `write_next.py --check` | pass; `09-modes` remains first unresolved |
| `git diff --check` | pass |
| Active product/entry-point module audit | pass; all 14 files begin with `module` |

The next executable step is the private checked-patch capability named by repaired Prompt 09.
