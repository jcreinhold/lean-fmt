---
claim_id: RCD-IMPL
status: verified
depends_on: [RCD-SPEC]
---

# RCD-IMPL — per-file effective configuration

## What shipped

`LeanFmt/Discovery.lean` (new, `LeanFmt.Internal.Discovery`) is the one private capability: it owns the
git-ignore matcher, git-config reading, the single `walkDir` pass, the directory→config map, and the
selection gates. It is globbed into `lean_lib LeanFmtApplication` only — deliberately not into
`lean_lib LeanFmtCompilerPlugin`, which would put configuration discovery inside every compilation of
every integrating module.

`LeanFmt/Config.lean` gained the loader half: `PartialConfig` (all-`Option` base fields, so "absent" is
distinguishable from "set to the default" — the distinction `extend` composition is built on),
`loadChain` with realpath cycle detection and depth 32, section handling for `[format]`/`[lint]` with
the §8.2 migration truth table, `valueLine` provenance via each `Lake.Toml.Value`'s own `ref : Syntax`,
and `FormatterConfig.describe`/`contributingFiles` for introspection.

`SourceTarget` now carries `config` and `configKey`; `Application.execute` memoizes one `RulePlan` per
distinct `configKey` rather than per file; `Cli.lean` gained `config show PATH [--json]`; and
`Rules.lean`'s generated `schema.json` is sectioned, with the flat keys retained and marked
`deprecated: true`.

Both baseline defects from RCD-SPEC are closed:

- **The `.lake` write defect.** The floor moved into `snapshotTarget`, beside the containment and
  extension checks, so both the discovered and the explicitly-named path form pass through it.
  Previously only the discovered form was filtered, and `format .lake/packages/dep/Dep.lean` wrote a
  dependency's source (`evidence/01-discovery-baseline.md` §3, with `od -c` bytes).
- **The stale `Application.lean` docstring.** `canonicalWidth : Nat := 100` is deleted — the width now
  comes from `snapshot.config.format.lineWidth`. Its docstring argued from a mechanism commit `62e23fa`
  had already replaced; rather than re-cite the new mechanism, the comment now explains why the old
  argument does not survive the promotion at all.

## Commands and outcomes

```
lake build                                     # clean, no warnings
lake exe lean-fmt-tests                        # lean-fmt module-artifact tests passed
lake exe lean-fmt docs --check                 # docs up to date (17 files)
tests/{compiler,check,suppression,lossless,modes,scale,service,boundary,syntax}/run.sh   # all pass
tests/{catalog,imports,layout,printer,semantic}/run.sh                                   # all pass
check_stack.py docs/projects/ruff-13-config-discovery   # OK: 3 prompt(s), 0 warning(s), no errors
```

Live introspection on the fixture used below (abridged):

```
$ lean-fmt config show sub/B.lean --root .
config: .../sub
contributing files: .../base.toml, .../sub/.lean-fmt.toml
selected: true (selected)
settings:
  exclude = []  (default)
  format.line-width = 42  (.../sub/.lean-fmt.toml:3)
  lint.select = ["security"]  (.../base.toml:5)
  lint.extend-select = ["FMT010", "FMT011"]  (.../base.toml:6, .../sub/.lean-fmt.toml:6)
```

That single output demonstrates four frozen rules at once: the closest config governs, scalars replace,
`extend-*` concatenates parent-then-child, and every setting carries its own file and line.

## Regression tests added

`LeanFmtTest.testDiscovery` builds a real temporary tree and walks it with the same `Discovery.run` the
product uses. It asserts: two recognized names in one directory error; the closest config governs and
does **not** inherit an ancestor's `exclude`; an excluded directory's contents report gate 3 while the
same-named directory under a different config does not; `extend` composition (scalar replace, base-array
inherit, `extend-*` concatenate, two contributing files); an `extend` cycle errors; a flat linter key
works and emits a notice; the same key set flat and under `[lint]` errors; `line-width` at the top level
errors; widths 0 and 1001 error; a `.gitignore` prunes a directory and a nearer file's `!` negation
re-includes; and the §9.2 identity rule stated on the identity string itself — a `[lint]` change leaves
it equal, a `[format]` change does not.

`tests/modes/run.sh` §9–§12 own the write path, because that is where a configuration mistake destroys
data rather than merely reporting wrongly:

