//! Per-toolchain install-path resolution and provenance for the `LeanFmt` worker.
//!
//! Mirrors `lean-dup`'s `worker::toolchain` seam (prompt-02 audit). `cargo install lean-fmt`
//! ships the parent Lean-free; the Lean-linking artifacts — the `lean-fmt-worker-child`
//! binary and the `LeanFmt` capability dylib — are built by `lean-fmt install-worker` into
//! `<install_root>/<toolchain-id>/`, and resolved at format time from the audited project's
//! `lean-toolchain` pin. Both the writer (`install-worker`) and the reader
//! ([`resolve_installed_worker`]) go through [`install_dir`], so they never disagree on
//! where a toolchain's artifacts live.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Default toolchain pin used as the resolution fallback.
pub const PINNED_TOOLCHAIN: &str = "leanprover/lean4:v4.32.0-rc1";
/// File name of the installed Lean-linked worker-child binary.
pub const WORKER_FILE_NAME: &str = "lean-fmt-worker-child";
/// Environment override pointing directly at a single-toolchain install dir.
pub const WORKERS_DIR_ENV: &str = "LEAN_FMT_WORKERS_DIR";
/// Provenance sidecar file name written beside an installed worker.
const SIDECAR_FILE_NAME: &str = "worker.json";

/// Canonical short form of a Lean toolchain pin (e.g. `v4.32.0-rc1`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolchainId(String);

impl ToolchainId {
    /// Parse a `lean-toolchain` line: either the elan-style `leanprover/lean4:<id>`
    /// or the bare `<id>` short form.
    ///
    /// # Errors
    ///
    /// [`ToolchainError::Unparseable`] if empty, whitespace-bearing, or naming a Lean
    /// fork we do not understand.
    pub fn parse(raw: &str) -> Result<Self, ToolchainError> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err(ToolchainError::Unparseable(raw.to_owned()));
        }
        let short = if let Some(rest) = trimmed.strip_prefix("leanprover/lean4:") {
            rest
        } else if trimmed.contains(':') || trimmed.contains('/') {
            return Err(ToolchainError::Unparseable(raw.to_owned()));
        } else {
            trimmed
        };
        if short.is_empty() || short.chars().any(char::is_whitespace) {
            return Err(ToolchainError::Unparseable(raw.to_owned()));
        }
        Ok(Self(short.to_owned()))
    }

    /// Read `<root>/lean-toolchain` and parse it.
    ///
    /// # Errors
    ///
    /// [`ToolchainError::FileMissing`] if absent/unreadable; forwards [`Self::parse`].
    pub fn from_lake_root(root: &Path) -> Result<Self, ToolchainError> {
        let path = root.join("lean-toolchain");
        let contents = std::fs::read_to_string(&path).map_err(|_| ToolchainError::FileMissing(path.clone()))?;
        Self::parse(&contents)
    }

    /// The development pin used as the resolution fallback. The const is under our
    /// control, so the fallback in `unwrap_or_else` is never reached in practice.
    #[must_use]
    pub fn pinned() -> Self {
        Self::parse(PINNED_TOOLCHAIN).unwrap_or_else(|_| Self("v4.32.0-rc1".to_owned()))
    }

    /// Resolved path to the elan toolchain root
    /// (`~/.elan/toolchains/leanprover--lean4---<id>`).
    ///
    /// # Errors
    ///
    /// [`ToolchainError::ElanMissing`] if the directory is absent.
    pub fn elan_dir(&self) -> Result<PathBuf, ToolchainError> {
        let dir = self.elan_dir_path()?;
        if dir.is_dir() {
            Ok(dir)
        } else {
            Err(ToolchainError::ElanMissing {
                toolchain: self.clone(),
                elan_dir: dir,
            })
        }
    }

    fn elan_dir_path(&self) -> Result<PathBuf, ToolchainError> {
        let home = dirs::home_dir().ok_or_else(|| ToolchainError::ElanMissing {
            toolchain: self.clone(),
            elan_dir: PathBuf::from(format!("~/.elan/toolchains/leanprover--lean4---{}", self.0)),
        })?;
        Ok(home
            .join(".elan")
            .join("toolchains")
            .join(format!("leanprover--lean4---{}", self.0)))
    }

    /// The elan-style label (`leanprover/lean4:<id>`) Lake and the toolchain
    /// materializers expect.
    #[must_use]
    pub fn elan_label(&self) -> String {
        format!("leanprover/lean4:{}", self.0)
    }

    /// The bare short id (e.g. `v4.32.0-rc1`).
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ToolchainId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// `<data_local>/lean-fmt/workers` — the per-toolchain install root.
///
/// Falls back to the current directory if no data dir can be located; callers then
/// fail soon after with a concrete [`ProvisionError::NotInstalled`].
#[must_use]
pub fn install_root() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("lean-fmt")
        .join("workers")
}

