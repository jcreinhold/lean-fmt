---
claim_id: RCD-FINAL
status: verified
depends_on: [RCD-IMPL]
---

# RCD-FINAL — nested workspaces, symlinks, ignore sources, and discovery timing

## What this prompt found

RCD-IMPL shipped a walk that **followed directory symlinks**. `tests/discovery/run.sh` found it on the
first run, on the fixture written to satisfy this prompt's own symlink obligation.

The failure was loud only by accident. On a fixture that also contained a symlink out of the root, the
run died with:

```
lean-fmt: no such file or directory (error code: 2)
  file: .../dir/loop/dir/loop/dir/loop/ ... /dir/loop/Outside.lean
```

— a path the walk built by descending `dir/loop -> ..` until the operating system refused to resolve it.
Without that second symlink the same tree produced a **correct** answer, because every duplicate
realpaths back onto a file already found and is collapsed by `Project.deduplicate`. So the defect
presented as: right answers, quietly, at enormous cost.

The cost, measured on the acceptance suite's own 1,200-file tree with one `pkg04/loop -> ..` in it:

| build | `phase.discovery_ms` |
| --- | --- |
| RCD-IMPL (follows directory symlinks) | **68,420** |
| RCD-FINAL (does not) | **11** |

Same tree, same binary otherwise, one guard between them. The suite's 2 s bound sits four orders of
magnitude below the pre-fix number and three above the post-fix one, so it is a real gate rather than a
threshold fitted to a passing run.

This also supersedes a claim in `results/02-implementation.md`. That note reported a symlink loop
"terminates and contributes no paths" — the observation was right, the inference was not. It reasoned
from an output to a mechanism it had not observed. The note now carries that correction inline rather
than being quietly edited.

## The fix

`LeanFmt/Discovery.lean` classifies each entry with `symlinkMetadata`, which does not follow links,
instead of `isDir`, which does. A symlinked directory is therefore never descended into — git's own
work-tree rule, and what makes the walk finite. Two consequences were then decided rather than
inherited:

- **A symlinked source whose target leaves the project is dropped by discovery**, not reported. It is
  gate 1 for the same reason `.lake` is: discovery must not hand the writer a file outside the tree it
  was pointed at. An *explicitly named* out-of-root path still errors in `Project.snapshotTarget` —
  there, the user named it.
- **A symlinked source inside the tree resolves to its target and is reported once**, under the target's
  own path, rather than twice under both names. Measured, not assumed: `config show dir/Link.lean`
  returns `relativePath: real/Real.lean`. Two entries would mean two writes to one file in one run.

## The acceptance suite

`tests/discovery/run.sh` (new, 30 assertions, ~40 s). It is separate from `tests/modes/run.sh` because
that suite owns the write path *inside this repository*, where a mistake damages tracked files, while
this one needs arbitrary tree shapes — nested workspaces, symlink loops, a config outside the root,
1,200 files — that cannot be built here without polluting the printer corpus and the git index. Every
fixture is a synthetic Lake project under a temporary directory, driven through the shipped binary.

Coverage, and the specific thing each section is able to catch:

- **Nested workspaces.** The closest config governs its directory and its subdirectories; a sibling
  keeps the root's; and the nested config does **not** inherit the root's `exclude`. That last one is
  the single assertion separating this design from a layered one.
- **`extend`.** Scalars replace, base arrays inherit, `extend-*` concatenates parent-then-child, both
  contributing files are reported parent-first — and provenance is per *setting*: the inherited value
  names `base.toml:4`, the overriding value names `.lean-fmt.toml:3`. A report naming one file for the
  whole config would pass every value assertion and still be useless.
- **Cycles.** `a → b → a` exits 2 and the message names the cycle.
- **Symlinks.** The four cases above, plus the loop-in-a-large-tree timing check.
- **Ignore sources.** All four prune (`.gitignore` directory and glob, `.git/info/exclude`, `.ignore`);
  a nearer `.gitignore` negation re-includes what an outer one excluded; `respect-gitignore = false`
  turns every git source off at once; `config show` lists the sources in force.
- **Explicit paths.** An excluded directory is absent from a no-arg run, an explicitly named excluded
  path is still processed, `force-exclude` withholds it — and `force-exclude` does **not** promote
  `include` into a filter on explicit paths. Those are different questions and conflating them would
  surprise a user who named a file outside `include` deliberately.
- **Migration.** A flat linter key works and warns once (not once per file); flat + `[lint]` is exit 2.
- **Introspection.** Two invocations agree byte for byte and the tree's checksum is unchanged.
- **Scale.** The walk reaches the deepest directory of a 1,200-file tree; a directory with its own
  config uses it while its config-less *sibling* falls back to the root rather than to its neighbor; the
  200-file ignored subtree is pruned.

## Commands

```
bash tests/discovery/run.sh          # failures=0 (30 assertions)
lake build                           # clean, no warnings
lake exe lean-fmt-tests              # passed
tests/{modes,check,compiler,suppression,lossless,scale,service,boundary,syntax}/run.sh   # pass
tests/{catalog,imports,layout,printer,semantic}/run.sh                                   # pass
lake exe lean-fmt docs --check       # docs up to date (17 files)
git diff --check                     # clean
check_stack.py + write_next.py --check docs/projects/ruff-13-config-discovery
```

## Measurement notes, and one thing not measured

Discovery is now timed as its own phase (`phase.discovery_ms`) in both `execute` and `describeConfig`.
It is the one phase this feature added to every run's critical path, and folding it into an existing
phase would have hidden exactly what this prompt owes.

**The timing goes through `config show`, not `check`, and that choice is load-bearing.** A `check` over
the same 1,200-file tree takes about **7 minutes** — but 13 ms of that is discovery. The rest is the
cold per-file pipeline on a tree with no build products, a workload `CLAUDE.md` names separately and
this stack does not own. Measuring discovery through `check` would have reported that cost as though
the walk had caused it. `config show` runs discovery and nothing else, which is why it is the honest
instrument here.

That 7 minutes for 1,000 trivial files is worth someone's attention, and it is **not** this stack's:
the profiled phases sum to under 400 ms, so roughly 99% of the wall time is in an unprofiled per-file
path. Recorded here as an observation with a number attached, not diagnosed, and not fixed — naming it
without evidence would be the same mistake this prompt just corrected in `results/02`.

Also unmeasured: nothing in this stack ran against full mathlib, per the roadmap's evidence policy.

## Remaining uncertainty

- A symlinked *config* file (as opposed to a symlinked source) is not covered. `loadChain` cycle
  detection is by realpath, so the mechanism is present, but the case has no fixture.
- Case-insensitive filesystems are untested. On macOS, `.LEAN-FMT.toml` and `.lean-fmt.toml` name one
  file; whether the "both recognized names present" error can be provoked spuriously there is unknown.
- `notes/01-discovery.md` §15's open questions remain open; none blocked this stack.
