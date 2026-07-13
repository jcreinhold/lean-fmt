//! End-to-end `install-worker` round-trip: install the capability + worker child into a
//! staging dir, then load and answer `lean_fmt_metadata` through the *installed* worker.
//!
//! This lives in the child crate because `CARGO_BIN_EXE_lean-fmt-worker-child` (the freshly
//! built Lean-linked child) is only exposed to this package's own tests. The install is
//! driven programmatically through `lean_fmt_cli::install_worker_command` (the same code the
//! `install-worker` subcommand runs), pointing `--worker-child` at that binary so the test
//! does not re-invoke cargo. It needs a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test install_worker -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::{ToolchainId, WORKER_FILE_NAME, WorkerSidecar, resolve_in};

fn args(install_dir: &std::path::Path, sysroot: &std::path::Path, toolchain: &str, force: bool) -> InstallWorkerArgs {
    InstallWorkerArgs {
        toolchain: Some(toolchain.to_owned()),
        sysroot: Some(sysroot.to_path_buf()),
        install_dir: Some(install_dir.to_path_buf()),
        worker_child: Some(PathBuf::from(env!("CARGO_BIN_EXE_lean-fmt-worker-child"))),
        source_dir: None,
        force,
    }
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn install_worker_round_trip_through_installed_worker() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let id = ToolchainId::parse(&toolchain).map_err(|error| error.to_string())?;
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;
    let dest = temp.path().join("workers");

    // Cold install: build capability + place child + write sidecar + smoke test.
    let out = install_worker_command(&args(&dest, &sysroot, &toolchain, false))?;
    assert_eq!(out, dest, "install returns the staging dir");
    assert!(dest.join(WORKER_FILE_NAME).is_file(), "worker child was installed");
    assert!(dest.join("worker.json").is_file(), "provenance sidecar was written");

    // Explicit round-trip against the *installed* worker (not an in-tree build).
    let installed = resolve_in(&dest, &id).map_err(|error| error.to_string())?;
    let mut worker = FormatterWorker::from_installed(&installed);
    let metadata = worker.metadata().map_err(|error| error.to_string())?;
    assert_eq!(metadata.capability, "lean-fmt");
    assert_eq!(metadata.schema, "lean-fmt.capability.v1");
    assert_eq!(metadata.version, "0.1.0");

    let digest_after_cold = WorkerSidecar::load(&dest)
        .ok_or_else(|| "sidecar missing after cold install".to_owned())?
        .runtime_source_digest()
        .to_owned();

    // Warm re-install: unchanged source is current, so it short-circuits (no rebuild) and
    // leaves the same provenance in place.
    let warm = install_worker_command(&args(&dest, &sysroot, &toolchain, false))?;
    assert_eq!(warm, dest);
    let digest_after_warm = WorkerSidecar::load(&dest)
        .ok_or_else(|| "sidecar missing after warm install".to_owned())?
        .runtime_source_digest()
        .to_owned();
    assert_eq!(
        digest_after_cold, digest_after_warm,
        "warm install keeps the same provenance"
    );

    // Corrupt sidecar forces a clean rebuild that restores a valid, smoke-passing install.
    std::fs::write(dest.join("worker.json"), b"{ not json").map_err(|error| error.to_string())?;
    assert!(WorkerSidecar::load(&dest).is_none(), "corrupt sidecar reads as absent");
    let rebuilt = install_worker_command(&args(&dest, &sysroot, &toolchain, false))?;
    assert_eq!(rebuilt, dest);
    let recovered = resolve_in(&dest, &id).map_err(|error| error.to_string())?;
    let mut worker2 = FormatterWorker::from_installed(&recovered);
    assert_eq!(
        worker2.metadata().map_err(|error| error.to_string())?.capability,
        "lean-fmt"
    );

    Ok(())
}