/// Install directory for one toolchain, honoring [`WORKERS_DIR_ENV`].
///
/// The override points directly at a single-toolchain install dir (used by dev/CI to
/// redirect provisioning out of the user data dir); otherwise the per-toolchain subdir
/// under [`install_root`] is used.
#[must_use]
pub fn install_dir(id: &ToolchainId) -> PathBuf {
    std::env::var_os(WORKERS_DIR_ENV).map_or_else(|| install_root().join(id.as_str()), PathBuf::from)
}

/// `lean-fmt install-worker --toolchain <id>` — the command that produces a missing
/// or stale worker for `id`.
fn install_cmd(id: &ToolchainId) -> String {
    format!("lean-fmt install-worker --toolchain {}", id.as_str())
}

/// The resolved, ready-to-spawn worker artifacts for one toolchain.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledWorker {
    /// The `lean-fmt-worker-child` binary that links `libleanshared`.
    pub worker_child: PathBuf,
    /// The `LeanFmt` capability artifact manifest the parent loads.
    pub capability_manifest: PathBuf,
    /// The Lean sysroot the child is spawned with (`LEAN_SYSROOT`).
    pub lean_sysroot: PathBuf,
}

/// Resolve the installed worker for the toolchain `workspace_root` pins.
///
/// Reads `<workspace_root>/lean-toolchain` (falling back to [`PINNED_TOOLCHAIN`] when
/// absent), then resolves `<install_root>/<id>/` — or the [`WORKERS_DIR_ENV`] override.
///
/// # Errors
///
/// [`ProvisionError`] when no usable worker is installed for the pin.
pub fn resolve_installed_worker(workspace_root: &Path) -> Result<InstalledWorker, ProvisionError> {
    let id = ToolchainId::from_lake_root(workspace_root).unwrap_or_else(|_| ToolchainId::pinned());
    resolve_in(&install_dir(&id), &id)
}

/// Resolution core over a concrete install dir, factored out so tests drive the
/// not-installed / stale / unusable / ok verdicts without mutating global state.
///
/// # Errors
///
/// [`ProvisionError`] when the install is missing, header-stale, or recorded unusable.
pub fn resolve_in(install_dir: &Path, id: &ToolchainId) -> Result<InstalledWorker, ProvisionError> {
    let worker_child = install_dir.join(WORKER_FILE_NAME);
    let Some(sidecar) = WorkerSidecar::load(install_dir) else {
        return Err(ProvisionError::NotInstalled {
            toolchain: id.clone(),
            install_cmd: install_cmd(id),
        });
    };
    if !worker_child.is_file() {
        return Err(ProvisionError::NotInstalled {
            toolchain: id.clone(),
            install_cmd: install_cmd(id),
        });
    }
    let lean_sysroot = PathBuf::from(&sidecar.lean_sysroot);
    // Header drift trumps everything: if the toolchain's lean.h moved under the worker,
    // a rebuild is the right move. When the header can't be read (the elan toolchain was
    // removed), skip the check — the child spawn surfaces the real failure itself.
    if let Ok(current) = hash_lean_header(&lean_sysroot)
        && !sidecar.header_matches(&current)
    {
        return Err(ProvisionError::Stale {
            toolchain: id.clone(),
            install_cmd: install_cmd(id),
        });
    }
    if let Some(SmokeOutcome::Failed { detail }) = sidecar.smoke() {
        return Err(ProvisionError::Unusable {
            toolchain: id.clone(),
            detail: detail.clone(),
            install_cmd: install_cmd(id),
        });
    }
    Ok(InstalledWorker {
        worker_child,
        capability_manifest: PathBuf::from(&sidecar.capability_manifest),
        lean_sysroot,
    })
}