- §9 puts a real layout-dirty Lean file **inside `.lake`** and asserts `format` and `fix` both refuse it
  under the default, under `force-exclude = true`, and under `force-exclude = false`, with the fixture's
  bytes, mtime, and mode unchanged. `config show` reports gate 1 for it.
- §10 formats one explicitly-named excluded path twice, changing only `force-exclude`: written without
  it, withheld with it. Same file, same argument, same mode, so the difference is attributable to
  nothing else.
- §11 asserts the cache identity behaviorally with the cache **on**: a width-100 entry must not be
  served to a width-20 run, while a `[lint]`-only change agrees. This asserts the wrong answer cannot be
  returned, which a hit counter would not.
- §12 asserts `config show` is byte-identical across two invocations, writes nothing, and names the
  right file and line.

Two of the new Lean assertions were mutation-checked (the `.gitignore` negation and the `extend-select`
concatenation) by perturbing the fixture and confirming each failed with its own message before
restoring. A test suite that has never been observed to fail is not evidence.

## Decisions changed during execution

- **`--config` anchors at the project root**, not at its own directory — an amendment to `notes` §7.
  An explicit config is usually outside the tree it governs (a shared file in a parent or sibling
  directory), and anchoring its patterns at its own location would make them meaningless. An `extend`
  parent outside the root keeps the extending file's anchor, which preserves §7 for the discovered case.
- **The `.lake` error names the resolved path**, not the argument as written. The freeze sketched the
  argument form, but the check now lives beside `snapshotTarget`'s containment and extension errors,
  which all name the resolved path; one of the three phrasing its path differently would be worse than
  the freeze's preference. `config show` and the pre-check in `describeConfig` do name the argument.
- **A batch run's obtained tier stays one decision.** Selection is now per-file, but what a run
  *obtains* is the union over per-file plans seeded at `.source`. Over-obtaining costs time;
  under-obtaining returns a wrong answer. The same asymmetry governs `demandedCaps`.
- **`Discovery.explain` is separate from `Discovery.gateFor`.** `gateFor` may assume the walk already
  pruned gates 2–3, because it only ever sees discovered paths. `config show` cannot: it is handed a
  command-line path that may sit under a directory the walk never entered, so `explain` re-asks gate 3
  against every ancestor and orders it before absence-from-`sources` — otherwise a config-excluded
  directory reports "excluded by a git ignore source" and sends the user to the wrong file to fix it.
  This was caught by the fixture, not by review: the first implementation reported gate 2 for
  `vendor/V.lean` under `exclude = ["vendor"]`.
- **The service keeps one root-level plan for its session lifetime.** Per-file configuration inside a
  session is deferred to `ruff-16-watch-incremental`, which owns the invalidation model that would make
  it correct; a comment in `Service.lean` records this rather than leaving it to be rediscovered.

## Collateral, and what it says

`tests/printer/run.sh` failed on the projection-shape evidence being stale. This was investigated
before being fixed: `git ls-tree` per commit shows the corpus was already stale by one module *before*
this stack (`fa141ee` 22 modules, `62e23fa` 23), so this stack widened an existing gap rather than
opening one. The gate's documented remedy (`experiments/run-projection-shape.sh`) was run and the
figures it feeds updated in `LeanFmt/Printer.lean` and the `ruff-03` notes and state. The corpus is now
748 commands / 81,115 nodes. That gate is doing exactly what it was built to do: this repository is the
printer's own corpus, so adding a production module moves every quoted figure.

The README's configuration section was materially false after this prompt — it documented a single root
config, no sections, no hierarchy, and a `text` selector retired in `ruff-11c`. It is rewritten.

## Remaining uncertainty

- Discovery timing on a large tree is not yet measured; that is RCD-FINAL's obligation. The design
  argument (one walk, memoized parses, pruned subtrees) predicts it is not on the critical path, but
  predicted is not measured.
- Symlink behavior is partly measured, not assumed. A directory symlink pointing at its own ancestor
  (`a/loop -> ..` in a minimal Lake project) terminates and contributes **no** paths: the walk reports
  exactly `a/A.lean` and `lakefile.lean`, so a symlink loop neither hangs nor duplicates. What is *not*
  yet measured is symlinked source files, a symlinked config file, and a symlink whose target lies
  outside the project root — RCD-FINAL owns that matrix.
- `notes` §15's open questions are untouched and remain open.
