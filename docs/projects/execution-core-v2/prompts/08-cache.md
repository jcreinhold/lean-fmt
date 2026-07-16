---
claim_id: ECV2-CACHE
status: verified
depends_on: [ECV2-CHECK]
---

# Add a sound result cache above semantic artifacts

## Task

Add a simple atomic result cache whose identity is semantic and independent of whether the result
came from compiler integration or exact fallback.

## Target

- Identity includes source, toolchain, ordered environment/build trace, formatter/rules, configuration,
  validation level, and artifact schema.
- Lake workspace configuration is evaluated before cache trust is decided. This is necessary because
  `lakefile.lean` is executable configuration and may derive module options, plugins, or roots from
  runtime state that no static file census can recover soundly.
- All-hit runs construct no frontend/import environment, start no analyzer or extractor process, and
  fetch no per-file setup job. Record workspace loading, epoch validation, and entry lookup as
  separate phases.
- The environment epoch is derived from the evaluated ordered workspace/search-root context and
  trustworthy Lake build traces. If the epoch cannot be established, caching is disabled for that
  run rather than accepting an approximate identity.
- Corrupt or untrusted entries are misses; source and artifact writes are never confused.

## Check

- Test invalidation of every identity component, corruption, partial writes, disabled cache, and
  byte-identical cached/fresh reports.
- Measure workspace loading and epoch validation over the complete mathlib selection. Measure a
  genuine all-hit lookup over fixtures and any representative sample for which real semantic
  results have been produced. Do not synthesize cache entries or run a known-implausible full cold
  path merely to seed this measurement; complete cache-warm mathlib acceptance remains Prompt 10.
- `lake build`
- `git diff --check`