/// Full SHA-256 (lowercase hex) of `<lean_sysroot>/include/lean/lean.h` — the robust
/// toolchain-identity check (a version string can lie; the header digest cannot).
///
/// # Errors
///
/// Forwards the read error if the header is absent or unreadable.
pub fn hash_lean_header(lean_sysroot: &Path) -> io::Result<String> {
    use sha2::{Digest, Sha256};
    let path = lean_sysroot.join("include").join("lean").join("lean.h");
    let bytes = std::fs::read(path)?;
    let digest = Sha256::digest(&bytes);
    use std::fmt::Write as _;
    let mut hex = String::with_capacity(digest.len().saturating_mul(2));
    for byte in &digest {
        let _ = write!(hex, "{byte:02x}");
    }
    Ok(hex)
}

/// Outcome of `install-worker`'s post-build runtime smoke test, recorded in the sidecar.
///
/// A header-digest match does not imply ABI compatibility — the toolchain's
/// `libleanshared` can still crash the worker — so the recorded run result is the sound
/// "can it actually load and answer" signal.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum SmokeOutcome {
    /// The built worker loaded the capability and answered `lean_fmt_metadata`.
    Passed,
    /// The worker built but failed at load/answer. `detail` is the failure.
    Failed {
        /// Human-readable failure detail.
        detail: String,
    },
}

/// Provenance record written beside an installed worker and read back at resolution time.
///
/// Records what the worker was built against (for drift detection) and where its artifacts
/// landed (absolute paths, so resolution does not recompute the build layout).
#[derive(Serialize, Deserialize, Debug, Clone, Eq, PartialEq)]
pub struct WorkerSidecar {
    toolchain: String,
    /// SHA-256 of the `lean.h` the worker was built against.
    header_digest: String,
    /// Runtime source digest the capability was built from (from `lean-fmt-runtime`).
    #[serde(default)]
    runtime_source_digest: String,
    /// `lean-fmt` version (`CARGO_PKG_VERSION`) that built this worker.
    #[serde(default)]
    built_by_host_version: String,
    /// Absolute Lean sysroot the worker-child is spawned with.
    lean_sysroot: String,
    /// Absolute path to the `LeanFmt` capability artifact manifest the parent loads.
    capability_manifest: String,
    /// Absolute path to the built `LeanFmt` capability dylib (diagnostics; the manifest
    /// already points at it).
    capability_dylib: String,
    /// Post-build runtime smoke outcome. `None` for a sidecar predating it.
    #[serde(default)]
    smoke: Option<SmokeOutcome>,
}

impl WorkerSidecar {
    /// Build a sidecar stamped with this host's build-time context.
    #[must_use]
    pub fn new(
        id: &ToolchainId,
        header_digest: String,
        runtime_source_digest: String,
        lean_sysroot: &Path,
        capability_manifest: &Path,
        capability_dylib: &Path,
        smoke: SmokeOutcome,
    ) -> Self {
        Self {
            toolchain: id.as_str().to_owned(),
            header_digest,
            runtime_source_digest,
            built_by_host_version: env!("CARGO_PKG_VERSION").to_owned(),
            lean_sysroot: lean_sysroot.display().to_string(),
            capability_manifest: capability_manifest.display().to_string(),
            capability_dylib: capability_dylib.display().to_string(),
            smoke: Some(smoke),
        }
    }

