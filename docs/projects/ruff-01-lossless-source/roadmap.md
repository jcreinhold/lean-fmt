---
kind: roadmap
topic: "Lossless Lean source and compiler artifact"
main_results: [RLS-FINAL]
prereq_stacks: [execution-core-v2]
blueprint_tracked: false
---

# Lossless Lean source and compiler artifact

## Goal

Replace the command-kind/range projection with one exact, compact representation of source tokens, trivia, comments, syntax boundaries, and source identity that both fresh frontend analysis and compiler-integrated artifacts can produce.

## Completion contract

- Round-trip every accepted UTF-8 source byte-for-byte before formatting; comments, doc comments, whitespace, quotations, antiquotations, macro syntax, and synthetic syntax are distinguished.
- The representation carries byte ranges and parent/child structure without exposing Lean frontend objects to product callers.
- Artifact identity remains bound to the successful module, exact source snapshot, toolchain, plugin schema, and Lake facet content hash; a mismatch is an ordinary miss.
- Measure artifact size, encode/decode time, plugin overhead, and extraction memory on fixtures and the frozen sample.

## Work order

1. **RLS-SPEC — Freeze the lossless-source contract.** Inspect Lean parser `SourceInfo`, token/trivia behavior, parser extensions, quotations, and current artifact code. Write `notes/01-source-authority.md` specifying which compiler-owned data is authoritative, a versioned wire schema, invariants, and rejected alternatives. Build adversarial fixtures before implementation.
2. **RLS-IMPL — Implement the lossless projection and artifact.** Add private modules for the immutable projection and codec. Produce it from both exact analysis and the compiler plugin/facet, validate all ranges and hashes on consumption, and migrate canonical semantic inputs without widening the public API.
3. **RLS-FINAL — Prove losslessness and bounded cost.** Run the round-trip/differential corpus, frozen sample, artifact invalidation matrix, module boundary guard, and size/time/RSS profile. Remove redundant DTOs and document the selected interface.

## Evidence and verification

Every prompt writes `results/01-authority.md`-style result notes with commands, raw measurements,
changed design decisions, and remaining uncertainty. Use focused fixtures, the frozen representative
mathlib sample, and named stress files. Do not run complete mathlib in this stack unless this is the
final acceptance stack and its prompt explicitly authorizes it.

Run the affected Lean build/tests, `tests/boundary/run.sh`, this stack's structural checker, generated-next
check, and `git diff --check`. Performance records name workload, profile, cache/build state,
machine/toolchain/commit, wall time, peak aggregate RSS, pressure, and swap delta.

## Blueprint

This is genuine formatter repository maintenance and introduces no mathematical theorem claim.
Therefore this roadmap sets `blueprint_tracked: false`.

## Stop rules

- Preserve exact ordered imports, search-path precedence, file-local syntax effects, validation identity,
  private application boundaries, and atomic writes.
- Stop resource experiments at 8 GiB aggregate RSS, abnormal pressure, or 256 MiB new swap.
- Prefer pure Lean; another language requires a named unavailable Lean capability and measured benefit.
- Do not restore workers, public strategy controls, accumulated/superset parsing, or per-file Lake runs.
