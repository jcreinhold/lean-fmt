//! Package-owned Lean runtime for the `LeanFmt` capability.
//!
//! Mirrors the `lean-semantic-search-runtime` pattern (prompt-02 audit): it owns the
//! runtime source digest, cache materialization, provenance sidecar, and the
//! explicit-sysroot Lake build that produces the loadable capability. It does not link
//! Lean in-process and does not run a worker; callers (the worker child) load the
//! returned [`LeanBuiltCapability`] with their own `lean-rs-worker-parent` configuration.
//!
//! Unlike a published library, `lean-fmt` is an application with no downstream hosts to
//! vendor for, so [`RUNTIME_SOURCE_ROOT`] points at the repository's own `lean/` package
//! and the digest is computed from it at materialization time. There is no vendored copy
//! to drift and no hand-baked digest constant to keep in sync.

use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

use lean_rs_worker_protocol::worker_exports::{doctor_signature, metadata_signature};
use lean_toolchain::{
    CargoLeanCapability, GeneratedSourceFile, LeanBuiltCapability, LeanBuiltCapabilityError, LeanExportSignature,
    LinkDiagnostics, SourcePackageError, SourcePackageManifestPolicy, SourcePackageMaterializationRequest,
    materialize_source_package as materialize_with_toolchain,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

/// The in-repo Lean package directory used as the runtime source.
const RUNTIME_SOURCE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../lean");
/// Provenance sidecar file name written beside each materialized package.
const SIDECAR_FILE_NAME: &str = "lean-fmt-runtime.json";
/// Provenance/cache sidecar schema version.
const CACHE_SCHEMA_VERSION: u32 = 1;

/// Marker for the in-repo runtime source revision (provenance only).
pub const SOURCE_REVISION: &str = "lean-fmt-lean@0.1.0";
/// Lake package name owned by the runtime payload (as written in `lean/lakefile.lean`).
pub const PACKAGE_NAME: &str = "lean-fmt";
/// Cache-private Lake package identifier. Underscored so Lake output-path resolution
/// finds the build artifacts (guillemet names do not resolve cleanly).
const MATERIALIZED_PACKAGE_NAME: &str = "lean_fmt";
/// Lean library and root module name owned by the runtime payload.
pub const LIBRARY_NAME: &str = "LeanFmt";

/// Names of the Lean `@[export]` capability commands.
///
/// Shared with the worker child, which registers each export by these exact symbols;
/// they must match the `@[export ...]` names in `lean/LeanFmt/Capability.lean`.
pub mod exports {
    /// `@[export lean_fmt_metadata]` — capability identity command.
    pub const METADATA_EXPORT: &str = "lean_fmt_metadata";
    /// `@[export lean_fmt_doctor]` — capability self-check command.
    pub const DOCTOR_EXPORT: &str = "lean_fmt_doctor";
}

/// Request to build the packaged runtime for one Lean toolchain.
///
/// `cache_root` is caller-owned; this crate owns the layout below it, keyed by source
/// digest and requested toolchain label.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FormatterRuntimeBuild {
    /// Caller-owned cache root.
    pub cache_root: PathBuf,
    /// Lean toolchain label written into the generated `lean-toolchain`.
    pub toolchain_label: String,
    /// Lean sysroot whose `bin/lake` and `LEAN_SYSROOT` drive the Lake build.
    pub lean_sysroot: PathBuf,
}

/// Request to materialize the packaged runtime as a Lake source package without
/// building it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FormatterSourcePackageRequest {
    /// Caller-owned cache root.
    pub cache_root: PathBuf,
    /// Lean toolchain label written into the generated `lean-toolchain`.
    pub toolchain_label: String,
}

/// Built `LeanFmt` runtime capability plus package provenance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FormatterRuntime {
    /// Built Lean capability descriptor for `LeanFmt`.
    pub built: LeanBuiltCapability,
    /// Runtime payload provenance for diagnostics and cache validation.
    pub provenance: FormatterRuntimeProvenance,
}

