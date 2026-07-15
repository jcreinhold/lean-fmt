# Evidence-policy repair gate

Date: 2026-07-15

## Repaired inconsistency

`ECV2-SCALE` required three complete runs for each workload path, while `ECV2-FINAL` appeared to
require those suites again. The repaired roadmap reserves complete mathlib execution for a candidate
whose representative evidence makes acceptance plausible, requires one monitored run per relevant
path, and lets the final audit reuse evidence keyed by binary, workload, toolchain, and configuration
digests.

The first unresolved claim remains `ECV2-COMPILER-ARTIFACTS`; no dependency or status changed.

## Gates

| Gate | Result |
| --- | --- |
| Generic structural checker | pass; 12 prompts, 0 warnings, no errors |
| Generated `state/next.md` check | pass; first unresolved remains `05-compiler-artifacts` |
| Scope | documentation-only; no production or measurement data changed |

Commands:

```text
uv run --with pyyaml python \
  /Users/jcreinhold/Code/kan-proofs/.claude/skills/lean-plan/scripts/check_stack.py \
  docs/projects/execution-core-v2 --structural
uv run --with pyyaml python \
  /Users/jcreinhold/Code/kan-proofs/.claude/skills/lean-plan/scripts/write_next.py \
  docs/projects/execution-core-v2 --check
```
