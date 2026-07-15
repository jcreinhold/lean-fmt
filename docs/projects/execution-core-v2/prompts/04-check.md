---
claim_id: ECV2-CHECK
status: planned
depends_on: [ECV2-DESIGN]
---

# Implement check end to end

## Task

Implement the first complete product path: `lean-fmt check`. Discover the target Lake workspace,
select files deterministically, run each through the oracle with its exact ordered imports and
options, and render stable findings and exit status without writing files.

## Read

- ECV2-ORACLE fixtures and ECV2-DESIGN decision note.
- Current Lake/toolchain discovery APIs and the target project's `lake env` behavior.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/08-pull-complexity-downwards.md`.
- `~/Code/papers/logic-and-computation/software-engineering/philosophy-of-software-design/18-code-should-be-obvious.md`.

## Target

- A private command path from argument parsing through `RunEngine` and `LeanRun` to text and JSON
  reports.
- Complete Lake environment and exact project toolchain resolution, with explicit errors rather
  than guessed build directories.
- Path-sorted complete reports; a broken file is reported without aborting unrelated files.
- Check never writes source or cache state and has tested success, findings, parse failure, and
  infrastructure-failure exit semantics.

## Stop

Do not add formatting modes, caching, service behavior, or speculative configuration. Stop if any
fixture differs from the Lean oracle or if the application needs to infer import semantics.

## Check

- End-to-end CLI tests cover clean, changed, broken, custom-syntax, mixed, and missing-environment cases.
- Verify source mtimes and contents are unchanged by every check test.
- Compare child results with ECV2-ORACLE goldens.
- `cargo clippy -p lean-fmt --all-targets -- -D warnings`
- `cargo test -p lean-fmt`
- `git diff --check`
