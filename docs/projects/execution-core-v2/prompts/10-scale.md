---
claim_id: ECV2-SCALE
status: verified
depends_on: [ECV2-MODES]
---

# Optimize and accept complete mathlib-scale execution

## Read

- `roadmap.md`, `state/current.md`, `notes/03-semantics-and-workloads.md`,
  `notes/04-ordinary-built-cold.md`, `notes/05-module-system-correction.md`, and
  `notes/10-scale-design.md`.
- `LeanFmt/Application.lean`, `LeanFmt/ArtifactModel.lean`, `LeanFmt/Analysis.lean`,
  `LeanFmt/Cache.lean`, `LeanFmt/Rules.lean`, and the target Lean/Lake APIs that own module traces,
  `ModuleSetup`, and `setupServerModule`.
- Existing raw measurements before starting a new profile. Reuse evidence when its binary, workload,
  toolchain, build state, cache state, and configuration identities still match.

## Task

Replace module-only batch execution with complete source-target execution, separate product semantics
from compiler projection, and measure the cheapest sound evidence path for each rule requirement.
Optimize ordinary-built cold, formatter-integrated cache-cold, and result-cache-warm execution in
that order, advancing only plausible candidates to full mathlib acceptance.

## Repair prerequisite: make selection complete

The batch implementation currently selects only root-package `Lake.Module`s. The frozen acceptance
workload is instead every one of the 8,795 non-`.lake` Lean sources, including standalone scripts and
Lake configuration sources that do not have an ordinary module output. Replace module-only selection
with one private source-target capability before making any scale claim.

- With no positionals, recursively select every root-relative `.lean` source outside `.lake`, then
  apply the configured include/exclude policy. With positionals, accept exact `.lean` sources inside
  the root even when they are not buildable library modules. Canonicalize, deduplicate, and bytewise
  path-sort both forms.
- A source target owns its immutable source snapshot and either its exact buildable `Lake.Module` or
  the information needed to obtain its exact `ModuleSetup` through Lake. Callers do not branch on the
  distinction or sequence setup themselves.
- Buildable modules derive setup and current-artifact evidence from Lake's module graph. Standalone
  sources use `setupServerModule` only when analysis or identity actually requires it. Missing setup
  is a clear per-file or infrastructure result, never an omitted file or a fabricated minimal setup.
- Generalize semantic cache identity and reporting from `Lake.Module` to the source target. An
  all-hit run starts no frontend/analyzer/extractor process. Do not run one setup job for each of the
  thousands of ordinary modules on the warm path; if the small standalone remainder requires setup
  resolution, measure it separately and keep the complete warm run below its target.
- Add coverage tests proving the default report has exactly one deterministic result for every
  selected package source, including standalone, malformed-header, unresolved-import, and explicit
  non-module files.

## Design prerequisite: express rule evidence honestly

Current FMT001/FMT002 findings are functions of the immutable source bytes. The implementation still
requires a compiler `ModuleArtifact`, including a command projection, before it can represent those
findings. That representation forces expensive frontend work and invites a fake empty syntax payload.
Remove that accidental coupling before optimizing.

- Define the canonical semantic result around product findings, diagnostics, source identity, and
  validation evidence. Compiler command projection remains a compiler/artifact detail and is not
  stored in a source-only result merely to satisfy a broad DTO.
- Each rule declares the weakest sufficient semantic input, initially source bytes or exact syntax.
  Construct one private rule plan that says whether any selected enabled rule requires syntax. Do
  not expose this as a CLI strategy switch.
- A current ordinary `.olean`, accepted by Lake's no-build trace check for the exact source target,
  is successful exact compilation evidence. It may authorize source-only rules without loading the
  frontend. It does not manufacture syntax, reproduce warnings not present in the product contract,
  or authorize a syntax-dependent rule.
- A trusted formatter-integrated artifact may satisfy source and syntax rule requirements. Otherwise
  a syntax-dependent rule uses the fresh exact-context frontend fallback. Edited candidates continue
  to use fresh exact validation because the old `.olean` does not describe the edited source.
