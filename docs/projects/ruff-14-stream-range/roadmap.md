---
kind: roadmap
topic: "stdin/stdout and range formatting"
main_results: [RSF-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-11d-format-in-place, ruff-13-config-discovery]
blueprint_tracked: false
---

# stdin/stdout and range formatting

## Goal

Support editor- and pipeline-friendly stdin/stdout operation plus syntax-aware range formatting that changes the smallest stable enclosing unit and reports its actual range.

## Completion contract

- `-` reads UTF-8 source from stdin and `--stdin-filename` supplies project/config/module identity; stdin never writes source or persistent disk-state cache entries. This stdin→stdout path is the raw-bytes-to-stdout surface that `ruff-11d-format-in-place` deliberately left unbuilt when it removed the old `=== path (N bytes) ===` stdout dump and made file-target `format` write in place: the default `format` publishes, `-`/`--stdin-filename` streams, and `format --check`/`diff` are the non-writing file-target previews. Do not reintroduce a file-target stdout escape hatch here.
- Range requests use byte or line/column positions with a documented encoding and expand to a structurally safe formatting boundary — one that is **reflow-stable**, not merely parse-safe: phase-2 reflow can rebreak the enclosing construct, so the boundary must contain every line the reflow of that unit can move.
- Output includes the actual formatted range and source map; because reflow can rebreak the enclosing unit, the **reported actual range may span lines the caller did not edit**, and text outside that reported range is byte-identical except explicitly documented boundary whitespace.
- Whole-file formatting and full-range formatting are equivalent.

## Work order

1. **RSF-SPEC — Define stream identity and range expansion.** Specify CLI forms, filename requirements, position encoding, enclosing-node selection, comment ownership at boundaries, diagnostics, exit codes, and cache/write policy.
2. **RSF-IMPL — Implement stdin and syntax-aware ranges.** Reuse snapshot analysis and the layout source map to add stdin/stdout and range formatting, exact validation, actual-range reporting, and deterministic errors.
3. **RSF-FINAL — Verify boundary stability and pipeline behavior.** Test UTF-8 positions, empty ranges, comments, custom syntax, nested nodes, malformed input, pipes, broken stdout, full-range equivalence, reflow-expanded ranges (an edit whose enclosing unit rebreaks), and repeated range idempotence.

## Evidence and verification

Every prompt writes `results/01-contract.md`-style result notes with commands, raw measurements,
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
