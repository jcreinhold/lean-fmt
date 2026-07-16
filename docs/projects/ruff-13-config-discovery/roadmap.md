---
kind: roadmap
topic: "Hierarchical and Git-aware configuration"
main_results: [RCD-FINAL]
prereq_stacks: [ruff-04-formatter-product, ruff-12-rule-lifecycle]
blueprint_tracked: false
---

# Hierarchical and Git-aware configuration

## Goal

Add predictable hierarchical configuration, explicit inheritance, Git ignore support, separate formatter/linter sections, and configuration introspection without making workspace evaluation unsound.

## Completion contract

- For each file, the closest recognized config applies; explicit `extend` composes a parent config with cycle detection and paths resolved relative to their owning file.
- Separate top-level discovery, `[format]`, and `[lint]` settings while providing a documented migration from the current flat schema.
- Respect `.gitignore`, `.ignore`, repository excludes, and global ignores by default; explicit paths bypass them unless `force-exclude` is enabled.
- `config show PATH --json` explains provenance and effective values deterministically.

## Work order

1. **RCD-SPEC — Freeze discovery, inheritance, and migration rules.** Specify recognized filenames, root boundaries, closest-config selection, `extend`, path resolution, ignore precedence, explicit-path behavior, and flat-config migration with a truth table.
2. **RCD-IMPL — Implement per-file effective configuration.** Add one private discovery capability, Git ignore matcher, inheritance loader, formatter/linter sections, provenance, config-show command, and cache invalidation over effective values.
3. **RCD-FINAL — Verify nested workspaces and discovery performance.** Test nested configs, extends, symlinks, ignore sources, explicit files, force-exclude, path origins, migration warnings, deterministic introspection, and large-tree discovery timing.

## Evidence and verification

Every prompt writes `results/01-semantics.md`-style result notes with commands, raw measurements,
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