/// Materialized `LeanFmt` source package plus provenance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FormatterSourcePackage {
    /// Materialized Lake project root, owned by this crate; treat as opaque.
    pub project_root: PathBuf,
    /// Runtime payload provenance for diagnostics and cache validation.
    pub provenance: FormatterRuntimeProvenance,
}

/// Provenance recorded beside each materialized runtime package.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FormatterRuntimeProvenance {
    /// Sidecar schema version.
    pub schema_version: u32,
    /// In-repo source revision marker.
    pub source_revision: String,
    /// Runtime source digest computed from the in-repo `lean/` package.
    pub runtime_source_digest: String,
    /// Lake package name.
    pub package: String,
    /// Cache-private Lake package identifier.
    pub materialized_package: String,
    /// Lean library/root module name.
    pub library: String,
    /// Requested Lean toolchain label.
    pub toolchain_label: String,
    /// Runtime crate version.
    pub crate_version: String,
    /// Whether `lean-toolchain` was generated during materialization.
    pub generated_toolchain_file: bool,
}

impl FormatterRuntimeProvenance {
    fn new(toolchain_label: &str, runtime_source_digest: String) -> Self {
        Self {
            schema_version: CACHE_SCHEMA_VERSION,
            source_revision: SOURCE_REVISION.to_owned(),
            runtime_source_digest,
            package: PACKAGE_NAME.to_owned(),
            materialized_package: MATERIALIZED_PACKAGE_NAME.to_owned(),
            library: LIBRARY_NAME.to_owned(),
            toolchain_label: toolchain_label.to_owned(),
            crate_version: env!("CARGO_PKG_VERSION").to_owned(),
            generated_toolchain_file: true,
        }
    }
}

/// Runtime crate errors.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Filesystem operation failed.
    #[error("{action} {}: {source}", path.display())]
    Io {
        /// Operation being attempted.
        action: &'static str,
        /// Path involved in the operation.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: std::io::Error,
    },
    /// JSON sidecar or manifest operation failed.
    #[error("{action} {}: {source}", path.display())]
    Json {
        /// Operation being attempted.
        action: &'static str,
        /// Path involved in the operation.
        path: PathBuf,
        /// Underlying JSON error.
        #[source]
        source: serde_json::Error,
    },
    /// Runtime payload invariant failed.
    #[error("invalid lean-fmt runtime payload: {0}")]
    InvalidRuntimePayload(String),
    /// Shared source-package materialization failed.
    #[error("lean-fmt runtime source materialization failed: {source}")]
    SourcePackage {
        /// Source-package materialization error.
        #[from]
        source: SourcePackageError,
    },
    /// Lake capability build failed.
    #[error("lean-fmt runtime build failed for toolchain {toolchain_label}: {source}")]
    Build {
        /// Requested toolchain label.
        toolchain_label: String,
        /// Lean/Lake diagnostic.
        #[source]
        source: LinkDiagnostics,
    },
    /// Built runtime descriptor was incomplete or invalid.
    #[error("lean-fmt runtime built capability descriptor is invalid: {source}")]
    BuiltCapability {
        /// Descriptor resolution failure.
        #[source]
        source: LeanBuiltCapabilityError,
    },
}

/// Build the packaged `LeanFmt` runtime capability for one toolchain.
///
/// Materializes the source package (cache hit on an unchanged digest), takes a build
/// lock over the materialized root, and drives an explicit-sysroot Lake build.
///
/// # Errors
///
/// Returns [`Error`] when materialization, cache validation, or the explicit-sysroot
/// Lake build fails.
pub fn build_cached(input: FormatterRuntimeBuild) -> Result<FormatterRuntime, Error> {
    let package = materialize_source_package(FormatterSourcePackageRequest {
        cache_root: input.cache_root,
        toolchain_label: input.toolchain_label.clone(),
    })?;
    let _build_lock = lock_runtime_build(&package.project_root)?;
    let mut builder = CargoLeanCapability::new(&package.project_root, LIBRARY_NAME)
        .package(MATERIALIZED_PACKAGE_NAME)
        .module(LIBRARY_NAME)
        .lean_sysroot(input.lean_sysroot);
    for signature in export_signatures() {
        builder = builder.export_signature(signature);
    }
    let built = builder.build_quiet().map_err(|source| Error::Build {
        toolchain_label: input.toolchain_label,
        source,
    })?;
    Ok(FormatterRuntime {
        built: (&built).into(),
        provenance: package.provenance,
    })
}

