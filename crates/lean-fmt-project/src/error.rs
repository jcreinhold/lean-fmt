//! Errors raised while discovering and resolving a Lake workspace.

use std::path::PathBuf;

use thiserror::Error;

/// An error produced by project discovery or configuration loading.
#[derive(Debug, Error)]
pub enum Error {
    /// The requested path does not exist on disk.
    #[error("workspace path does not exist: {0}")]
    WorkspaceMissing(PathBuf),

    /// The requested path (and its `lean/` child) contains no `lakefile.lean`
    /// or `lakefile.toml`, so it is not a Lake project root.
    #[error("not a Lake project: no lakefile.lean or lakefile.toml in {0} or its lean/ subdirectory")]
    NotLakeWorkspace(PathBuf),

    /// A Lake root was found but no `lean_lib` module roots could be determined.
    #[error("no module roots found under Lake project {0}")]
    NoModuleRoots(PathBuf),

    /// Discovery selected roots but found no `.lean` source files to format.
    #[error("no Lean source files found under {root} for module root(s): {selected}")]
    NoSourceFiles {
        /// The resolved Lake root.
        root: PathBuf,
        /// The module roots that were searched.
        selected: String,
    },

    /// An explicitly requested file is missing or is not a `.lean` file.
    #[error("requested file is not a readable .lean file: {0}")]
    NotALeanFile(PathBuf),

    /// A `lakefile.toml` could not be parsed.
    #[error("could not parse {path}: {source}")]
    LakefileToml {
        /// The offending lakefile path.
        path: PathBuf,
        /// The underlying TOML error (boxed: `toml::de::Error` is large).
        source: Box<toml::de::Error>,
    },

    /// A `lean-fmt.toml` config file could not be parsed.
    #[error("could not parse config {path}: {source}")]
    Config {
        /// The offending config path.
        path: PathBuf,
        /// The underlying TOML error (boxed: `toml::de::Error` is large).
        source: Box<toml::de::Error>,
    },

    /// A filesystem operation failed.
    #[error("{message}: {path}: {source}")]
    Io {
        /// Human-readable context for the failing operation.
        message: &'static str,
        /// The path involved.
        path: PathBuf,
        /// The underlying I/O error.
        source: std::io::Error,
    },

    /// A cache entry could not be serialized (or otherwise processed) before write.
    #[error("{message}: {source}")]
    Cache {
        /// Human-readable context for the failing operation.
        message: &'static str,
        /// The underlying serialization error (boxed to keep the enum small).
        source: Box<serde_json::Error>,
    },
}

/// Convenience alias for results in this crate.
pub type Result<T> = std::result::Result<T, Error>;
