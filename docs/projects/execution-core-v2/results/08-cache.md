# ECV2-CACHE result

Status: verified on 2026-07-16 after identity, corruption, atomicity, disabled-cache, no-child,
full-epoch, representative-hit, repository, and module-boundary gates.

## Result

A private `ResultCache` capability now owns semantic identity, Lake trace validation, entry paths,
payload trust, and atomic writes. It can be constructed only for a complete evaluated workspace
epoch. Source, toolchain, ordered environment/build traces, exact formatter binary, evaluated module
configuration, validation level, and artifact schemas all participate; execution strategy does not.

The application preflights every selected result once. An all-hit run returns before temporary
fallback setup, artifact extraction, or exact frontend startup. Missing traces disable caching;
missing, stale, corrupt, partial, or semantically invalid entries are ordinary misses. `--no-cache`
performs no reads or writes.

On already-built mathlib, complete epoch validation took 11.302 seconds inside 11.992 seconds wall.
A genuine 62-file warm run took 11.709 seconds, of which cache lookup itself was 40 ms, with the
analyzer disabled and byte-identical output. Full cache-warm mathlib acceptance remains Prompt 10.

## Evidence

See [the cache design note](../notes/08-cache.md),
[the trust-boundary repair](../notes/08-cache-trust-boundary.md), and
[Prompt 08 gates](../evidence/08-cache-gates.md).
