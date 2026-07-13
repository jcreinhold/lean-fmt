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

use lean_fmt_edit::{DeclHeaderRecord, Diagnostic, ImportRecord, SyntaxRegion, TacticBlockRecord, TextRange};
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

/// Request for the `lean_fmt_parse_file` command.
///
/// `imports` is an optional caller hint; the Lean side derives the authoritative
/// import set from the snapshot's own header. `options` seeds `initSearchPath` so the
/// header's imports (and their notation/parser extensions) resolve.
#[derive(Clone, Debug, Serialize)]
pub struct ParseFileRequest {
    /// File label used in diagnostics (the snapshot is not read from disk).
    pub file: String,
    /// The in-memory Lean source to parse.
    pub source: String,
    /// Optional caller-supplied import hint; omitted from the wire when empty.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub imports: Vec<String>,
    /// Search-path options for resolving the header's imports.
    pub options: ParseFileOptions,
}

/// Search-path options for [`ParseFileRequest`].
#[derive(Clone, Debug, Serialize)]
pub struct ParseFileOptions {
    /// Lean sysroot whose core `.olean`s seed the module search path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sysroot: Option<String>,
    /// Extra module build directories (e.g. the target project's build output).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub search_path: Vec<String>,
}

/// Outcome tag for a parse (`lean_fmt_parse_file`).
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ParseStatus {
    /// Header, imports, and body all parsed without error.
    Ok,
    /// A best-effort parse: an import was unresolved or the body carried parse errors.
    Degraded,
    /// The header itself failed to parse, or the request envelope was malformed.
    Error,
}

/// A single parse diagnostic, mirroring `LeanFmt.Frontend`'s rendering.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ParseDiagnostic {
    /// Severity tag (`info`/`warning`/`error`).
    pub severity: String,
    /// Human-readable message body.
    pub message: String,
    /// File label the diagnostic is attributed to.
    pub file: String,
    /// 1-based line of the diagnostic start.
    pub line: u32,
    /// 0-based column of the diagnostic start.
    pub column: u32,
    /// Optional end line.
    #[serde(default)]
    pub end_line: Option<u32>,
    /// Optional end column.
    #[serde(default)]
    pub end_column: Option<u32>,
}

/// The parsed module header summary.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ModuleHeader {
    /// Deduplicated import module names derived from the snapshot header.
    pub imports: Vec<String>,
    /// Whether the header is a `module` header.
    pub is_module: bool,
    /// Byte-anchored per-`import` records (module name + statement range), in source
    /// order. Empty for header-error responses. Unlike `imports`, these are *not*
    /// deduplicated — a repeated `import X` appears once per statement, so the import
    /// rule can flag and remove the duplicate.
    #[serde(default)]
    pub import_spans: Vec<ImportRecord>,
}

/// One top-level command kind and its occurrence count.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct CommandKind {
    /// Syntax node kind (e.g. `Lean.Parser.Command.declaration`).
    pub kind: String,
    /// Number of top-level commands of this kind.
    pub count: usize,
}

/// The lightweight syntax summary of a parsed snapshot.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct SyntaxSummary {
    /// Total top-level commands parsed.
    pub command_count: usize,
    /// Per-kind command counts.
    pub command_kinds: Vec<CommandKind>,
    /// Per-command byte-anchored source regions (kind + byte range + line/column),
    /// in parse order. Empty for header-error / degraded-before-parse responses.
    #[serde(default)]
    pub command_regions: Vec<SyntaxRegion>,
    /// Per-declaration header role spans (keyword/name/binders/return-colon/`:=`/
    /// `where`), in parse order. The substrate the `declaration/header-spacing` rule
    /// consumes. Empty for header-error / degraded-before-parse responses.
    #[serde(default)]
    pub declaration_headers: Vec<DeclHeaderRecord>,
    /// Per-`by`-block tactic anchor spans (`by`/seq/first-step/bullets), in parse order.
    /// The substrate the `tactic/block-indent` rule consumes. Empty for header-error /
    /// degraded-before-parse responses.
    #[serde(default)]
    pub tactic_blocks: Vec<TacticBlockRecord>,
}

