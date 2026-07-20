---
kind: state
first_unresolved: none
---

# Current state

**RCD-SPEC is verified** (`results/01-semantics.md`; design `notes/01-discovery.md`; baseline
`evidence/01-discovery-baseline.md`). Recognized filenames, the discovery walk and its root boundary,
closest-config selection, `extend` composition with cycle detection, pattern path resolution,
ignore-source precedence, explicit-path behavior with `force-exclude`, and flat-config migration with a
truth table are frozen precisely enough for `RCD-IMPL`. Following the `*-SPEC` convention (`ruff-11`
RMR-SPEC, `ruff-12` RRL-SPEC), no production Lean interface, config key, or CLI surface shipped in that
prompt.

Key frozen decisions:

- Recognized filenames are `.lean-fmt.toml` then `lean-fmt.toml`; both in one directory is a hard
  error. `lakefile.toml [tool.lean-fmt]` was **measured to work** — Lake ignores unknown keys on
  v4.33.0-rc1 — and rejected anyway, because that tolerance is undocumented and incidental
  (`notes` §3.1).
- **Hierarchy does not merge.** The closest config applies whole and replaces its ancestors for its
  subtree; `extend` is the only composition. Discovery ascends to the project root and stops, with two
  explicit exceptions: `extend` targets and repository-root detection for git ignore sources.
- **One walk, not one per file.** A single `root.walkDir` builds a directory map; per-file resolution
  is an in-memory ascent; configs are parsed once and memoized by realpath. Pruning ignored subtrees is
  sound only because git's directory-exclusion rule is preserved.
- **Patterns anchor at the declaring config's directory**, never the root and never the consuming file.
  An inherited pattern keeps its parent's anchor.
- `extend` is a single string resolved relative to its declaring file, realpath cycle-detected, depth
  capped at 32. Base arrays replace; the `extend-*` family concatenates — the additive rule those keys
  already have within one file.
- **Sections split on the identity boundary**: top level = discovery/cross-cutting, `[format]` =
  settings that change canonical bytes, `[lint]` = settings that project over results. The rule that
  falls out — **a `[format]` key enters `configurationIdentity`; a `[lint]` key never does** — makes the
  `CLAUDE.md` projection discipline checkable by inspection. `preview` stays top-level.
- Migration keeps every config valid today valid: linter keys accepted flat with a deprecation notice;
  the same key in both places is a hard error; `line-width` gets no flat spelling. The notice channel
  must widen beyond `RulePlan.notices` — an interface change named in the freeze, not left to be
  invented mid-implementation.
- Ignore precedence is a total order: `.lake` floor < global git ignore < `.git/info/exclude` <
  `.gitignore` outer→inner < `.ignore` < config `exclude`. Git config is parsed directly (no `git`
  subprocess); `include`/`includeIf` are deliberately not followed, with the consequence stated.
- `config show PATH --json` reports value/file/line per setting (provenance is available — every
  `Lake.Toml.Value` carries `ref : Syntax`), plus the `extend` chain, ignore sources in precedence
  order, and whether the path would be selected with the deciding gate number.

**RCD-IMPL is verified** (`results/02-implementation.md`). `LeanFmt/Discovery.lean` is the one private
capability: git-ignore matcher, git-config reading, a single `walkDir` pass, the directory→config map,
and the selection gates. `LeanFmt/Config.lean` owns the loader half (`PartialConfig`, `loadChain` with
realpath cycle detection, `[format]`/`[lint]` sections with the §8.2 migration table, `ref`-derived
provenance, `describe`). `SourceTarget` carries `config`/`configKey`; `execute` memoizes one `RulePlan`
per distinct `configKey`; `config show PATH [--json]` ships; `schema.json` is sectioned with the flat
keys retained as `deprecated: true`. The README's configuration section was materially false after the
change and is rewritten.

Amendments and deviations recorded in the result note: `--config` anchors at the **project root** (not
its own directory); the `.lake` error names the resolved path, matching its `snapshotTarget` siblings;
what a run *obtains* stays one batch decision (union over per-file plans, seeded at `.source`) even
though selection is per-file; `Discovery.explain` is separate from `gateFor` because a command-line path
may sit under a directory the walk never entered; the service keeps one root-level plan for its session
lifetime, with per-file configuration deferred to `ruff-16-watch-incremental`.

