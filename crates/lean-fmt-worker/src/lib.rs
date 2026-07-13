//! Parent-side worker boundary for lean-fmt.
//!
//! Mirrors `lean-dup`'s `LeanDupCapabilityRuntime`/`PoolEngine` seam (prompt-02 audit):
//! it owns *how the `LeanFmt` capability is loaded and driven* — building a
//! `lean-rs-worker-parent` capability from the runtime crate's built dylib, spawning the
//! Lean-linked `lean-fmt-worker-child`, registering the `@[export]` commands, and running
//! JSON commands through a one-worker pool.
//!
//! This crate is deliberately **Lean-free**: `lean-rs-worker-parent` links no Lean itself,
//! it spawns the child binary. `libleanshared` is reached only through that child, never
//! linked into this library or the parent CLI. (The child binary lives in the separate
//! `lean-fmt-worker-child` crate, whose `build.rs` is the workspace's only Lean link step.)

pub mod toolchain;

use std::path::PathBuf;
use std::time::Duration;

use lean_fmt_runtime::exports;
use lean_rs_worker_parent::{
    LeanWorkerCapabilityBuilder, LeanWorkerChild, LeanWorkerError, LeanWorkerJsonCommand, LeanWorkerPool,
    LeanWorkerPoolConfig,
};
use lean_toolchain::LeanBuiltCapability;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::toolchain::InstalledWorker;

/// Default per-request timeout for a worker command. Loading and answering a static
/// identity command is fast; this leaves generous headroom for a cold capability load.
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Static `LeanFmt` capability identity, as returned by the `lean_fmt_metadata` export.
///
/// The field set mirrors `lean/LeanFmt/Capability.lean`'s `metadataJson` exactly; the
/// decode tests below guard the two envelopes against drift.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CapabilityMetadata {
    /// Capability name advertised to the host (`"lean-fmt"`).
    pub capability: String,
    /// Capability schema identifier (`"lean-fmt.capability.v1"`).
    pub schema: String,
    /// Package version, kept in sync with the Rust workspace version.
    pub version: String,
}

/// `LeanFmt` capability self-check result, as returned by the `lean_fmt_doctor` export.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CapabilityDoctor {
    /// Capability name advertised to the host.
    pub capability: String,
    /// Capability schema identifier.
    pub schema: String,
    /// Package version.
    pub version: String,
    /// Whether the capability is loaded and responding.
    pub ok: bool,
    /// Whether the capability's own metadata envelope parsed cleanly.
    pub metadata_valid: bool,
}

/// Worker boundary errors.
#[derive(Debug, thiserror::Error)]
pub enum WorkerError {
    /// Capability load, child spawn, or command request/response encode/decode failed.
    #[error("lean-fmt worker capability load/dispatch failed: {source}")]
    Parent {
        /// Underlying `lean-rs-worker-parent` error.
        #[from]
        source: LeanWorkerError,
    },
}

/// Loads the `LeanFmt` capability produced by the runtime crate and drives its
/// `@[export]` commands through the Lean-linked `lean-fmt-worker-child`.
///
/// Holds a one-worker pool; a warm child session is reused across dispatches. The built
/// capability, child binary path, and Lean sysroot are supplied explicitly (the runtime
/// crate builds the capability; per-toolchain *resolution* of the installed child is
/// prompt 08's job).
#[derive(Debug)]
pub struct FormatterWorker {
    pool: LeanWorkerPool,
    built: LeanBuiltCapability,
    child_binary: PathBuf,
    lean_sysroot: PathBuf,
    request_timeout: Duration,
}

impl FormatterWorker {
    /// Construct a worker over an already-built capability, the child binary, and the
    /// Lean sysroot the child loads `libleanshared` from.
    #[must_use]
    pub fn new(built: LeanBuiltCapability, child_binary: impl Into<PathBuf>, lean_sysroot: impl Into<PathBuf>) -> Self {
        Self {
            pool: LeanWorkerPool::new(LeanWorkerPoolConfig::new(1)),
            built,
            child_binary: child_binary.into(),
            lean_sysroot: lean_sysroot.into(),
            request_timeout: DEFAULT_REQUEST_TIMEOUT,
        }
    }