/// The source model of a parsed snapshot: trivia runs plus docstring node ranges.
///
/// The inter-token trivia runs hold every comment and blank line; classification of a
/// run's text into typed [`lean_fmt_edit::Trivia`] pieces is done with
/// [`lean_fmt_edit::classify_trivia`]. Docstrings arrive as separate node ranges.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Default)]
pub struct SourceModel {
    /// Maximal byte ranges between parsed tokens, in source order. Their union with the
    /// token spans is `[0, source_len)`, so all comments and whitespace live here.
    #[serde(default)]
    pub trivia_runs: Vec<TextRange>,
    /// Byte ranges of `docComment` nodes (`/-- … -/`, `/-! … -/`). These are syntax, not
    /// trivia, and never overlap a trivia run.
    #[serde(default)]
    pub docstrings: Vec<TextRange>,
}

/// Response from the `lean_fmt_parse_file` command.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ParseFileResponse {
    /// Parse outcome tag.
    pub status: ParseStatus,
    /// Parse diagnostics rendered from the Lean message log.
    pub diagnostics: Vec<ParseDiagnostic>,
    /// Whether the diagnostics list was byte-bounded and truncated.
    pub diagnostics_truncated: bool,
    /// The parsed module header.
    pub module_header: ModuleHeader,
    /// The lightweight syntax summary.
    pub syntax_summary: SyntaxSummary,
    /// The trivia/docstring source model (empty for header-error responses).
    #[serde(default)]
    pub source_model: SourceModel,
}

/// The formatter diagnostics response envelope: schema version plus rule findings.
///
/// This is the wire shape the Lean `LeanFmt.Protocol` constructors emit and a future
/// `lean_fmt_diagnostics` command returns; each [`Diagnostic`] carries an optional
/// conflict-checked fix ([`lean_fmt_edit::EditSet`]).
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Default)]
pub struct FormatterDiagnostics {
    /// The edit-protocol schema version; must equal [`lean_fmt_edit::SCHEMA`].
    pub schema: String,
    /// The rule findings, each with an optional fix.
    #[serde(default)]
    pub diagnostics: Vec<Diagnostic>,
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
            .json_command_export(exports::PARSE_FILE_EXPORT)
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