/// Materialize the packaged runtime source package without building it.
///
/// # Errors
///
/// Returns [`Error`] when the in-repo source is invalid, the digest cannot be computed,
/// or cache materialization fails.
pub fn materialize_source_package(input: FormatterSourcePackageRequest) -> Result<FormatterSourcePackage, Error> {
    let source_root = Path::new(RUNTIME_SOURCE_ROOT);
    ensure_runtime_payload_source(source_root)?;
    let digest = compute_runtime_source_digest_from(source_root)?;
    let provenance = FormatterRuntimeProvenance::new(&input.toolchain_label, digest);
    let request = source_package_request(input.cache_root, &input.toolchain_label, &provenance)?;
    let materialized = materialize_with_toolchain(&request)?;
    Ok(FormatterSourcePackage {
        project_root: materialized.project_root,
        provenance,
    })
}

/// Compute the runtime source digest from the in-repo `lean/` package.
///
/// # Errors
///
/// Returns [`Error`] if the runtime source files cannot be read.
pub fn compute_runtime_source_digest() -> Result<String, Error> {
    compute_runtime_source_digest_from(Path::new(RUNTIME_SOURCE_ROOT))
}

fn export_signatures() -> [LeanExportSignature; 2] {
    [
        metadata_signature(exports::METADATA_EXPORT),
        doctor_signature(exports::DOCTOR_EXPORT),
    ]
}

fn source_package_request(
    cache_root: PathBuf,
    toolchain_label: &str,
    provenance: &FormatterRuntimeProvenance,
) -> Result<SourcePackageMaterializationRequest, Error> {
    Ok(SourcePackageMaterializationRequest {
        source_root: PathBuf::from(RUNTIME_SOURCE_ROOT),
        cache_root,
        package_name: PACKAGE_NAME.to_owned(),
        materialized_package_name: MATERIALIZED_PACKAGE_NAME.to_owned(),
        library_name: LIBRARY_NAME.to_owned(),
        source_digest: provenance.runtime_source_digest.clone(),
        source_revision: SOURCE_REVISION.to_owned(),
        crate_name: env!("CARGO_PKG_NAME").to_owned(),
        crate_version: env!("CARGO_PKG_VERSION").to_owned(),
        toolchain_label: toolchain_label.to_owned(),
        // Copy only the Lean source; `.lake`, `lean-toolchain`, and the source lakefile
        // are excluded and replaced by the generated files below.
        include_paths: vec![PathBuf::from("LeanFmt.lean"), PathBuf::from("LeanFmt")],
        generated_files: vec![
            GeneratedSourceFile {
                relative_path: PathBuf::from("lakefile.lean"),
                contents: materialized_lakefile_bytes(),
            },
            GeneratedSourceFile {
                relative_path: PathBuf::from("lake-manifest.json"),
                contents: materialized_manifest_bytes(),
            },
            GeneratedSourceFile {
                relative_path: PathBuf::from(SIDECAR_FILE_NAME),
                contents: sidecar_bytes(provenance)?,
            },
        ],
        sentinel_files: [
            "lakefile.lean",
            "lake-manifest.json",
            "LeanFmt.lean",
            "LeanFmt/Capability.lean",
            SIDECAR_FILE_NAME,
        ]
        .into_iter()
        .map(PathBuf::from)
        .collect(),
        manifest_policy: SourcePackageManifestPolicy::ZeroPackages,
    })
}

