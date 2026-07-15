---
claim_id: ECV2-NATIVE-RESET
status: verified
depends_on: [ECV2-RESET]
---

# Replace the implementation with a native Lean foundation

## Task

Delete the Rust workspace, worker child, capability package, legacy fixtures, Rust CI, scripts, and
stale architecture documentation. Run `lake +v4.32.0 init lean-fmt exe` at the repository root and
retain only an idiomatic `LeanFmt` library plus the `lean-fmt` executable.

## Target

- `lakefile.toml`, `lean-toolchain`, `LeanFmt.lean`, `LeanFmt/Basic.lean`, and `Main.lean`.
- Package and executable name `lean-fmt`; Lean namespace `LeanFmt`.
- No Cargo manifest, `crates/`, worker protocol, or legacy production Lean module.

## Check

- `LEAN_NUM_THREADS=1 lake build`
- `lake exe lean-fmt`
- Inspect `git status` and the active dependency graph.
- `git diff --check`
