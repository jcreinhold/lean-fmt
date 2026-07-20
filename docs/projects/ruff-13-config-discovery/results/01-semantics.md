---
kind: result
claim_id: RCD-SPEC
status: verified
---

# RCD-SPEC — discovery, inheritance, ignore precedence, and migration, frozen

Recognized filenames, the discovery walk and its root boundary, closest-config selection, `extend`
composition with cycle detection, pattern path resolution, ignore-source precedence, explicit-path
behavior with `force-exclude`, and flat-config migration with a truth table are specified precisely
enough for `RCD-IMPL`. The design is `notes/01-discovery.md`; the measured baseline it maps is
`evidence/01-discovery-baseline.md`.

As with the prior `*-SPEC` prompts (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC), **no production Lean
interface, config key, or CLI surface ships in this prompt** — the freeze is the note plus the recorded
baseline; `RCD-IMPL` wires it.

## Commands run

```
$ cd /Users/jcreinhold/Code/lean-fmt && LEAN_NUM_THREADS=1 lake build          # exit 0
$ lake resolve-deps        # in probe project, unknown lakefile.toml keys       # exit 0
$ lake build               # in probe project                                   # exit 0
$ lean-fmt check  --root P                                    # files=1 (.lake skipped)
$ lean-fmt check  --root P .lake/packages/dep/Dep.lean        # files=1 findings=1 (accepted)
$ lean-fmt format --root P .lake/packages/dep/Dep.lean        # written=1  (defect)
$ od -c P/.lake/packages/dep/Dep.lean                         # bytes changed on disk
```

Raw transcripts, with the toolchain/machine/commit identification the roadmap requires, are in
`evidence/01-discovery-baseline.md`. No timing claim is made in this prompt — `RCD-SPEC` is docs-only
and the discovery-performance measurement belongs to `RCD-FINAL`.

## What was decided

- **Recognized filenames: `.lean-fmt.toml` then `lean-fmt.toml`, and nothing else.** Both present in
  one directory is a hard error, matching the existing `extend-safe`/`extend-unsafe` conflict rule
  (`Config.lean:434-436`) rather than a silent priority win.
- **`lakefile.toml [tool.lean-fmt]` was measured to work, and rejected anyway.** Lake's decoder ignores
  unknown keys — both an unknown `[tool.*]` table and an unknown top-level scalar load and build with
  exit 0 on v4.33.0-rc1 (`evidence` §2), consistent with `Lake/Load/Toml.lean:405-421`. That tolerance
  is undocumented and incidental; a future Lake that validates its own schema would break every project
  that relied on it, through a failure path we do not control. Declined on durability, not capability
  (`notes` §3.1, open question 1).
- **Hierarchy does not merge; inheritance is explicit.** The closest config applies whole and replaces
  its ancestors for the subtree it governs; `extend` is the only composition. This is the roadmap's
  "explicit inheritance", and it is stated as a rule because implicit ancestor merging is what a reader
  will otherwise assume.
- **Discovery ascends to the project root and stops.** The root is already the containment boundary for
  every source (`insideRoot`, `Project.lean:90-92`) and the authority boundary for project semantics.
  Two explicit exceptions: `extend` may name a path outside it, and repository-root detection for git
  ignore sources may ascend above it, since a Lean project is commonly a subdirectory of a repository.
- **One walk, not one per file.** `RCD-IMPL`'s stop rule is satisfied structurally: a single
  `root.walkDir` collects sources, config files, and ignore files into a directory map; per-file
  resolution is an in-memory ascent; each config file is parsed once, memoized by realpath. Pruned
  directories cost nothing, which is sound only because git's directory-exclusion rule is preserved.
