//! The `lean-fmt serve` transport: a stdio, line-delimited JSON loop over a [`FormatService`].
//!
//! This is the thin transport layer above the transport-agnostic service core in
//! `lean-fmt-project`. It reads one JSON request object per line from stdin, hands it to the
//! single worker-owning controller thread, and writes one JSON response object per line to
//! stdout. Progress and errors go to stderr so stdout stays a clean response stream.
//!
//! Stdio is the default editor process model (one client launches one server, EOF ends it),
//! mirroring `lean-host-mcp`. A local socket or HTTP transport would construct the *same*
//! [`FormatService`] over the same controller; neither would own the worker session, which is
//! why the stop-rule guarantee is a property of the core, not of this transport.

use std::io::{BufRead, Write};
use std::path::PathBuf;

use lean_fmt_project::{
    FormatService, FormatterConfig, ServiceRequest, ServiceResponse, ServiceSettings, ValidationLevel,
};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::resolve_installed_worker;

use crate::{CacheKeyBuilder, Error, Result, ServeArgs, cache_root_for, project_search_path};

/// The bounded request-queue depth: past this many queued requests, `try_submit` reports
/// `busy`. Sized for an editor's burst of per-keystroke requests, not throughput.
const QUEUE_CAPACITY: usize = 64;

/// Run the stdio server until stdin reaches EOF or a `shutdown` request stops the service.
///
/// # Errors
/// Returns an error if config/discovery fails or no usable worker is installed. A malformed
/// request line is *not* an error — it is answered with an error response and the loop goes on.
pub(crate) fn serve(args: &ServeArgs) -> Result<()> {
    let service = build_service(args)?;
    run_loop(&service, std::io::stdin().lock(), &mut std::io::stdout().lock())
}

/// Resolve the workspace and worker and spawn the long-lived [`FormatService`].
fn build_service(args: &ServeArgs) -> Result<FormatService> {
    let config = match &args.config {
        Some(path) => FormatterConfig::load_from(path)?,
        None => FormatterConfig::discover(&args.root)?,
    };
    let selection = lean_fmt_diagnostics::RuleSelection::new(
        args.select.clone(),
        args.ignore.clone(),
        config.select.clone(),
        config.ignore.clone(),
        config.per_file_ignores.clone(),
    );
    let level = if args.check_elab {
        ValidationLevel::Elab
    } else {
        ValidationLevel::Syntax
    };

    // Discover the Lake root so the worker, cache, and import search path match the project.
    let workspace = lean_fmt_project::resolve(&args.root, args.module_root.as_deref(), &config)?;
    let root = workspace.root;

    let installed = resolve_installed_worker(&root).map_err(|error| Error::Worker(error.to_string()))?;
    let keys = CacheKeyBuilder::new(
        &config,
        env!("CARGO_PKG_VERSION"),
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        level,
    );
    let settings = ServiceSettings {
        selection,
        level,
        search_path: project_search_path(&root),
        keys,
    };
    let cache = cache_for_serve(args, cache_root_for(&root));

    eprintln!("lean-fmt: serving {}", root.display());
    // The worker is built inside the controller thread, so it is owned solely by that thread.
    FormatService::spawn(settings, cache, QUEUE_CAPACITY, move || {
        Ok(FormatterWorker::from_installed(&installed))
    })
    .map_err(Error::Worker)
}

/// The incremental cache for a serve run, honoring `--no-cache`.
fn cache_for_serve(args: &ServeArgs, cache_root: PathBuf) -> lean_fmt_project::FormatCache {
    // Reuse the file-mode resolver's `--no-cache` semantics via a synthesized flag check.
    if args.no_cache {
        lean_fmt_project::FormatCache::disabled(cache_root)
    } else {
        lean_fmt_project::FormatCache::new(cache_root)
    }
}

/// The read/serve/write loop, generic over the reader and writer so it is directly testable.
fn run_loop(service: &FormatService, reader: impl BufRead, writer: &mut impl Write) -> Result<()> {
    for line in reader.lines() {
        let line = line.map_err(|error| Error::Worker(format!("stdin read failed: {error}")))?;
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<ServiceRequest>(&line) {
            Ok(request) => service.submit(request),
            Err(error) => ServiceResponse::Error {
                message: format!("malformed request: {error}"),
            },
        };
        let stopping = matches!(response, ServiceResponse::ShuttingDown);
        write_response(writer, &response)?;
        if stopping {
            break;
        }
    }
    Ok(())
}