    /// Parse an in-memory Lean source snapshot (`lean_fmt_parse_file`), resolving the
    /// header's imports against this worker's sysroot plus `search_path`.
    ///
    /// `search_path` should contain the target project's module build directories so
    /// import-dependent syntax (custom notation from another module) parses; when a
    /// module is unresolved the worker returns [`ParseStatus::Degraded`] rather than
    /// failing. A syntactically broken snapshot returns structured diagnostics, not an
    /// error.
    ///
    /// # Errors
    ///
    /// Returns [`WorkerError`] if capability load, child spawn, or dispatch fails (a
    /// parse failure is reported *in* the response, not as an error).
    pub fn parse_file(
        &mut self,
        file: impl Into<String>,
        source: impl Into<String>,
        search_path: &[PathBuf],
    ) -> Result<ParseFileResponse, WorkerError> {
        let request = ParseFileRequest {
            file: file.into(),
            source: source.into(),
            imports: Vec::new(),
            options: ParseFileOptions {
                sysroot: Some(self.lean_sysroot.display().to_string()),
                search_path: search_path.iter().map(|path| path.display().to_string()).collect(),
            },
        };
        self.dispatch_json(exports::PARSE_FILE_EXPORT, &request)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use super::{CapabilityDoctor, CapabilityMetadata, FormatterDiagnostics, ParseFileResponse, ParseStatus};

    // The exact compact envelopes emitted by `lean/LeanFmt/Capability.lean`. These
    // guard the parent DTOs against Lean-side drift without needing a live worker.
    const METADATA_JSON: &str = r#"{"capability":"lean-fmt","schema":"lean-fmt.capability.v1","version":"0.1.0"}"#;
    const DOCTOR_JSON: &str = r#"{"capability":"lean-fmt","schema":"lean-fmt.capability.v1","version":"0.1.0","ok":true,"metadata_valid":true}"#;

    // The exact compact envelopes emitted by `lean/LeanFmt/Frontend.lean`'s
    // `parseFileCommand` (captured from a real run against v4.32.0-rc1). Object keys
    // are alphabetically sorted by `Json.compress`.
    // Captured from a real `parseFileCommand` run against this source (v4.32.0-rc1):
    //   import Init
    //   <blank>
    //   /-- doc -/
    //   def foo := 1 -- t
    //   <blank>
    //   def bar := 2
    // The docstring is a node (`docstrings`), and the run at bytes 36..43 (" -- t\n\n")
    // holds whitespace + a line comment + a blank-line cluster.
    const PARSE_OK_JSON: &str = r#"{"diagnostics":[],"diagnostics_truncated":false,"module_header":{"imports":["Init"],"is_module":false},"source_model":{"docstrings":[{"end":23,"start":13}],"trivia_runs":[{"end":7,"start":6},{"end":13,"start":11},{"end":17,"start":16},{"end":24,"start":23},{"end":28,"start":27},{"end":32,"start":31},{"end":35,"start":34},{"end":43,"start":36},{"end":47,"start":46},{"end":51,"start":50},{"end":54,"start":53},{"end":56,"start":55}]},"status":"ok","syntax_summary":{"command_count":2,"command_kinds":[{"count":2,"kind":"Lean.Parser.Command.declaration"}],"command_regions":[{"kind":"Lean.Parser.Command.declaration","line_column":{"end":{"column":12,"line":4},"start":{"column":0,"line":3}},"range":{"end":36,"start":13}},{"kind":"Lean.Parser.Command.declaration","line_column":{"end":{"column":12,"line":6},"start":{"column":0,"line":6}},"range":{"end":55,"start":43}}]}}"#;
    const PARSE_DEGRADED_JSON: &str = r#"{"diagnostics":[{"column":0,"file":"A.lean","line":4,"message":"unexpected end of input","severity":"error"}],"diagnostics_truncated":false,"module_header":{"imports":["Init"],"is_module":false},"status":"degraded","syntax_summary":{"command_count":1,"command_kinds":[{"count":1,"kind":"Lean.Parser.Command.declaration"}]}}"#;
    const PARSE_ERROR_JSON: &str = r#"{"diagnostics":[{"column":0,"file":"<snapshot>","line":0,"message":"invalid parse_file request","severity":"error"}],"diagnostics_truncated":false,"module_header":{"imports":[],"is_module":false},"status":"error","syntax_summary":{"command_count":0,"command_kinds":[]}}"#;
    // Captured from a real `parseFileCommand` run against this source (v4.32.0-rc1):
    //   import Init
    //   -- about A
    //   import Init
    //   <blank>
    //   def f := 1
    // A duplicate `import Init` with a comment between the two statements. `import_spans`
    // keeps BOTH occurrences (unlike the deduplicated `imports`), each with its own byte
    // range, and the comment at bytes 11..23 is trivia — outside every import range.
    const PARSE_IMPORT_SPANS_JSON: &str = r#"{"diagnostics":[],"diagnostics_truncated":false,"module_header":{"import_spans":[{"module":"Init","range":{"end":11,"start":0}},{"module":"Init","range":{"end":34,"start":23}}],"imports":["Init"],"is_module":false},"source_model":{"docstrings":[],"trivia_runs":[{"end":7,"start":6},{"end":23,"start":11},{"end":30,"start":29},{"end":36,"start":34},{"end":40,"start":39},{"end":42,"start":41},{"end":45,"start":44},{"end":47,"start":46}]},"status":"ok","syntax_summary":{"command_count":1,"command_kinds":[{"count":1,"kind":"Lean.Parser.Command.declaration"}],"command_regions":[{"kind":"Lean.Parser.Command.declaration","line_column":{"end":{"column":10,"line":5},"start":{"column":0,"line":5}},"range":{"end":46,"start":36}}]}}"#;

    // Verbatim envelope for `def f (x : Nat) : Nat := x + 1\n`, captured from a live
    // `lean_fmt_parse_file` run (v4.32.0-rc1). Carries one `declaration_headers` record
    // with every header role span.
    const PARSE_DECL_HEADER_JSON: &str = r#"{"diagnostics":[],"diagnostics_truncated":false,"module_header":{"import_spans":[],"imports":["Init"],"is_module":false},"source_model":{"docstrings":[],"trivia_runs":[{"end":4,"start":3},{"end":6,"start":5},{"end":9,"start":8},{"end":11,"start":10},{"end":16,"start":15},{"end":18,"start":17},{"end":22,"start":21},{"end":25,"start":24},{"end":27,"start":26},{"end":29,"start":28},{"end":31,"start":30}]},"status":"ok","syntax_summary":{"command_count":1,"command_kinds":[{"count":1,"kind":"Lean.Parser.Command.declaration"}],"command_regions":[{"kind":"Lean.Parser.Command.declaration","line_column":{"end":{"column":30,"line":1},"start":{"column":0,"line":1}},"range":{"end":30,"start":0}}],"declaration_headers":[{"assign":{"end":24,"start":22},"binders":[{"close":{"end":15,"start":14},"colon":{"end":10,"start":9},"open":{"end":7,"start":6},"range":{"end":15,"start":6}}],"keyword":{"end":3,"start":0},"kind":"Lean.Parser.Command.definition","name":{"end":5,"start":4},"range":{"end":30,"start":0},"sig_colon":{"end":17,"start":16}}]}}"#;

    // Verbatim envelope for `theorem t : True ∧ True := by\n  refine ⟨?_, ?_⟩\n  · trivial\n  · trivial\n`,
    // captured from a live `lean_fmt_parse_file` run (v4.32.0-rc1). Carries one
    // `tactic_blocks` record with the `by` keyword span, the tactic-sequence span, the
    // base column, the first-step span, and the two `·` bullet markers.
    const PARSE_TACTIC_BLOCKS_JSON: &str = r#"{"diagnostics":[],"diagnostics_truncated":false,"module_header":{"import_spans":[],"imports":["Init"],"is_module":false},"source_model":{"docstrings":[],"trivia_runs":[{"end":8,"start":7},{"end":10,"start":9},{"end":12,"start":11},{"end":17,"start":16},{"end":21,"start":20},{"end":26,"start":25},{"end":29,"start":28},{"end":34,"start":31},{"end":41,"start":40},{"end":48,"start":47},{"end":56,"start":53},{"end":59,"start":58},{"end":69,"start":66},{"end":72,"start":71},{"end":80,"start":79}]},"status":"ok","syntax_summary":{"command_count":1,"command_kinds":[{"count":1,"kind":"Lean.Parser.Command.declaration"}],"command_regions":[{"kind":"Lean.Parser.Command.declaration","line_column":{"end":{"column":11,"line":4},"start":{"column":0,"line":1}},"range":{"end":79,"start":0}}],"declaration_headers":[{"assign":{"end":28,"start":26},"binders":[],"keyword":{"end":7,"start":0},"kind":"Lean.Parser.Command.theorem","name":{"end":9,"start":8},"range":{"end":79,"start":0},"sig_colon":{"end":11,"start":10}}],"tactic_blocks":[{"base_column":2,"bullets":[{"kind":"cdot","range":{"end":58,"start":56}},{"kind":"cdot","range":{"end":71,"start":69}}],"by":{"end":31,"start":29},"first_step":{"end":53,"start":34},"seq":{"end":79,"start":34}}]}}"#;

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

    #[test]
    fn parse_ok_decodes_lean_side_envelope() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_OK_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Ok);
        assert!(resp.diagnostics.is_empty());
        assert!(!resp.diagnostics_truncated);
        assert_eq!(resp.module_header.imports, vec!["Init".to_owned()]);
        assert!(!resp.module_header.is_module);
        assert_eq!(resp.syntax_summary.command_count, 2);
        assert_eq!(
            resp.syntax_summary.command_kinds[0].kind,
            "Lean.Parser.Command.declaration"
        );
        assert_eq!(resp.syntax_summary.command_kinds[0].count, 2);
        // Per-command byte-anchored regions decode through `lean-fmt-edit`.
        let regions = &resp.syntax_summary.command_regions;
        assert_eq!(regions.len(), 2, "two command regions");
        assert_eq!(regions[0].kind, "Lean.Parser.Command.declaration");
        assert_eq!(regions[0].range, lean_fmt_edit::TextRange::new(13, 36));
        assert_eq!(regions[0].line_column.start, lean_fmt_edit::LineColumn::new(3, 0));
        assert_eq!(regions[0].line_column.end, lean_fmt_edit::LineColumn::new(4, 12));
        assert_eq!(regions[1].range, lean_fmt_edit::TextRange::new(43, 55));