    /// Write `<install_dir>/worker.json`, overwriting any existing record.
    ///
    /// # Errors
    ///
    /// Forwards serialization or write failures.
    pub fn write(&self, install_dir: &Path) -> io::Result<()> {
        let json = serde_json::to_string_pretty(self).map_err(io::Error::other)?;
        std::fs::write(install_dir.join(SIDECAR_FILE_NAME), json)
    }

    /// Load `<install_dir>/worker.json`. `None` when absent or unparseable — unknown
    /// provenance, not an error (a corrupt sidecar reads as "not installed").
    #[must_use]
    pub fn load(install_dir: &Path) -> Option<Self> {
        let bytes = std::fs::read(install_dir.join(SIDECAR_FILE_NAME)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Whether the recorded build-time digest still matches the toolchain.
    #[must_use]
    pub fn header_matches(&self, current_digest: &str) -> bool {
        self.header_digest == current_digest
    }

    /// The recorded post-build smoke outcome, if any.
    #[must_use]
    pub fn smoke(&self) -> Option<&SmokeOutcome> {
        self.smoke.as_ref()
    }

    /// The recorded runtime source digest, or `""` if the sidecar predates the field.
    #[must_use]
    pub fn runtime_source_digest(&self) -> &str {
        &self.runtime_source_digest
    }
}

/// Errors resolving or interpreting a Lean toolchain pin.
#[derive(Debug)]
pub enum ToolchainError {
    /// The `lean-toolchain` string could not be parsed.
    Unparseable(String),
    /// No `lean-toolchain` file was found at the expected path.
    FileMissing(PathBuf),
    /// The elan toolchain directory is absent.
    ElanMissing {
        /// The toolchain that was requested.
        toolchain: ToolchainId,
        /// The elan directory that was expected but not found.
        elan_dir: PathBuf,
    },
}

impl fmt::Display for ToolchainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unparseable(raw) => write!(f, "could not parse lean-toolchain string: {raw:?}"),
            Self::FileMissing(path) => write!(f, "lean-toolchain file not found at {}", path.display()),
            Self::ElanMissing { toolchain, elan_dir } => write!(
                f,
                "elan toolchain {toolchain} is not installed (expected {}); install it with: \
                 elan toolchain install {}",
                elan_dir.display(),
                toolchain.elan_label()
            ),
        }
    }
}

impl std::error::Error for ToolchainError {}

/// Why a usable worker could not be resolved. Every variant's [`Display`] names the
/// `install-worker` command that fixes it.
#[derive(Debug)]
pub enum ProvisionError {
    /// No worker is installed for this toolchain.
    NotInstalled {
        /// The toolchain with no usable install.
        toolchain: ToolchainId,
        /// The `install-worker` command that provisions it.
        install_cmd: String,
    },
    /// The toolchain's `lean.h` changed since the worker was built: rebuild it.
    Stale {
        /// The stale toolchain.
        toolchain: ToolchainId,
        /// The `install-worker` command that rebuilds it.
        install_cmd: String,
    },
    /// The worker built but failed its post-build smoke test — the toolchain's
    /// `libleanshared` is ABI-incompatible and the worker fails on load.
    Unusable {
        /// The unusable toolchain.
        toolchain: ToolchainId,
        /// The recorded smoke-failure detail.
        detail: String,
        /// The `install-worker` command that rebuilds it.
        install_cmd: String,
    },
}

impl fmt::Display for ProvisionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotInstalled { toolchain, install_cmd } => write!(
                f,
                "no lean-fmt worker is installed for toolchain {toolchain}; run: {install_cmd}"
            ),
            Self::Stale { toolchain, install_cmd } => write!(
                f,
                "the lean-fmt worker for toolchain {toolchain} is stale (its lean.h changed since it was built); \
                 rebuild it: {install_cmd}"
            ),
            Self::Unusable {
                toolchain,
                detail,
                install_cmd,
            } => write!(
                f,
                "the lean-fmt worker for toolchain {toolchain} is unusable ({detail}); rebuild it: {install_cmd}"
            ),
        }
    }
}

