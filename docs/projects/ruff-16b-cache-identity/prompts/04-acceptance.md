---
claim_id: RCI-FINAL
status: planned
depends_on: [RCI-IMPL]
---

# Audit invalidation and settle the watch workaround

## Task

Deliver **RCI-FINAL**: Exercise adversarial edit and graph shapes against the new identity, verify no
stale hit under any of them, settle index accumulation and collection, and decide on measurement whether
watch's per-generation re-exec comes out.

Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests,
and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and
characterization tests before implementation where the behavior is not already frozen.

## Target

- Implement the task behind the existing private intent-to-report architecture; keep CLI presentation in
  `LeanFmt.Cli` and lifecycle/cache/project complexity below callers.
- Add or update focused fixtures and persistent regression tests at the owning layer.
- Write `results/03-acceptance.md` with exact commands, raw outputs or evidence locators, measurements,
  decisions changed during execution, and remaining uncertainty.
- Update `state/current.md` only after reading the checks, then regenerate `state/next.md`.

## Plan

1. Adversarial graph and edit shapes, each asserted at entry granularity: a module added mid-closure, a
   module deleted mid-closure, an import edge added and removed, a module renamed, a widely-imported
   module edited, a `choice`-node and `#exit` file in the closure, and a file whose only change is
   normalization-visible (CRLF).
2. Non-source invalidation still works: config change, `lean-toolchain` change, dependency rebuild,
   formatter rebuild. These must remain full invalidations where they were.
3. Index accumulation and collection under repeated edits; confirm the disk footprint is bounded and
   stale indices are collectable.
4. **Settle the watch re-exec question on measurement.** Compare an in-process watch generation against
   the current child-process generation on the same fixture: wall time per generation and parent RSS
   across at least a dozen generations. `ruff-16` measured re-exec at ~400 ms fixed cost and 16 KiB
   growth over 13 generations; beat both or keep re-exec and say so. Record the decision either way, and
   if re-exec stays, correct `ruff-16`'s stated *reason* for it regardless.
5. Confirm the `ruff-16` record correction from `RCI-SPEC` survived implementation and that no document
   still asserts the in-process defect.
6. Inspect all callers and documentation for leaked mechanism or claims stronger than evidence.

## Stop

- **A stale hit is a stop, not a finding to file.** Reopen the identity.
- Do not remove watch's re-exec because the original justification was wrong; remove it only if
  in-process wins on measurement, since re-exec independently buys the retention `ruff-16` measured.
- Do not report invalidation improvements in wall time alone; wall time cannot distinguish a cache hit
  from a warm page cache, which is the error this stack exists to correct.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.

## Check

- Run `LEAN_NUM_THREADS=1 lake build` and `lake exe lean-fmt-tests`.
- Run the full suite list in `CLAUDE.md`, and inspect every changed module boundary manually.
- Use focused fixtures and the frozen sample for scale; complete mathlib is forbidden in this stack.
- From the KanProofs tool environment, run the generic stack structural checker and
  `write_next.py --check` for `docs/projects/ruff-16b-cache-identity`.
- Run `git diff --check` and read all output before marking RCI-FINAL verified.