**Both baseline defects found while characterizing the boundary are closed by `RCD-IMPL`:**

- **CLOSED — An explicit path into `.lake` was accepted, and `format` wrote it.** Measured: `written=1` and the
  bytes of a vendored dependency changed on disk (`evidence` §3). Discovery filters `.lake`
  (`Project.lean:114`) but the requested-path branch checks only existence, root containment, and
  extension. Since `ruff-11d` made `format` a writer by default this is a write-safety defect. The
  freeze makes `.lake` an absolute selection floor no key or path form can lift (`notes` §11).
- **CLOSED — `Application.lean:365-382` was stale.** It cites `Digest.ofBytes (← IO.FS.readBinFile application)`
  at `Cache.lean:258`; commit `62e23fa` replaced that with binary metadata (`Cache.lean:262-264`). The
  conclusion survives, the cited mechanism does not. Rewritten by `RCD-IMPL` in the same commit that
  promotes `line-width`, since that promotion is what invalidates the docstring's argument.

**RCD-FINAL is verified** (`results/03-acceptance.md`). `tests/discovery/run.sh` is the owning
acceptance suite: 30 assertions over synthetic Lake projects covering nested workspaces, `extend`
composition and per-setting provenance, cycles, the symlink matrix, all four ignore sources, explicit
paths with `force-exclude`, migration warnings, deterministic introspection, and discovery timing at
1,200 files.

It found a defect RCD-IMPL shipped: **the walk followed directory symlinks.** It presented as right
answers at enormous cost, because every duplicate realpaths back onto a file already found and is
collapsed by `Project.deduplicate` — measured at **68,420 ms** of discovery on a 1,200-file tree with
one loop in it, against **11 ms** after the fix. The walk now classifies entries with
`symlinkMetadata`, which does not follow links. A symlinked source whose target leaves the project is
dropped by discovery (gate 1, like `.lake`); one inside the tree resolves to its target and is reported
once, not twice. A claim in `results/02-implementation.md` that reasoned from this behavior's *output*
to a mechanism it had not observed is corrected inline there.

Discovery is now timed as its own phase (`phase.discovery_ms`) in both `execute` and `describeConfig`.
Timing is taken through `config show`, which runs discovery and nothing else: a `check` over the same
tree takes ~7 minutes, of which 13 ms is the walk — the rest is the cold per-file pipeline, a workload
`CLAUDE.md` names separately and this stack does not own. That ~7 minutes for 1,000 trivial files is
recorded as an observation with a number attached, undiagnosed and unfixed, and is the most concrete
lead this stack leaves behind.

Prerequisite stacks `ruff-04-formatter-product`, `ruff-11d-format-in-place`, and
`ruff-12-rule-lifecycle` are verified; their live code was re-read for this spec (`Config.lean`,
`Project.lean`, `Cache.lean`, `Application.lean`, `Cli.lean`, `Rules.lean`, `LeanFmtTest.lean`). If
live code contradicts a prerequisite result, reopen the owning prerequisite rather than patching
around it. Full mathlib is not development evidence.

| Prompt | Claim | Status | Depends on |
| --- | --- | --- | --- |
| 01-semantics | RCD-SPEC | verified | — |
| 02-implementation | RCD-IMPL | verified | RCD-SPEC |
| 03-acceptance | RCD-FINAL | verified | RCD-IMPL |

## Blockers and prerequisites

- No blocker recorded. The stack is complete. Uncovered cases named in `results/03-acceptance.md`: a
  symlinked *config* file (the realpath cycle mechanism exists, the fixture does not), and
  case-insensitive filesystems. `notes/01-discovery.md` §15's open questions remain open; none blocked
  this stack.
- Full mathlib is not development evidence; follow this roadmap's evidence policy.

## Verification convention

A claim becomes verified only after its prompt checks pass, its result note records meaningful evidence,
and state agrees with live code. Missing, stale, unsupported, or unread checks are failures to verify.
