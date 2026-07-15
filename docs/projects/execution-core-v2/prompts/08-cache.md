---
claim_id: ECV2-CACHE
status: planned
depends_on: [ECV2-CHECK]
---

# Add a sound result cache above semantic artifacts

## Task

Add a simple atomic result cache whose identity is semantic and independent of whether the result
came from compiler integration or exact fallback.

## Target

- Identity includes source, toolchain, ordered environment/build trace, formatter/rules, configuration,
  validation level, and artifact schema.
- All-hit runs construct no frontend child and do not load project environments.
- Corrupt or untrusted entries are misses; source and artifact writes are never confused.

## Check

- Test invalidation of every identity component, corruption, partial writes, disabled cache, and
  byte-identical cached/fresh reports.
- Measure epoch and all-hit time over mathlib separately.
- `lake build`
- `git diff --check`
