//! End-to-end worker round-trip: build the `LeanFmt` capability with the runtime crate,
//! spawn the freshly built `lean-fmt-worker-child`, and answer identity commands through
//! the real `from_built_capability` load path.
//!
//! This test lives in the child crate because `CARGO_BIN_EXE_lean-fmt-worker-child`
//! (the just-built child binary) is only exposed to this package's own tests. It needs a
//! real Lean sysroot, so it is `#[ignore]`d by default. Run it with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test metadata_round_trip -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;

use lean_fmt_runtime::{FormatterRuntimeBuild, build_cached};
use lean_fmt_worker::FormatterWorker;

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn metadata_round_trip_through_real_child() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let child = PathBuf::from(env!("CARGO_BIN_EXE_lean-fmt-worker-child"));
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;

    // Build (or reuse) the capability dylib through the runtime crate.
    let runtime = build_cached(FormatterRuntimeBuild {
        cache_root: temp.path().to_path_buf(),
        toolchain_label: toolchain,
        lean_sysroot: sysroot.clone(),
    })
    .map_err(|error| error.to_string())?;

    let mut worker = FormatterWorker::new(runtime.built, &child, &sysroot);

    // Load + metadata round-trip through the real spawned child.
    let metadata = worker.metadata().map_err(|error| error.to_string())?;
    assert_eq!(metadata.capability, "lean-fmt");
    assert_eq!(metadata.schema, "lean-fmt.capability.v1");
    assert_eq!(metadata.version, "0.1.0");

    // The self-check confirms the shared library actually loaded and answered.
    let doctor = worker.doctor().map_err(|error| error.to_string())?;
    assert!(doctor.ok, "doctor reported the capability not ok");
    assert!(doctor.metadata_valid, "doctor reported invalid metadata envelope");

    // A malformed command must surface as a typed error, not a panic across the ABI.
    let bad: Result<serde_json::Value, _> = worker.dispatch_json("lean_fmt_does_not_exist", &serde_json::json!({}));
    assert!(bad.is_err(), "unknown export must yield a typed error, not success");

    Ok(())
}
