//! `lean-fmt install-worker` — build and install the toolchain-specific worker.
//!
//! `cargo install lean-fmt` ships the parent Lean-free. The artifacts that link Lean —
//! the `lean-fmt-worker-child` binary and the `LeanFmt` capability dylib — are built here,
//! into `<install_root>/<toolchain-id>/`, and resolved at format time from the audited
//! project's `lean-toolchain` pin.
//!
//! This module orchestrates prompts 05–07: the capability comes from `lean-fmt-runtime`
//! ([`build_cached`], which owns the source digest, cache reuse, and the explicit-sysroot
//! Lake build); the worker-child comes from a prebuilt binary (`--worker-child`) or a
//! `cargo build -p lean-fmt-worker-child` with `LEAN_SYSROOT` pinned to the target
//! toolchain. After both land, a post-build smoke test spawns the *installed* worker and
//! runs `lean_fmt_metadata` through the real load path — a matching header digest does not
//! imply ABI compatibility, so this is the sound "can it actually load" signal — and the
//! outcome is recorded in the sidecar. This crate stays Lean-free: it launches the child
//! as a subprocess and never links `libleanshared`.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use lean_fmt_runtime::{FormatterRuntimeBuild, build_cached};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::{
    SmokeOutcome, ToolchainId, WORKER_FILE_NAME, WorkerSidecar, hash_lean_header, install_dir, resolve_in,
};

use crate::InstallWorkerArgs;

/// Build and install the worker for the requested toolchain, returning a process exit
/// code. Progress goes to stderr; the final install path goes to stdout.
pub(crate) fn run(args: &InstallWorkerArgs) -> ExitCode {
    match install(args) {
        Ok(dir) => {
            println!("{}", dir.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("lean-fmt: install-worker failed: {error}");
            ExitCode::FAILURE
        }
    }
}

pub(crate) fn install(args: &InstallWorkerArgs) -> Result<PathBuf, String> {
    let id = resolve_toolchain(args)?;
    let dest = args.install_dir.clone().unwrap_or_else(|| install_dir(&id));
    let sysroot = resolve_sysroot(args, &id)?;

    if !args.force && worker_is_current(&dest, &sysroot) {
        eprintln!(
            "==> worker for {id} is already installed and current at {} (use --force to rebuild)",
            dest.display()
        );
        return Ok(dest);
    }
    std::fs::create_dir_all(&dest).map_err(|error| format!("create install dir {}: {error}", dest.display()))?;

    // 1. Build (or reuse) the capability directly into the install dir, so the manifest
    //    the parent later loads points at the installed artifacts — no dylib to relocate.
    eprintln!("==> building LeanFmt capability for {id}");
    let runtime = build_cached(FormatterRuntimeBuild {
        cache_root: dest.clone(),
        toolchain_label: id.elan_label(),
        lean_sysroot: sysroot.clone(),
    })
    .map_err(|error| format!("build LeanFmt capability: {error}"))?;
    let manifest = runtime
        .built
        .resolved_manifest_path()
        .map_err(|error| format!("resolve capability manifest: {error}"))?;
    let dylib = runtime
        .built
        .dylib_path()
        .map_err(|error| format!("resolve capability dylib: {error}"))?;

    // 2. Place the Lean-linked worker-child binary beside it.
    let installed_child = dest.join(WORKER_FILE_NAME);
    place_worker_child(args, &id, &sysroot, &installed_child)?;

    // 3. Write the sidecar optimistically so the smoke test's resolution finds the fresh
    //    artifacts; the real smoke outcome is recorded below.
    let header_digest = hash_lean_header(&sysroot).map_err(|error| format!("hash toolchain lean.h: {error}"))?;
    let source_digest = runtime.provenance.runtime_source_digest.as_str();
    write_sidecar(
        &dest,
        &id,
        &header_digest,
        source_digest,
        &sysroot,
        &manifest,
        &dylib,
        SmokeOutcome::Passed,
    )?;

    // 4. Smoke test: load the capability and answer metadata through the *installed* worker.
    eprintln!("==> smoke test: load the capability and run lean_fmt_metadata for {id}");
    if let Err(detail) = smoke_test(&dest, &id) {
        write_sidecar(
            &dest,
            &id,
            &header_digest,
            source_digest,
            &sysroot,
            &manifest,
            &dylib,
            SmokeOutcome::Failed { detail: detail.clone() },
        )?;
        return Err(format!(
            "worker for {id} built but FAILED its smoke test ({detail}); this toolchain's libleanshared is \
             likely ABI-incompatible with lean-fmt's lean-rs build. The worker is recorded as unusable and will \
             not be served"
        ));
    }

    eprintln!("==> installed worker for {id} at {}", dest.display());
    Ok(dest)
}

/// The toolchain to build for: `--toolchain` wins, else the current directory's
/// `lean-toolchain`, else the pinned default.
fn resolve_toolchain(args: &InstallWorkerArgs) -> Result<ToolchainId, String> {
    if let Some(raw) = &args.toolchain {
        return ToolchainId::parse(raw).map_err(|error| error.to_string());
    }
    let cwd = std::env::current_dir().map_err(|error| format!("read current directory: {error}"))?;
    Ok(ToolchainId::from_lake_root(&cwd).unwrap_or_else(|_| ToolchainId::pinned()))
}

/// The Lean sysroot to build and link against: `--sysroot` wins, else the elan dir for
/// the toolchain (surfacing the actionable `elan toolchain install` hint if absent).
fn resolve_sysroot(args: &InstallWorkerArgs, id: &ToolchainId) -> Result<PathBuf, String> {
    match &args.sysroot {
        Some(sysroot) => Ok(sysroot.clone()),
        None => id.elan_dir().map_err(|error| error.to_string()),
    }
}

/// Whether `dest` already holds a usable, header-fresh, smoke-passing worker — mirrors
/// the parent's resolution so a skipped rebuild is one the parent would accept.
fn worker_is_current(dest: &Path, sysroot: &Path) -> bool {
    let Some(sidecar) = WorkerSidecar::load(dest) else {
        return false;
    };
    if !dest.join(WORKER_FILE_NAME).is_file() || !matches!(sidecar.smoke(), Some(SmokeOutcome::Passed)) {
        return false;
    }
    let Ok(current) = hash_lean_header(sysroot) else {
        return false;
    };
    sidecar.header_matches(&current)
}

/// Install the worker-child binary at `dest_bin`: copy a `--worker-child` prebuilt, else
/// `cargo build -p lean-fmt-worker-child --release` from a checkout with `LEAN_SYSROOT`
/// pinned to the target toolchain, then copy the built binary.
fn place_worker_child(
    args: &InstallWorkerArgs,
    id: &ToolchainId,
    sysroot: &Path,
    dest_bin: &Path,
) -> Result<(), String> {
    if let Some(prebuilt) = &args.worker_child {
        eprintln!(
            "==> installing {WORKER_FILE_NAME} for {id} (prebuilt {})",
            prebuilt.display()
        );
        return copy_into_place(prebuilt, dest_bin);
    }
    let workspace = workspace_source(args).ok_or_else(|| {
        format!(
            "cannot locate a lean-fmt checkout to build {WORKER_FILE_NAME}; pass --worker-child <path> to a \
             prebuilt binary or --source-dir <dir> to a checkout"
        )
    })?;
    eprintln!("==> building {WORKER_FILE_NAME} for {id} (workspace source)");
    let status = Command::new("cargo")
        .args(["build", "--release", "-p", WORKER_FILE_NAME, "--locked"])
        .current_dir(&workspace)
        .env("LEAN_SYSROOT", sysroot)
        .status()
        .map_err(|error| format!("spawn cargo build: {error}"))?;
    if !status.success() {
        return Err(format!(
            "cargo build -p {WORKER_FILE_NAME} (toolchain {id}) failed with status {status}"
        ));
    }
    let built = workspace.join("target").join("release").join(WORKER_FILE_NAME);
    if !built.is_file() {
        return Err(format!("expected worker binary at {} but found none", built.display()));
    }
    copy_into_place(&built, dest_bin)
}

/// The checkout to build the worker-child from: `--source-dir` if given, else this
/// binary's own workspace when it was built from a checkout (the worker-child crate sits
/// beside it), else `None`.
fn workspace_source(args: &InstallWorkerArgs) -> Option<PathBuf> {
    if let Some(dir) = &args.source_dir {
        return Some(dir.clone());
    }
    // `CARGO_MANIFEST_DIR` is `<repo>/crates/lean-fmt-cli` for a checkout build; for a
    // registry-installed binary it points into the registry with no worker-child crate
    // beside it. Probe for that crate specifically.
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)?;
    repo.join("crates")
        .join("lean-fmt-worker-child")
        .join("Cargo.toml")
        .is_file()
        .then_some(repo)
}