/// Write one response as a single JSON line, then flush so an editor sees it immediately.
fn write_response(writer: &mut impl Write, response: &ServiceResponse) -> Result<()> {
    let json = serde_json::to_string(response)?;
    writer
        .write_all(json.as_bytes())
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush())
        .map_err(|error| Error::Worker(format!("stdout write failed: {error}")))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use lean_fmt_project::{FormatService, ServiceResponse, ServiceSettings};

    use super::run_loop;

    /// Build a service backed by a stub parser that reports every file clean, so the loop can
    /// be exercised without a real worker.
    fn stub_service() -> (FormatService, tempfile::TempDir) {
        use std::collections::BTreeMap;
        use std::path::PathBuf;

        use lean_fmt_diagnostics::RuleSelection;
        use lean_fmt_project::{CacheKeyBuilder, FormatCache, FormatterConfig, SourceParser, ValidationLevel};
        use lean_fmt_worker::{
            ModuleHeader, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary, ValidateResponse, WorkerError,
        };

        struct Clean;
        impl SourceParser for Clean {
            fn parse_source(
                &mut self,
                _file: &str,
                _source: &str,
                _search_path: &[PathBuf],
            ) -> std::result::Result<ParseFileResponse, WorkerError> {
                Ok(ParseFileResponse {
                    status: ParseStatus::Ok,
                    diagnostics: Vec::new(),
                    diagnostics_truncated: false,
                    module_header: ModuleHeader {
                        imports: Vec::new(),
                        is_module: false,
                        import_spans: Vec::new(),
                    },
                    syntax_summary: SyntaxSummary {
                        command_count: 0,
                        command_kinds: Vec::new(),
                        command_regions: Vec::new(),
                        declaration_headers: Vec::new(),
                        tactic_blocks: Vec::new(),
                    },
                    source_model: SourceModel {
                        trivia_runs: Vec::new(),
                        docstrings: Vec::new(),
                    },
                })
            }

            fn validate_source(
                &mut self,
                _file: &str,
                _source: &str,
                _search_path: &[PathBuf],
            ) -> std::result::Result<ValidateResponse, WorkerError> {
                Ok(ValidateResponse {
                    valid: true,
                    diagnostics: Vec::new(),
                    diagnostics_truncated: false,
                })
            }
        }

        let dir = tempfile::TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        let settings = ServiceSettings {
            selection: RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new()),
            level: ValidationLevel::Syntax,
            search_path: Vec::new(),
            keys: CacheKeyBuilder::new(
                &FormatterConfig::default(),
                "0.1.0",
                "tc",
                "rt",
                ValidationLevel::Syntax,
            ),
        };
        let service = FormatService::spawn(settings, cache, 8, || Ok(Clean)).unwrap();
        (service, dir)
    }

    #[test]
    fn loop_answers_one_json_line_per_request_and_stops_on_shutdown() {
        let (service, _dir) = stub_service();
        // Two requests then a shutdown; a blank line is skipped.
        let input = concat!(
            r#"{"method":"check","path":"A.lean","text":"def a := 1\n"}"#,
            "\n\n",
            r#"{"method":"health"}"#,
            "\n",
            r#"{"method":"shutdown"}"#,
            "\n",
            // This line is past the shutdown and must never be served.
            r#"{"method":"health"}"#,
            "\n",
        );
        let mut output = Vec::new();
        run_loop(&service, input.as_bytes(), &mut output).unwrap();

        let text = String::from_utf8(output).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3, "one response per request up to shutdown: {text}");

        let first: ServiceResponse = serde_json::from_str(lines[0]).unwrap();
        assert!(matches!(first, ServiceResponse::Analyzed { changed: false, .. }));
        let second: ServiceResponse = serde_json::from_str(lines[1]).unwrap();
        assert!(matches!(second, ServiceResponse::Health { served: 1, .. }));
        let third: ServiceResponse = serde_json::from_str(lines[2]).unwrap();
        assert!(matches!(third, ServiceResponse::ShuttingDown));
    }

    #[test]
    fn a_malformed_request_line_is_answered_not_fatal() {
        let (service, _dir) = stub_service();
        let input = concat!("not json at all\n", r#"{"method":"shutdown"}"#, "\n");
        let mut output = Vec::new();
        run_loop(&service, input.as_bytes(), &mut output).unwrap();

        let text = String::from_utf8(output).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2, "the bad line got an error response; the loop continued");
        let first: ServiceResponse = serde_json::from_str(lines[0]).unwrap();
        assert!(matches!(first, ServiceResponse::Error { .. }));
    }
}
