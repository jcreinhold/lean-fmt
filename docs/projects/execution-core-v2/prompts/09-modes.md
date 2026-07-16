---
claim_id: ECV2-MODES
status: planned
depends_on: [ECV2-CACHE]
---

# Add product modes and conservative writes

## Read

- `roadmap.md`, `state/current.md`, and `notes/09-product-contract.md`
- `LeanFmt/Application.lean`, `LeanFmt/ArtifactModel.lean`, `LeanFmt/Cache.lean`, and
  `LeanFmt/Rules.lean`
- The archived implementation only as characterization evidence for rule/edit behavior; do not
  restore its public APIs, worker controls, or orchestration layers.

## Task

Add `format`, `diff`, `fix`, `rules`, `clean`, and compiler-integration setup/status over the same
semantic result used by check. First add one private edit capability that accepts an immutable source
snapshot and selected findings and returns either a fully checked patch or one typed rejection. The
application operation, not the CLI dispatcher, owns patch preparation, exact validation, stale-source
checking, atomic publication, cache interaction, and deterministic aggregation.

## Product contract

- `check`, `format`, `diff`, and `fix` accept the existing root, positional file, text/JSON,
  `--no-cache`, and `--max-memory` intent. They additionally accept an explicit `--config`,
  repeatable `--select` and `--ignore`, `--statistics`, and `fix --check-elab`. There is no jobs,
  pinning, unsafe-validation, or execution-strategy option.
- The optional `lean-fmt.toml` configuration has only `include`, `exclude`, `select`, `ignore`, and
  `per-file-ignores`. CLI selection replaces configured selection when present; ignores are then
  applied and always win. Selectors are `all`, `text`, or exact rule codes. Unknown selectors,
  malformed values, and unknown configuration keys are infrastructure errors rather than silently
  ignored input.
- Positional files are exact requested modules. Without positionals, selection starts from root
  package library modules, then applies include/exclude patterns to normalized root-relative paths.
  Per-file ignores use the same normalized pattern semantics. Results remain path-sorted after every
  projection.
- `check` renders selected findings. `format` renders the complete proposed source for changed files
  in deterministic path-delimited text blocks or JSON fields. `diff` renders a deterministic unified
  diff. None writes project source. `fix` is the only command that writes `.lean` source.
- `rules` renders the stable registry—including code, category, summary, fix availability, and
  default state—in text or JSON without loading a workspace.
- `clean --root PATH` removes only that workspace's `.lean-fmt-cache`; an absent cache is success and
  no source, Lake build output, or compiler artifact is removed.
- `compiler setup` emits versioned, deterministic text/JSON integration guidance for this package's
  module plugin/facet and does not rewrite executable `lakefile.lean`. `compiler status --root PATH`
  evaluates the workspace read-only and reports exact toolchain compatibility and deterministic
  per-module trusted-artifact coverage without building modules or publishing artifacts. These
  commands do not introduce an installer or a second execution path.
- Text stdout and JSON stdout are deterministic product output. Statistics and warnings go only to
  stderr. Exit `0` means clean/successfully previewed or applied output, `1` means findings, broken
  sources, or rejected fixes, and `2` means request/workspace/infrastructure failure. `format` and
  `diff` return `1` when they propose changes; `fix` returns `0` when every proposed change was
  safely applied.

## Edit and validation contract

- Patch preparation validates every half-open byte range, UTF-8 boundary, expected source snapshot,
  replacement encoding, and overlap before exposing output. A rejection exposes no partial patch.
  Adjacent edits are allowed; conflicting insertions or overlapping replacements are rejected.
- Rule selection is a presentation/edit projection over the canonical semantic result. It never
  changes parser strategy and must not cause strategy-dependent cache entries. Formatting applies
  all and only selected safe fixes in deterministic source order.
- Before a write, analyze the proposed complete source under the same exact module setup, ordered
  paths, toolchain, options, and validation identity as the result that produced its edits. The
  default gate may be stronger than syntax-only when the available exact frontend primitive fully
  elaborates; `--check-elab` remains a distinct declared identity and may never be implemented as a
  weaker check.
- After validation and immediately before publication, reread the target and require byte identity
  with the original snapshot. Publish through a same-directory temporary file and rename while
  preserving the target's permissions. Any validation, conflict, stale-source, or write failure
  leaves that file unchanged. Multi-file atomicity is per file; one rejected file does not erase
  reports for the others.
- Never validate edited output from the pre-edit result cache, and never cache a rejected edited
  candidate as the original source's result. A successful write may invalidate/remove the original
  entry; future lookup must be keyed by the new source.

## Target

- Check, format, and diff never write source; fix is the only source-writing mode.
- Range and conflict checks are atomic and unconditional; fix writes only output validated under the
  exact identity represented by its result.
- Configuration, ignore/selection, statistics, cache controls, and `--max-memory` express user intent,
  not worker strategy.
- Compiler integration is an auditable module-system configuration, not an imperative lifecycle or
  automatic edit of an executable Lake program.

## Check

- Golden and property tests cover reversibility, overlap rejection, stale artifacts, rejected
  validation, unchanged files, and every mode's write behavior.
- Tests cover selector precedence, include/exclude and per-file patterns, deterministic text/JSON,
  exit codes, stderr-only statistics, clean scope/idempotence, setup output, and read-only status.
- A cache hit and either semantic source (trusted module artifact or exact fallback) produce
  byte-identical selected output and patches.
- Every production and test Lean source compiled by this package begins with `module`; executable
  Lake configuration files are the only repository exception.
- Run the focused unit/integration suite before the full build. Do not run complete mathlib here;
  Prompt 10 owns sampled optimization and late release-candidate acceptance.
- `lake build`
- `git diff --check`

## Stop

Stop for replanning instead of weakening validation, treating arbitrary Lake source as safely
rewritable, silently accepting unknown configuration, inventing strategy controls, or adding a
second analyzer/orchestrator. Ordinary Lean API/name drift, missing small edit/diff/config helpers,
and a failed first implementation attempt are not blockers.