/// Copy `from` to `to`, replacing any existing file and preserving the executable bit.
fn copy_into_place(from: &Path, to: &Path) -> Result<(), String> {
    if to.exists() {
        std::fs::remove_file(to).map_err(|error| format!("remove stale {}: {error}", to.display()))?;
    }
    std::fs::copy(from, to).map_err(|error| format!("copy {} -> {}: {error}", from.display(), to.display()))?;
    Ok(())
}

/// Load the capability and answer `lean_fmt_metadata` through the freshly installed
/// worker — the sound proof the installed artifacts actually load and respond.
fn smoke_test(dest: &Path, id: &ToolchainId) -> Result<(), String> {
    let installed = resolve_in(dest, id).map_err(|error| error.to_string())?;
    let mut worker = FormatterWorker::from_installed(&installed);
    let metadata = worker.metadata().map_err(|error| error.to_string())?;
    if metadata.capability == "lean-fmt" {
        Ok(())
    } else {
        Err(format!("unexpected capability identity {:?}", metadata.capability))
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "sidecar carries the full build-time provenance record"
)]
fn write_sidecar(
    dest: &Path,
    id: &ToolchainId,
    header_digest: &str,
    source_digest: &str,
    sysroot: &Path,
    manifest: &Path,
    dylib: &Path,
    smoke: SmokeOutcome,
) -> Result<(), String> {
    WorkerSidecar::new(
        id,
        header_digest.to_owned(),
        source_digest.to_owned(),
        sysroot,
        manifest,
        dylib,
        smoke,
    )
    .write(dest)
    .map_err(|error| format!("write worker sidecar: {error}"))
}