- Cache identity is semantic and includes the rule/runtime version and validation identity, never the
  evidence strategy. Module evidence, compiler artifacts, exact fallback, and cache hits must produce
  byte-identical canonical results for the same source and selected product semantics.

## Measurement ladder

Use paired trials and retain raw phase/per-file evidence. Remove an optimization that does not
materially improve end-to-end time unless it independently makes the implementation simpler.

1. **Current critical path.** Measure the unchanged release binary on focused fixtures, the frozen
   62-file sample, and named heavy/standalone files. Separate workspace load, selection/snapshot,
   cache epoch, cache lookup, module-trace validation, artifact access, frontend fallback, rules,
   projection, and rendering. Stop a known-losing run once the hypothesis is decided.
2. **Ordinary module evidence.** On the frozen sample, compare a batched Lake no-build current-olean
   check plus source rules against independent fresh exact frontend results. Include stale source,
   stale dependency, broken source, custom plugin/syntax, missing own output, and corrupt trace cases.
   Retain the path only if it fails closed and is byte-identical to the product oracle.
3. **Formatter-integrated evidence.** Validate and consume the package-owned `leanFmtArtifact` facet
   directly when its official Lake trace and exact source/module identity are current. Do not rebuild
   an equivalent private facet or spawn one extractor per module on the cold consumption path. Compare
   direct consumption against independent extraction and corruption/invalidation fixtures.
4. **Cache epoch and lookup.** Optimize only if they remain material after the first two paths.
   Preserve ordered roots, trustworthy traces, toolchain/runtime/configuration/validation identity,
   corruption-as-miss behavior, and atomic writes.
5. **Private concurrency.** First remove repeated work. Test exactly two isolated frontend sessions
   only if remaining fallback work prevents the target; retain concurrency only for at least 20%
   end-to-end improvement while the same aggregate envelope holds. Never expose jobs or pinning.

Do not promote the experimental same-process accumulated-import batch. It is admissible only after
new differential evidence proves exact per-file isolation and retained-state memory behavior; process
exit remains the supported reclamation boundary for frontend fallback.

## Acceptance targets

- Ordinary-built, formatter-cache-cold aims below ten minutes and records the best exact time if a
  measured upstream Lean limitation remains. Prerequisite project builds are excluded and reported
  separately.
- Formatter-integrated-built, formatter-cache-cold completes below ten minutes. The formatter
  artifact prerequisite build is timed separately and is never called ordinary-built execution.
- Formatter-cache-warm completes below 30 seconds without starting a frontend, analyzer, or extractor
  process.
- Every accepted full path covers exactly the frozen 8,795 sources and produces no missing file,
  crash, abort, pressure excursion, aggregate RSS above 8 GiB, or swap growth above 256 MiB.
- Evidence names machine, revisions, toolchain, build/artifact/cache states, source and binary digests,
  command, wall and phase times, peak aggregate RSS, live pressure, swap delta, exit, and output digest.

## Full-run policy

Development uses focused fixtures, the frozen 62-file sample, named worst cases, and targeted retention
tests. Advance a path to one monitored full acceptance only when sampled evidence and complete source
coverage make its target plausible. Reuse the full result while all relevant identities remain
unchanged. If a path is implausible, record the best exact sample and limitation rather than spending
a full run to reproduce the projection.

## Check

- Focused complete-selection, standalone-setup, rule-requirement, stale/corrupt-evidence, cache, and
  deterministic-report suites pass.
- Every optimized semantic source is differentially sampled against fresh exact frontend results;
  source-only module evidence also includes deliberately stale/broken negative cases.
- Paired representative profiles retain raw phase and per-file evidence.
- One monitored full acceptance is recorded for each plausible release-candidate path, and only for
  such paths.
- Every production and test Lean source compiled by this package begins with `module`; executable
  `lakefile.lean` configuration is the only repository exception.
- `lake build`
- `git diff --check`
- Run the stack structural checker and generated-next checker.

## Stop

Stop for replanning instead of weakening exactness, omitting standalone files, treating an `.olean`
as syntax it does not contain, hiding prerequisite compilation, accepting an untraced sidecar, or
raising the memory envelope. Ordinary Lean API/name drift, a missing small filesystem/setup helper,
and a failed first measurement or implementation attempt are not blockers.
