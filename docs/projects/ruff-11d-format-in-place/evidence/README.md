# Raw evidence

Store or index reproducible fixtures, manifests, profiles, output digests, and gate transcripts here.
Performance evidence must identify workload, profile, cache/build state, machine/toolchain/commit,
wall time, peak aggregate RSS, memory pressure, and swap delta. Do not commit bulky generated build
artifacts. FIP-SPEC's first-hand characterization of today's stdout-only `format` (the `=== file (N
bytes) ===` framing and the non-write) belongs in `01-current-format.md`.
