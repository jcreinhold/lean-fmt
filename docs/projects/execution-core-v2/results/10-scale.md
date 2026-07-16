# ECV2-SCALE result

Status: verified on 2026-07-16.

## Result

The pure-Lean execution core now covers every non-`.lake` source through one private project
capability. Current ordinary module evidence authorizes source-input rules, trusted registered Lake
facets supply syntax when required, and a fresh exact-context frontend remains the bounded fallback.
All evidence paths produce one strategy-independent semantic result before rule projection.

The cache is one source-aware, environment-scoped atomic index. It retains independent per-source
identity checks while eliminating thousands of cache files and defers standalone `ModuleSetup` until
a real miss. A valid all-hit run returns before module evidence, official facets, or exact analysis.

## Acceptance

On the frozen already-built mathlib revision and current machine, a complete 8,795-source cold check
finished in 109.649 seconds with 1,315,248 KiB peak aggregate RSS, normal pressure, and no swap growth.
The subsequent forced worker-free all-hit check finished in 16.290 seconds and produced byte-identical
output. Both are below their ten-minute and thirty-second targets with no omission, crash, abort, or
resource breach.

The syntax-artifact path is covered by focused registered-facet tests. A formatter-integrated full
mathlib run was not performed because no current syntax-input rule would consume the prerequisite
artifacts; it was therefore not a plausible distinct release-candidate path under the stack's
full-run policy.

Detailed identities, phases, rejected designs, monitored diagnostic stops, and raw-record locators
are in [the Prompt 10 acceptance evidence](../evidence/10-scale-acceptance.md). The earlier major-step
record remains in [module-evidence evidence](../evidence/10-scale-module-evidence.md). The sequential
repository checks and manual deep-module inspection are recorded in
[the Prompt 10 gate](../evidence/10-scale-gates.md).