    /// Construct a worker from a resolved on-disk install (see
    /// [`toolchain::resolve_installed_worker`]). The capability is reloaded from the
    /// installed manifest; the installed child binary and its sysroot drive the spawn.
    #[must_use]
    pub fn from_installed(installed: &InstalledWorker) -> Self {
        Self::new(
            LeanBuiltCapability::manifest_path(installed.capability_manifest.clone()),
            installed.worker_child.clone(),
            installed.lean_sysroot.clone(),
        )
    }

    /// Override the per-request timeout.
    #[must_use]
    pub fn request_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = timeout;
        self
    }

    /// Build a capability builder with the child wired and both identity commands
    /// registered as JSON exports. Registering both keeps the warm session shared.
    fn builder(&self) -> Result<LeanWorkerCapabilityBuilder, WorkerError> {
        let builder = LeanWorkerCapabilityBuilder::from_built_capability(&self.built, Vec::<String>::new())?;
        Ok(builder
            .worker_child(LeanWorkerChild::for_toolchain(
                self.child_binary.clone(),
                self.lean_sysroot.clone(),
            ))
            .json_command_export(exports::METADATA_EXPORT)
            .json_command_export(exports::DOCTOR_EXPORT)
            .request_timeout(self.request_timeout))
    }

    /// Dispatch one JSON command through a freshly leased worker session.
    ///
    /// # Errors
    ///
    /// Returns [`WorkerError`] if the capability cannot be loaded, the child cannot be
    /// spawned, or the command request/response cannot be encoded/decoded (a malformed
    /// export or a shape mismatch surfaces as a typed error, never a panic across the ABI).
    pub fn dispatch_json<Req, Resp>(&mut self, export: &str, request: &Req) -> Result<Resp, WorkerError>
    where
        Req: Serialize,
        Resp: DeserializeOwned,
    {
        let builder = self.builder()?;
        let command = LeanWorkerJsonCommand::<Req, Resp>::new(export);
        let mut lease = self.pool.acquire_lease(builder)?;
        let response = lease.run_json_command(&command, request, None, None)?;
        Ok(response)
    }

    /// Load the capability and return its static identity (`lean_fmt_metadata`).
    ///
    /// # Errors
    ///
    /// Returns [`WorkerError`] if capability load, child spawn, or dispatch fails.
    pub fn metadata(&mut self) -> Result<CapabilityMetadata, WorkerError> {
        self.dispatch_json(exports::METADATA_EXPORT, &json!({}))
    }

    /// Run the capability self-check (`lean_fmt_doctor`).
    ///
    /// # Errors
    ///
    /// Returns [`WorkerError`] if capability load, child spawn, or dispatch fails.
    pub fn doctor(&mut self) -> Result<CapabilityDoctor, WorkerError> {
        self.dispatch_json(exports::DOCTOR_EXPORT, &json!({}))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::{CapabilityDoctor, CapabilityMetadata};

    // The exact compact envelopes emitted by `lean/LeanFmt/Capability.lean`. These
    // guard the parent DTOs against Lean-side drift without needing a live worker.
    const METADATA_JSON: &str = r#"{"capability":"lean-fmt","schema":"lean-fmt.capability.v1","version":"0.1.0"}"#;
    const DOCTOR_JSON: &str = r#"{"capability":"lean-fmt","schema":"lean-fmt.capability.v1","version":"0.1.0","ok":true,"metadata_valid":true}"#;

    #[test]
    fn metadata_decodes_lean_side_envelope() {
        let meta: CapabilityMetadata = serde_json::from_str(METADATA_JSON).unwrap();
        assert_eq!(meta.capability, "lean-fmt");
        assert_eq!(meta.schema, "lean-fmt.capability.v1");
        assert_eq!(meta.version, "0.1.0");
    }

    #[test]
    fn doctor_decodes_lean_side_envelope() {
        let doctor: CapabilityDoctor = serde_json::from_str(DOCTOR_JSON).unwrap();
        assert_eq!(doctor.capability, "lean-fmt");
        assert!(doctor.ok);
        assert!(doctor.metadata_valid);
    }
}
