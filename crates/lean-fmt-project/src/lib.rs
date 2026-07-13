//! Lake project model and orchestration for lean-fmt.
//!
//! Discovers Lake project roots, enumerates Lean source files, loads formatter config,
//! and (in later prompts) drives the check / fix / diff modes. One project owns one
//! serialized worker controller, mirroring the `lean-host-mcp` host policy. Discovery
//! never scans `.lake` source and does not assume a single module root.

mod analyze;
mod cache;
mod config;
mod error;
mod run;
mod server;
mod validate;
mod workspace;

pub use analyze::{AnalysisOutcome, AnalyzeError, FileAnalysis, SourceParser, analyze_file};
pub use cache::{CacheKey, CacheLookup, CacheMiss, FormatCache, InvalidationReason, config_fingerprint, source_digest};
pub use config::{CONFIG_FILE_NAME, FormatterConfig};
pub use error::{Error, Result};
pub use run::{CacheKeyBuilder, FileReport, ProjectRun, RunMode, RunSummary, run_project};
pub use server::{FormatService, ParseFinding, ServiceRequest, ServiceResponse, ServiceSettings};
pub use validate::{SafeApplyError, ValidationLevel, ValidationOutcome, safe_apply};
pub use workspace::{ProjectRoot, ResolvedWorkspace, SourceFile, resolve, resolve_files};