impl std::error::Error for ProvisionError {}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use std::path::Path;

    use tempfile::TempDir;

    use super::{ProvisionError, SmokeOutcome, ToolchainId, WorkerSidecar, resolve_in};

    fn write_child(dir: &Path) {
        std::fs::write(dir.join(super::WORKER_FILE_NAME), b"#!/bin/sh\n").unwrap();
    }

    fn sidecar(header: &str, smoke: SmokeOutcome) -> WorkerSidecar {
        WorkerSidecar::new(
            &ToolchainId::pinned(),
            header.to_owned(),
            "digest".to_owned(),
            Path::new("/no/such/sysroot"),
            Path::new("/install/manifest.json"),
            Path::new("/install/lib.dylib"),
            smoke,
        )
    }

    #[test]
    fn toolchain_parse_accepts_both_forms() {
        assert_eq!(
            ToolchainId::parse("leanprover/lean4:v4.32.0-rc1").unwrap().as_str(),
            "v4.32.0-rc1"
        );
        assert_eq!(ToolchainId::parse("  v4.32.0-rc1\n").unwrap().as_str(), "v4.32.0-rc1");
        assert!(ToolchainId::parse("").is_err());
        assert!(ToolchainId::parse("nightly/lean4:x").is_err());
    }

    #[test]
    fn resolve_missing_sidecar_is_not_installed() {
        let dir = TempDir::new().unwrap();
        let err = resolve_in(dir.path(), &ToolchainId::pinned()).unwrap_err();
        assert!(matches!(err, ProvisionError::NotInstalled { .. }));
    }

    #[test]
    fn resolve_missing_binary_is_not_installed() {
        let dir = TempDir::new().unwrap();
        // Sysroot unreadable, so the header check is skipped; only the missing binary bites.
        sidecar("deadbeef", SmokeOutcome::Passed).write(dir.path()).unwrap();
        let err = resolve_in(dir.path(), &ToolchainId::pinned()).unwrap_err();
        assert!(matches!(err, ProvisionError::NotInstalled { .. }));
    }

    #[test]
    fn resolve_failed_smoke_is_unusable() {
        let dir = TempDir::new().unwrap();
        write_child(dir.path());
        sidecar(
            "deadbeef",
            SmokeOutcome::Failed {
                detail: "sigsegv".to_owned(),
            },
        )
        .write(dir.path())
        .unwrap();
        let err = resolve_in(dir.path(), &ToolchainId::pinned()).unwrap_err();
        assert!(matches!(err, ProvisionError::Unusable { .. }));
    }

    #[test]
    fn resolve_ok_when_present_passed_and_header_unchecked() {
        let dir = TempDir::new().unwrap();
        write_child(dir.path());
        sidecar("deadbeef", SmokeOutcome::Passed).write(dir.path()).unwrap();
        let resolved = resolve_in(dir.path(), &ToolchainId::pinned()).unwrap();
        assert_eq!(resolved.worker_child, dir.path().join(super::WORKER_FILE_NAME));
        assert_eq!(resolved.capability_manifest, Path::new("/install/manifest.json"));
    }

    #[test]
    fn corrupt_sidecar_reads_as_not_installed() {
        let dir = TempDir::new().unwrap();
        write_child(dir.path());
        std::fs::write(dir.path().join("worker.json"), b"{ not json").unwrap();
        assert!(WorkerSidecar::load(dir.path()).is_none());
        let err = resolve_in(dir.path(), &ToolchainId::pinned()).unwrap_err();
        assert!(matches!(err, ProvisionError::NotInstalled { .. }));
    }
}
