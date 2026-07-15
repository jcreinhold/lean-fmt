# ECV2-NATIVE-RESET result

On 2026-07-15 the remaining Rust workspace, worker child, capability package, legacy corpus, Rust
scripts/configuration, boundary hooks, and stale product documentation were deleted from the active
tree. The archive branch remains unchanged.

The repository root was initialized with:

```sh
lake +v4.32.0 init lean-fmt exe
```

The generated package was normalized only so Lean library modules use `LeanFmt` while the package and
executable remain exactly `lean-fmt`. `LEAN_NUM_THREADS=1 lake build` succeeds and `lake exe lean-fmt`
prints the native foundation message. No Cargo manifest, `crates/` directory, worker protocol, or
legacy production Lean source remains.
