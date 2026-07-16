---
claim_id: ECV2-FINAL
status: planned
depends_on: [ECV2-SERVE]
role: final-audit
---

# Audit the native Lean replacement from fresh evidence

## Read

- `roadmap.md`, `state/current.md`, every result note, and the evidence records for Prompts 10 and 11.
- `AGENTS.md`, `README.md`, `lakefile.lean`, every active production/entry/test module, and every
  repository gate script. Read current source rather than carrying forward architectural conclusions.
- The recorded full-mathlib profile metadata and current executable digest before deciding whether a
  complete path must run again.

## Task

Rerun correctness, architecture, performance, resource, packaging, and documentation checks from a
fresh read. Fix root causes before marking completion.

## Target

- `results/12-final-audit.md` maps every roadmap claim to implementation and reproducible evidence.
- No Rust workspace, worker protocol, public strategy DTO, temporal lifecycle API, pass-through
  module, or legacy production source has returned.
- Common callers know nothing about cache keys, ordered search roots, plugin loading, child lifetimes,
  retries, or resource scheduling.
- Documentation distinguishes ordinary-built, formatter-integrated, cache-cold, and cache-warm claims.

## Requirement audit

Create `results/12-final-audit.md` as a table mapping every roadmap completion-contract clause and
each Prompt 12 target/check to: implementation owner, direct test or inspection, performance/resource
record where applicable, and conclusion. “No match found” is not evidence unless the search scope and
the positive replacement boundary are both named.

- Re-derive exactness, complete selection, deterministic reports, cache identity, compiler-artifact
  authority, edit transaction, service semantics, and resource enforcement from the live modules and
  focused tests. Confirm tests actually reach their claimed evidence paths.
- Enumerate all active declarations and production callers. Require the empty `LeanFmt` root, no
  public application declarations, executable entry points only, private constructors for project,
  patch, cache, and exact-run capabilities, and no caller-visible lifecycle or strategy sequencing.
- Enumerate tracked source kinds and Lake targets. Require no `.rs`, `Cargo.toml`, worker protocol,
  archived production module, generated binary, cache, or build artifact in the active source tree.
  The historical branch may exist; it is not part of the active package.
- Verify every compiled `.lean` source starts with `module`; executable `lakefile.lean` files are the
  only exception. Inspect the Lake dependency graph so compiler-plugin modules cannot import
  application/cache/service modules and ordinary `LeanFmt` imports export no API.
- Audit README/AGENTS/roadmap/results for stale Rust, worker, jobs, pinning, unsafe validation,
  strategy-based cache, module-only selection, accumulated/superset parsing, or misleading cold/warm
  wording. Historical rejection evidence may name those designs only as rejected history.

## Performance evidence rule

Compare the current executable SHA-256 with ECV2-SCALE's accepted binary. If it differs and active
batch production code changed, run exactly one monitored ordinary-built formatter-cache-cold full
mathlib check and its immediate forced worker-free warm check. Reuse the frozen project/source
manifest; stop on the existing 8 GiB, pressure-level, or swap-growth gates. Both reports must contain
exactly 8,795 unique bytewise-sorted paths and be byte-identical. Do not rerun the formatter-integrated
full workload while no syntax-input rule would consume it.

If the current digest and relevant configuration match accepted evidence, validate the saved report
digests/count/order directly instead. Documentation-only changes after the candidate build do not
invalidate a recorded binary digest.

## Clean-source packaging

Export tracked `HEAD` to a temporary directory with `git archive`, assert ignored/untracked state is
absent, and build the default package/executable with its pinned toolchain. Run `lean-fmt --help`, a
focused clean `check`, `lean-fmt-tests`, and an NDJSON health/shutdown smoke from that export. Confirm
the installed product is named `lean-fmt`, the package contains no Rust/workers, and the empty root
module exposes no application API. Installation/publishing to a remote registry is out of scope;
clean tracked sources must be self-contained.

## Stop

Do not verify while any required command fails, exactness is uncertain, reports omit files, resource
bounds are breached, or performance wording exceeds measurements.

## Check

- Sequentially run `lake build`, `lake exe lean-fmt-tests`, `tests/compiler/run.sh`,
  `tests/check/run.sh`, `tests/modes/run.sh`, `tests/scale/run.sh`, and `tests/service/run.sh` with one
  Lean thread. Read each negative-test restoration sentinel.
- Run the module-first guard, tracked-source/boundary searches, clean-source packaging gate, and
  deep-module audit; inspect all production callers by hand because the audit script has no Lean
  backend.
- Validate or refresh ECV2-SCALE under the performance-evidence rule, and validate ECV2-SERVE's saved
  profile metadata against the final candidate digest.
- Regenerate `state/next.md`, then run the generic structural checker, generated-next checker, and
  `git diff --check`.
- Mark Prompt 12 and state complete only after the requirement table contains no missing, indirect,
  contradictory, or uncertain row.