        // The source model decodes and classifies. The docstring is a node, not trivia.
        let sm = &resp.source_model;
        assert_eq!(sm.docstrings, vec![lean_fmt_edit::TextRange::new(13, 23)]);
        assert_eq!(sm.trivia_runs.len(), 12, "twelve inter-token trivia runs");
        // The mixed run at 36..43 (" -- t\n\n") classifies as whitespace + line comment
        // + blank lines, and every run tiles losslessly.
        let src = "import Init\n\n/-- doc -/\ndef foo := 1 -- t\n\ndef bar := 2\n";
        let trivia = lean_fmt_edit::classify_trivia(src, &sm.trivia_runs);
        assert!(
            lean_fmt_edit::trivia_tiles_runs(&sm.trivia_runs, &trivia),
            "classification tiles every reported run"
        );
        let mixed: Vec<_> = trivia.iter().filter(|t| t.run_start == 36).map(|t| t.kind).collect();
        assert_eq!(
            mixed,
            [
                lean_fmt_edit::TriviaKind::Whitespace,
                lean_fmt_edit::TriviaKind::LineComment,
                lean_fmt_edit::TriviaKind::BlankLines,
            ]
        );
    }

    #[test]
    fn parse_degraded_decodes_with_diagnostics() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_DEGRADED_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Degraded);
        assert_eq!(resp.diagnostics.len(), 1);
        assert_eq!(resp.diagnostics[0].severity, "error");
        assert_eq!(resp.diagnostics[0].line, 4);
        assert_eq!(resp.syntax_summary.command_count, 1);
    }

    #[test]
    fn parse_decl_headers_decode_role_spans() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_DECL_HEADER_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Ok);
        let headers = &resp.syntax_summary.declaration_headers;
        assert_eq!(headers.len(), 1, "one declaration header");
        let h = &headers[0];
        let source = "def f (x : Nat) : Nat := x + 1\n";
        let at = |r: lean_fmt_edit::TextRange| &source[r.start..r.end];
        assert_eq!(h.kind, "Lean.Parser.Command.definition");
        assert_eq!(at(h.keyword.unwrap()), "def");
        assert_eq!(at(h.name.unwrap()), "f");
        assert_eq!(at(h.sig_colon.unwrap()), ":");
        assert_eq!(at(h.assign.unwrap()), ":=");
        assert!(h.where_kw.is_none());
        assert_eq!(h.binders.len(), 1);
        assert_eq!(at(h.binders[0].range), "(x : Nat)");
        assert_eq!(at(h.binders[0].colon.unwrap()), ":");
    }

    #[test]
    fn parse_tactic_blocks_decode_anchor_spans() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_TACTIC_BLOCKS_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Ok);
        let blocks = &resp.syntax_summary.tactic_blocks;
        assert_eq!(blocks.len(), 1, "one tactic block");
        let b = &blocks[0];
        let source = "theorem t : True ∧ True := by\n  refine ⟨?_, ?_⟩\n  · trivial\n  · trivial\n";
        let at = |r: lean_fmt_edit::TextRange| &source[r.start..r.end];
        assert_eq!(at(b.by_kw), "by");
        assert_eq!(b.base_column, Some(2));
        // The first step is `refine ⟨?_, ?_⟩`; the sequence spans through the last bullet body.
        assert_eq!(at(b.first_step.unwrap()), "refine ⟨?_, ?_⟩");
        assert_eq!(at(b.seq.unwrap()), "refine ⟨?_, ?_⟩\n  · trivial\n  · trivial");
        // Both `·` markers are captured, in source order, each two bytes wide.
        assert_eq!(b.bullets.len(), 2);
        assert_eq!(b.bullets[0].kind, "cdot");
        assert_eq!(at(b.bullets[0].range), "·");
        assert_eq!(b.bullets[1].kind, "cdot");
        assert_eq!(at(b.bullets[1].range), "·");
    }

    #[test]
    fn parse_import_spans_decode_keeps_duplicates() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_IMPORT_SPANS_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Ok);
        // `imports` is deduplicated; `import_spans` records every statement.
        assert_eq!(resp.module_header.imports, vec!["Init".to_owned()]);
        let spans = &resp.module_header.import_spans;
        assert_eq!(spans.len(), 2, "both `import Init` statements are recorded");
        assert_eq!(
            spans[0],
            lean_fmt_edit::ImportRecord {
                module: "Init".to_owned(),
                range: lean_fmt_edit::TextRange::new(0, 11),
            }
        );
        assert_eq!(
            spans[1],
            lean_fmt_edit::ImportRecord {
                module: "Init".to_owned(),
                range: lean_fmt_edit::TextRange::new(23, 34),
            }
        );
        // The comment between the imports (bytes 11..23) is outside every import range.
        for span in spans {
            assert!(
                !span.range.contains(15),
                "the comment byte is not part of any import statement"
            );
        }
    }

    #[test]
    fn parse_error_decodes_malformed_request() {
        let resp: ParseFileResponse = serde_json::from_str(PARSE_ERROR_JSON).unwrap();
        assert_eq!(resp.status, ParseStatus::Error);
        assert!(resp.module_header.imports.is_empty());
        assert_eq!(resp.syntax_summary.command_count, 0);
    }

    // Captured verbatim from `LeanFmt.Protocol.diagnosticsJson` (a diagnostic with a fix
    // edit set). Guards the cross-side edit-protocol contract: Lean builds it, Rust
    // decodes it, and the decoded fix applies through `lean-fmt-edit`.
    const DIAGNOSTICS_JSON: &str = r#"{"diagnostics":[{"applicability":"safe","fix":{"edits":[{"expected":"import B\n","new_text":"import A\n","range":{"end":9,"start":0}}]},"message":"imports are not sorted","range":{"end":9,"start":0},"rule":"import-sort"}],"schema":"lean-fmt.edit.v1"}"#;

    #[test]
    fn diagnostics_envelope_decodes_and_fix_applies() {
        let resp: FormatterDiagnostics = serde_json::from_str(DIAGNOSTICS_JSON).unwrap();
        assert_eq!(resp.schema, lean_fmt_edit::SCHEMA, "Lean and Rust agree on the schema");
        assert_eq!(resp.diagnostics.len(), 1);
        let diag = &resp.diagnostics[0];
        assert_eq!(diag.rule, lean_fmt_edit::RuleId::new("import-sort"));
        assert_eq!(diag.applicability, lean_fmt_edit::Applicability::Safe);
        assert_eq!(diag.range, lean_fmt_edit::TextRange::new(0, 9));
        // The decoded fix applies through the patch engine to reorder the imports.
        let fix = diag.fix.as_ref().expect("diagnostic carries a fix");
        let out = fix.apply("import B\n").expect("fix applies to the expected source");
        assert_eq!(out.output, "import A\n");
        // The same fix is stale against a different source and is rejected, not applied.
        assert!(fix.apply("import C\n").is_err(), "stale source is rejected");
    }
}