- **Patterns anchor at the declaring config's directory** — never the project root, never the consuming
  file. Today those coincide because there is exactly one root config, so this is the rule a careless
  implementation gets silently wrong. An inherited `exclude` keeps the parent's anchor; re-anchoring at
  the inheritor was considered and rejected (a pattern's meaning must not depend on who inherited it).
- **`extend` is a single string, resolved relative to its declaring file**, cycle-detected by realpath
  with the cycle printed in encounter order, and depth-capped at 32 as a resource bound. Merge is
  child-over-parent, with base arrays replacing and the `extend-*` family concatenating — the same
  additive rule those keys already have within one file (`Config.lean:427-428`). Duplicates and order
  are preserved because `resolveAxis` folds with `Nat.max` (`Config.lean:400-408`), making them
  unobservable in the plan while keeping provenance able to name every contributing file.
- **Sections split on the identity boundary, not on taste.** Top level holds discovery and
  cross-cutting policy (`extend`, `include`, `exclude`, `force-exclude`, `respect-gitignore`,
  `preview`); `[format]` holds settings that change canonical bytes; `[lint]` holds settings that
  project over results. The sharp rule that falls out — **a `[format]` key enters
  `configurationIdentity`, a `[lint]` key never does** — is what makes the `CLAUDE.md` projection
  discipline checkable by inspection rather than by argument.
- **Migration keeps every config valid today valid.** Linter keys stay accepted at the top level with a
  non-fatal deprecation notice; the same key set in both places is a hard error, not a precedence
  puzzle; `line-width` is new so it gets no flat spelling and top-level use is a hard error. Full truth
  table in `notes` §8.2.
- **The notice channel must widen.** Migration notices ride the existing non-fatal contract
  (`RulePlan.notices`, `Config.lean:66-70`: stderr, never changes exit status or which rules run), but
  today's plan-shaped field cannot carry `[format]`/discovery notices. That is an interface change,
  called out in the freeze so `RCD-IMPL` does not invent it mid-flight.
- **Ignore precedence is fixed as a total order** (`notes` §10.1): `.lake` floor < global git ignore <
  `.git/info/exclude` < `.gitignore` outer→inner < `.ignore` (outranking `.gitignore` at the same
  directory, per ripgrep) < config `exclude`. Last-match-wins within a file, nearer-file-wins between
  files, and git's directory-exclusion rule preserved.
- **Git config is parsed directly, not via a subprocess**, so lean-fmt does not require `git` on `PATH`
  to format a repository. This is deliberately partial: `include`/`includeIf` directives are not
  followed, and the user-visible consequence (global ignores unreachable through a conditional include
  are not applied) is stated rather than hidden (open question 5).
- **`config show PATH --json` reports value, file, and line per setting.** Provenance to `file:line` is
  available without a second parse: every `Lake.Toml.Value` constructor carries `ref : Syntax`
  (`Lake/Toml/Data/Value.lean:27-49`). It also reports the owning config, the full `extend` chain, the
  ignore sources in precedence order, and whether the path would be selected **with the deciding gate
  number** — "would this file be formatted, and why not" is the question the command exists to answer.

## Baseline defects found and assigned

Characterizing the current boundary turned up two, both recorded with evidence:

- **An explicit path into `.lake` is accepted, and `format` writes it.** Discovery filters `.lake`
  (`Project.lean:114`) but the requested-path branch checks only existence, root containment, and
  extension (`Project.lean:139-160`, `94-106`). Measured: `lean-fmt format --root P
  .lake/packages/dep/Dep.lean` reported `written=1` and changed the bytes of a vendored dependency on
  disk (`evidence` §3). Since `ruff-11d` made `format` a writer by default this is a write-safety
  defect, not a reporting quirk. The freeze makes `.lake` gate 1 of the selection table — absolute, and
  liftable by no key, no path form, and no `force-exclude` setting — and assigns `RCD-IMPL` to move the
  test into the shared containment check so both path forms pass through it (`notes` §11).
- **A stale docstring at `Application.lean:365-382`.** It justifies the constant margin by citing
  `formatter := Digest.ofBytes (← IO.FS.readBinFile application)` at `Cache.lean:258`; commit `62e23fa`
  replaced that with binary metadata (`Cache.lean:262-264`). The conclusion survives — a rebuild still
  changes size and mtime — but the cited mechanism does not exist. Assigned to `RCD-IMPL`, in the same
  commit that promotes `line-width`, since that promotion is exactly what invalidates the docstring's
  argument (`notes` §9.1).

Neither is a stop condition: both fall inside this stack's stated contract (explicit-path behavior and
which files are *published*; the cache-identity consequence of a runtime margin).

## Decisions changed during execution

- The `lakefile.toml` question was expected to be settled by reading Lake's decoder. Reading was
  inconclusive (no explicit reject-unknown pass, but absence of a pass is not a guarantee), so it was
  settled empirically instead. The probe *succeeded*, which inverted the shape of the decision from
  "can we?" to "should we depend on undocumented tolerance?" — recorded as such rather than as a
  capability finding.
- `force-exclude`'s interaction with `include` was initially assumed symmetric with `exclude`. It is
  specified asymmetric: `force-exclude` re-enables exclusions for explicit paths but never the
  `include` whitelist, because `include` answers "when I say nothing, format these" and naming a path
  is saying something. Flagged as the table's one judgment call, for `RCD-FINAL` to test both ways.
- `preview` was going to move into `[lint]`. It stays top-level, where it already is
  (`Config.lean:207-210`), because it gates formatter behavior as well as rule selection — so it needs
  no migration row at all.

## Files changed

- `docs/projects/ruff-13-config-discovery/notes/01-discovery.md` (new — the freeze)
- `docs/projects/ruff-13-config-discovery/evidence/01-discovery-baseline.md` (new — raw transcripts)
- `docs/projects/ruff-13-config-discovery/results/01-semantics.md` (new — this note)
- `docs/projects/ruff-13-config-discovery/state/current.md`, `state/next.md` (updated)

No production Lean source changed in this prompt.

## Checks read

- `LEAN_NUM_THREADS=1 lake build` — exit 0 (baseline; no production source touched).
- `tests/boundary/run.sh` — passing (see below); no module boundary changed in this prompt.
- Stack structural checker and `write_next.py --check` for
  `docs/projects/ruff-13-config-discovery` — passing.
- `git diff --check` — clean.
- Full mathlib was **not** run, per this roadmap's evidence policy.

## Remaining uncertainty

- **`line-width` bounds are asserted, not measured** (`1 ≤ n ≤ 1000`). `RCD-FINAL` must confirm the
  printer terminates and emits valid output at both extremes on a real file; the lower bound in
  particular is a claim about `Doc.go`'s fit test that has not been exercised.
- **Discovery cost on a large tree is unmeasured.** The one-walk design is argued structurally, not
  timed. `RCD-FINAL` owns the measurement, per the roadmap's performance schema.
- **The notice-channel widening has no chosen shape.** The freeze establishes that `RulePlan.notices`
  is too narrow and that the contract must be preserved; which type carries it is `RCD-IMPL`'s
  interface decision.
- **Git pattern semantics are specified from the documented git rules, not from a differential test
  against git itself.** `RCD-FINAL` should consider a differential check on a fixture tree if one is
  cheap; the directory-exclusion rule is the one most likely to be gotten subtly wrong, and pruning
  soundness depends on it.
- **Symlinked source trees** are named in `RCD-FINAL`'s task but only lightly specified here: realpath
  identity governs `extend` cycles and config memoization, and `Project.load` already realpaths every
  target. Whether a symlink *into* the tree from outside should be followed during discovery is not
  decided.
