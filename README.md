# lean-fmt

A formatter and linter for Lean 4, being rebuilt as a native Lean application.

The active implementation is intentionally the minimal project produced from `lake init`. Design
and performance work is tracked in `docs/projects/execution-core-v2/`; experiments remain isolated
under `experiments/` and are not production dependencies.

```sh
lake build
lake exe lean-fmt
```
