//! Package-owned Lean runtime for the `LeanFmt` capability.
//!
//! Mirrors the `lean-semantic-search-runtime` pattern (prompt-02 audit): owns the runtime
//! payload, source digest, cache materialization, provenance, and explicit-sysroot Lake build.
//! Downstream hosts depend on this crate rather than vendoring Lean source. The parent stays
//! Lean-free; a later `install-worker` step builds the per-toolchain capability dylib.
