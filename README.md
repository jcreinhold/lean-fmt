# lean-fmt

A formatter and linter for Lean 4, being rebuilt as a native Lean application.

The active implementation is a private-by-default Lean module system rooted at `LeanFmt`. Its first
compiler capability stores formatter results in Lean's persistent `.olean` lint log after successful
elaboration; a Lake module facet owns supported extraction into a compact content-addressed result.
The product CLI is still under construction. Design and performance work is tracked in
`docs/projects/execution-core-v2/`, and experiments remain isolated under `experiments/`.

```sh
lake build
lake exe lean-fmt
tests/compiler/run.sh
```