/// The materialized Lake project uses the underscored package name so Lake resolves
/// build output paths; the library, roots, and globs match `lean/lakefile.lean`.
fn materialized_lakefile_bytes() -> Vec<u8> {
    let text = concat!(
        "import Lake\n",
        "open Lake DSL\n\n",
        "package lean_fmt where\n",
        "  version := v!\"0.1.0\"\n\n",
        "@[default_target]\n",
        "lean_lib LeanFmt where\n",
        "  roots := #[`LeanFmt]\n",
        "  globs := #[.andSubmodules `LeanFmt]\n",
    );
    text.as_bytes().to_vec()
}

/// Zero-dependency manifest with the materialized package name.
fn materialized_manifest_bytes() -> Vec<u8> {
    let text = concat!(
        "{\"version\": \"1.2.0\",\n",
        " \"packagesDir\": \".lake/packages\",\n",
        " \"packages\": [],\n",
        " \"name\": \"lean_fmt\",\n",
        " \"lakeDir\": \".lake\",\n",
        " \"fixedToolchain\": false}\n",
    );
    text.as_bytes().to_vec()
}

fn sidecar_bytes(provenance: &FormatterRuntimeProvenance) -> Result<Vec<u8>, Error> {
    let mut bytes = serde_json::to_vec_pretty(provenance).map_err(|source| Error::Json {
        action: "encode lean-fmt runtime provenance sidecar",
        path: PathBuf::from(SIDECAR_FILE_NAME),
        source,
    })?;
    bytes.push(b'\n');
    Ok(bytes)
}

/// Validate that the in-repo runtime source has the required files and a
/// zero-dependency manifest before materialization.
fn ensure_runtime_payload_source(source_root: &Path) -> Result<(), Error> {
    for required in [
        "LeanFmt.lean",
        "LeanFmt/Capability.lean",
        "lakefile.lean",
        "lake-manifest.json",
    ] {
        let path = source_root.join(required);
        if !path.exists() {
            return Err(Error::InvalidRuntimePayload(format!(
                "runtime source missing required file {}",
                path.display()
            )));
        }
    }
    ensure_zero_package_manifest(&source_root.join("lake-manifest.json"))
}

fn ensure_zero_package_manifest(path: &Path) -> Result<(), Error> {
    let manifest: serde_json::Value =
        serde_json::from_slice(&read_file(path, "read lean-fmt runtime lake-manifest.json")?).map_err(|source| {
            Error::Json {
                action: "decode lean-fmt runtime lake-manifest.json",
                path: path.to_path_buf(),
                source,
            }
        })?;
    let packages = manifest
        .get("packages")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| {
            Error::InvalidRuntimePayload("lake-manifest.json must contain an array `packages`".to_owned())
        })?;
    if packages.is_empty() {
        Ok(())
    } else {
        Err(Error::InvalidRuntimePayload(
            "lake-manifest.json must remain zero-dependency (`packages: []`)".to_owned(),
        ))
    }
}

fn compute_runtime_source_digest_from(source_root: &Path) -> Result<String, Error> {
    let mut entries = digest_entries(source_root)?;
    entries.sort_by(|left, right| left.0.cmp(&right.0));
    let mut outer = Sha256::new();
    for (canonical_path, digest) in entries {
        outer.update(digest.as_bytes());
        outer.update(b"  ");
        outer.update(canonical_path.as_bytes());
        outer.update(b"\n");
    }
    Ok(hex_lower(&outer.finalize()))
}

fn digest_entries(source_root: &Path) -> Result<Vec<(String, String)>, Error> {
    let mut entries = Vec::new();
    let walker = WalkDir::new(source_root)
        .into_iter()
        .filter_entry(|entry| entry.file_name() != ".lake");
    for entry in walker {
        let entry = entry.map_err(|source| Error::InvalidRuntimePayload(format!("walk runtime source: {source}")))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let relative = path.strip_prefix(source_root).map_err(|source| {
            Error::InvalidRuntimePayload(format!("relative path for {}: {source}", path.display()))
        })?;
        if excluded_runtime_path(relative) {
            continue;
        }
        let mut hasher = Sha256::new();
        hasher.update(&read_file(path, "read lean-fmt runtime source file")?);
        entries.push((canonical_digest_path(relative), hex_lower(&hasher.finalize())));
    }
    Ok(entries)
}

