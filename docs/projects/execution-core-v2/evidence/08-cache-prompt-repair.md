# Prompt 08 cache-boundary repair

Date: 2026-07-16

## Classification

The first unfinished prompt contained an incorrect completion requirement. General executable Lake
configuration prevents a semantic project identity from being validated without evaluating that
configuration.

## Repair

- Kept `08-cache` as the first unfinished prompt and left its dependency on verified `07-check`.
- Replaced the impossible “do not load project environments” condition with a precise frontend-free
  hit contract.
- Required separate timing for workspace evaluation, epoch validation, and entry lookup.
- Required evaluated workspace structure and trustworthy Lake traces, with cache disabled when that
  trust cannot be established.
- Moved complete cache-warm mathlib acceptance to Prompt 10, its existing scale owner. Prompt 08
  still measures the full mathlib epoch and genuine hits, but forbids synthetic semantic entries or
  a known-implausible cold run performed only to seed timing.
- Did not weaken source, toolchain, configuration, validation, schema, corruption, or atomicity
  requirements.

No production code or verified claim changed in this repair.
