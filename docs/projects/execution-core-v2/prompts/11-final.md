---
claim_id: ECV2-FINAL
status: planned
depends_on: [ECV2-ACCEPTANCE]
role: final-audit
---

# Final ground-up architecture audit

## Task

Adversarially verify the completed two-binary system against every roadmap claim. Inspect code and
callers, rerun evidence, and fix root causes before marking completion; prior status text alone is
not evidence.

## Read

- The roadmap, every prompt, state, result, and evidence file.
- Both Cargo manifests, all private application modules, child protocol/Lean code, and build scripts.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/04-modules-should-be-deep.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/05-information-hiding-and-leakage.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/23-summary-of-design-principles.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/deep-module-design/SKILL.md`.
- `~/.codex/plugins/cache/lean-rs-skills/lean-rs-skills/0.1.1/skills/optimizing-lean-performance/SKILL.md`.

## Target

- `docs/projects/execution-core-v2/results/11-final-audit.md` maps each completion claim to inspected
  implementation, tests, and reproducible evidence.
- Exactly two binary crates, no public Rust library API, and one Lean-link site remain.
- `RunEngine` and `LeanRun` are private deep modules with concrete callers and no pass-through layer.
- Oracle equivalence, exact ordered contexts, coarse trace epochs, deterministic modes, service
  ownership, and the 8 GiB aggregate envelope are all demonstrated.

## Stop

Do not verify ECV2-FINAL while any command fails, the mathlib run is incomplete, peak RSS exceeds
8 GiB, a cache hit changes output, ordered-context equivalence is uncertain, or a third/public layer
has reappeared. Reopen the owning claim.

## Check

- Run the deep-module audit and inspect every caller of `RunEngine` and `LeanRun`.
- Confirm workspace membership, binary-only targets, dependency tree, and native link directives.
- Rerun oracle differential, command/service suites, cold mathlib, cached mathlib, and RSS evidence.
- `scripts/fmt.sh`
- `scripts/lint.sh`
- `scripts/test.sh`
- `scripts/lean.sh`
- `git diff --check`