fn excluded_runtime_path(relative: &Path) -> bool {
    relative.components().any(|component| component.as_os_str() == ".lake")
        || relative == Path::new("lean-toolchain")
        || relative
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| matches!(extension, "olean" | "ilean" | "c" | "so" | "dylib" | "a"))
}

fn canonical_digest_path(relative: &Path) -> String {
    relative.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")
}

fn hex_lower(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut out = String::new();
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn read_file(path: &Path, action: &'static str) -> Result<Vec<u8>, Error> {
    fs::read(path).map_err(|source| Error::Io {
        action,
        path: path.to_path_buf(),
        source,
    })
}

struct BuildLock {
    _file: File,
}

fn lock_runtime_build(project_root: &Path) -> Result<BuildLock, Error> {
    let path = project_root.join(".lean-fmt-runtime-build.lock");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)
        .map_err(|source| Error::Io {
            action: "open lean-fmt runtime build lock",
            path: path.clone(),
            source,
        })?;
    fs4::FileExt::lock(&file).map_err(|source| Error::Io {
        action: "lock lean-fmt runtime build",
        path,
        source,
    })?;
    Ok(BuildLock { _file: file })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use tempfile::TempDir;

    use super::{
        FormatterSourcePackageRequest, LIBRARY_NAME, MATERIALIZED_PACKAGE_NAME, SIDECAR_FILE_NAME,
        compute_runtime_source_digest, materialize_source_package,
    };

    fn request(cache_root: &std::path::Path) -> FormatterSourcePackageRequest {
        FormatterSourcePackageRequest {
            cache_root: cache_root.to_path_buf(),
            toolchain_label: "leanprover/lean4:v4.32.0-rc1".to_owned(),
        }
    }

    #[test]
    fn digest_is_deterministic_and_hex() {
        let first = compute_runtime_source_digest().unwrap();
        let second = compute_runtime_source_digest().unwrap();
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
        assert!(first.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn materialize_writes_expected_files_and_provenance() {
        let cache = TempDir::new().unwrap();
        let package = materialize_source_package(request(cache.path())).unwrap();
        let root = &package.project_root;
        assert!(root.join("LeanFmt.lean").is_file());
        assert!(root.join("LeanFmt/Capability.lean").is_file());
        assert!(root.join(SIDECAR_FILE_NAME).is_file());
        let lakefile = std::fs::read_to_string(root.join("lakefile.lean")).unwrap();
        assert!(lakefile.contains("package lean_fmt where"));
        // The source lakefile's guillemet name must not survive into the materialized package.
        assert!(!lakefile.contains("«lean-fmt»"));
        assert_eq!(package.provenance.materialized_package, MATERIALIZED_PACKAGE_NAME);
        assert_eq!(package.provenance.library, LIBRARY_NAME);
        assert_eq!(package.provenance.runtime_source_digest.len(), 64);
    }

    #[test]
    fn warm_materialization_reuses_entry() {
        let cache = TempDir::new().unwrap();
        let cold = materialize_source_package(request(cache.path())).unwrap();
        let warm = materialize_source_package(request(cache.path())).unwrap();
        assert_eq!(cold.project_root, warm.project_root);
        assert_eq!(cold.provenance, warm.provenance);
    }

    #[test]
    fn corrupt_sidecar_rematerializes() {
        let cache = TempDir::new().unwrap();
        let cold = materialize_source_package(request(cache.path())).unwrap();
        std::fs::write(cold.project_root.join(SIDECAR_FILE_NAME), b"not json").unwrap();
        // A second materialization must recover a valid package rather than trusting the
        // corrupted sidecar.
        let recovered = materialize_source_package(request(cache.path())).unwrap();
        assert_eq!(recovered.provenance, cold.provenance);
        let sidecar = std::fs::read_to_string(recovered.project_root.join(SIDECAR_FILE_NAME)).unwrap();
        assert!(sidecar.contains("runtime_source_digest"));
    }
}
