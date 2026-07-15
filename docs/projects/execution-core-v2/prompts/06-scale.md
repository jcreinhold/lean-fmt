---
claim_id: ECV2-SCALE
status: planned
depends_on: [ECV2-REUSE]
---

# Scale within an 8 GiB aggregate envelope

## Task

Make the reused check path complete over mathlib while enforcing an 8 GiB ceiling across the parent,
child, and descendants. Bound Lean threads and allocator growth, sample process-tree RSS, and rotate
`LeanRun` at a measured safe point before retained state threatens the envelope.

## Read

- ECV2-REUSE timing and RSS evidence.
- Child process and memory-limit facilities in lean-rs.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/20-designing-for-performance.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`.

## Target

- One aggregate memory policy owned by `RunEngine`; every spawned process is included.
- Default execution remains at or below 8 GiB peak process-tree RSS with reserved parent/OS headroom.
- A bounded child lifecycle prevents unbounded environment retention; rotation preserves exact
  results and resumes at a file boundary.
- Crossing the hard envelope terminates the child cleanly and reports the affected file and measured
  memory instead of relying on OS OOM behavior.

## Stop

Do not raise the envelope to pass acceptance. Do not add concurrency before measurements show it is
both necessary and safe. Do not rotate in the middle of a protocol operation or lose a file.

## Check

- Stress tests use a process-tree RSS monitor and assert the 8 GiB limit.
- Forced low-limit tests prove clean termination, complete accounting, and deterministic resume.
- Compare reports before and after child rotation.
- Run an uncached mathlib check and record file count, wall time, rotation count, and peak RSS.
- `cargo test --workspace`
- `git diff --check`
