//! Explicit-sysroot build test for the packaged `LeanFmt` runtime.
//!
//! Requires a real Lean sysroot, so it is `#[ignore]`d by default. Run it with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-runtime --test build_cached -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;

use lean_fmt_runtime::{FormatterRuntimeBuild, build_cached};

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn build_cached_against_explicit_sysroot() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;

    let cold_start = std::time::Instant::now();
    let cold = build_cached(FormatterRuntimeBuild {
        cache_root: temp.path().to_path_buf(),
        toolchain_label: toolchain.clone(),
        lean_sysroot: sysroot.clone(),
    })
    .map_err(|error| error.to_string())?;
    let cold_elapsed = cold_start.elapsed();

    let warm_start = std::time::Instant::now();
    let warm = build_cached(FormatterRuntimeBuild {
        cache_root: temp.path().to_path_buf(),
        toolchain_label: toolchain.clone(),
        lean_sysroot: sysroot,
    })
    .map_err(|error| error.to_string())?;
    let warm_elapsed = warm_start.elapsed();

    // The warm build reuses the materialized package and the built artifact.
    assert_eq!(cold.provenance, warm.provenance);
    assert_eq!(cold.built.package_name(), Some("lean_fmt"));
    assert_eq!(warm.built.module_name(), Some("LeanFmt"));
    assert_eq!(
        cold.built.dylib_path().map_err(|error| error.to_string())?,
        warm.built.dylib_path().map_err(|error| error.to_string())?,
    );
    println!(
        "lean_fmt_runtime_build toolchain={toolchain} cold_ms={} warm_ms={}",
        cold_elapsed.as_millis(),
        warm_elapsed.as_millis()
    );
    Ok(())
}
