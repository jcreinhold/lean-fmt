//! Lake project model and orchestration for lean-fmt.
//!
//! Discovers Lake project roots, enumerates Lean source files, loads formatter config,
//! and (in later prompts) drives the check / fix / diff modes. One project owns one
//! serialized worker controller, mirroring the `lean-host-mcp` host policy. Discovery
//! never scans `.lake` source and does not assume a single module root.

mod config;
mod error;
mod validate;
mod workspace;

pub use config::{CONFIG_FILE_NAME, FormatterConfig};
pub use error::{Error, Result};
pub use validate::{SafeApplyError, ValidationLevel, ValidationOutcome, safe_apply};
pub use workspace::{ProjectRoot, ResolvedWorkspace, SourceFile, resolve, resolve_files};
