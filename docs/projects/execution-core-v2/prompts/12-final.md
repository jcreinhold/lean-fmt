---
claim_id: ECV2-FINAL
status: planned
depends_on: [ECV2-SERVE]
role: final-audit
---

# Audit the native Lean replacement from fresh evidence

## Task

Rerun correctness, architecture, performance, resource, packaging, and documentation checks from a
fresh read. Fix root causes before marking completion.

## Target

- `results/12-final-audit.md` maps every roadmap claim to implementation and reproducible evidence.
- No Rust workspace, worker protocol, public strategy DTO, temporal lifecycle API, pass-through
  module, or legacy production source has returned.
- Common callers know nothing about cache keys, ordered search roots, plugin loading, child lifetimes,
  retries, or resource scheduling.
- Documentation distinguishes ordinary-built, formatter-integrated, cache-cold, and cache-warm claims.

## Stop

Do not verify while any required command fails, exactness is uncertain, reports omit files, resource
bounds are breached, or performance wording exceeds measurements.

## Check

- Run the deep-module audit and inspect all production callers.
- `lake build`
- Differential, cache, modes, and service suites at their specified scope.
- Validate the digests and coverage of ECV2-SCALE's completed full-mathlib acceptance evidence. Rerun
  a full path only if the candidate binary, workload, toolchain, or relevant configuration changed.
- Generic stack checker and generated-state check.
- `git diff --check`
