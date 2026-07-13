//! A long-lived, transport-agnostic format service for editor integration.
//!
//! [`FormatService`] answers one-file `format`/`check` requests over a live worker session,
//! suitable for an editor that keeps a formatter running and sends a request per keystroke or
//! save. It is the server analogue of prompt 27's project engine: the same [`analyze_file`]
//! driver, but request-driven instead of file-set-driven.
//!
//! **The load-bearing property is the stop rule** — request handling must never concurrently
//! mutate one worker session. This is enforced *structurally*, not by a lock: a single
//! controller thread is the sole owner of the [`SourceParser`], and every request reaches it
//! over a bounded channel and is served one at a time in FIFO order. Client threads only
//! enqueue a job and block on its reply; there is no path by which two [`analyze_file`] calls
//! run at once. This mirrors `lean-host-mcp`'s project controller ("exactly one owner of the
//! Lean runtime at a time is a structural fact rather than a lock discipline").
//!
//! Two more editor-facing behaviors fall out of the same design:
//!
//! - **Bounded queue → retryable `busy`.** The job channel is bounded; [`FormatService::try_submit`]
//!   returns [`ServiceResponse::Busy`] instead of growing memory without bound when a burst of
//!   requests outruns the worker.
//! - **Stale-version rejection.** A request may carry a monotonic document `version`; a request
//!   for a version at or below the last one seen for that path is rejected as
//!   [`ServiceResponse::Stale`], so a late in-flight request never clobbers newer editor state.
//!
//! The transport (stdio, socket, …) lives above this core in the CLI; this module never does
//! I/O beyond the worker calls `analyze_file` already makes.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::thread::JoinHandle;

use serde::{Deserialize, Serialize};

use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_edit::Diagnostic;
use lean_fmt_worker::ParseDiagnostic;

use crate::analyze::{AnalysisOutcome, FileAnalysis, SourceParser, analyze_file};
use crate::cache::FormatCache;
use crate::run::CacheKeyBuilder;
use crate::validate::ValidationLevel;

/// A request to the format service. Serialized with a `method` tag so a transport can carry it
/// as one JSON object per request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum ServiceRequest {
    /// Format one file's in-memory `text`, returning the formatted output when it changed.
    Format {
        /// The file path the text belongs to (used for the cache key and diagnostics labels).
        path: String,
        /// The in-memory source to format.
        text: String,
        /// An optional monotonic document version for stale-request rejection.
        #[serde(default)]
        version: Option<u64>,
    },
    /// Check one file's in-memory `text`, reporting findings without returning formatted text.
    Check {
        /// The file path the text belongs to.
        path: String,
        /// The in-memory source to check.
        text: String,
        /// An optional monotonic document version for stale-request rejection.
        #[serde(default)]
        version: Option<u64>,
    },
    /// A liveness/status probe that does not touch the worker.
    Health,
    /// Ask the service to shut down gracefully after replying.
    Shutdown,
}

/// A stable, serializable projection of a worker [`ParseDiagnostic`] for the broken-file reply.
/// (`ParseDiagnostic` itself is `Deserialize`-only, so the response cannot embed it directly.)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParseFinding {
    /// Severity tag (`info`/`warning`/`error`).
    pub severity: String,
    /// Human-readable message body.
    pub message: String,
    /// 1-based line of the diagnostic start.
    pub line: u32,
    /// 0-based column of the diagnostic start.
    pub column: u32,
}

impl From<&ParseDiagnostic> for ParseFinding {
    fn from(diagnostic: &ParseDiagnostic) -> Self {
        Self {
            severity: diagnostic.severity.clone(),
            message: diagnostic.message.clone(),
            line: diagnostic.line,
            column: diagnostic.column,
        }
    }
}

/// A response from the format service. Serialized with a `status` tag.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ServiceResponse {
    /// The file parsed and was analyzed. `changed` is whether formatting would alter it;
    /// `formatted` carries the new text (present only for a `format` request that changed it).
    Analyzed {
        /// The file the response is about.
        path: String,
        /// Whether formatting would change the file.
        changed: bool,
        /// The formatted text, when a `format` request produced a change.
        #[serde(skip_serializing_if = "Option::is_none")]
        formatted: Option<String>,
        /// The unified diff from source to formatted, when there is one.
        #[serde(skip_serializing_if = "Option::is_none")]
        diff: Option<String>,
        /// The rule findings (empty for an already-clean file).
        findings: Vec<Diagnostic>,
        /// Whether the analysis was served from the incremental cache.
        from_cache: bool,
    },
    /// The file did not parse cleanly and so was not formatted.
    Broken {
        /// The file the response is about.
        path: String,
        /// The parse diagnostics explaining why.
        diagnostics: Vec<ParseFinding>,
    },
    /// The request carried a document version at or below the last one seen for this path and
    /// was dropped, so a late request cannot overwrite newer editor state.
    Stale {
        /// The file the stale request was about.
        path: String,
        /// The rejected request version.
        version: u64,
        /// The newest version already seen for this path.
        latest: u64,
    },
    /// The bounded request queue was full; the client should retry shortly.
    Busy,
    /// A health probe result: requests served so far and the current worker generation.
    Health {
        /// How many analysis requests the service has served.
        served: u64,
        /// The current worker generation (bumped on a future worker restart).
        worker_generation: u64,
    },
    /// The service acknowledged a shutdown request and is stopping.
    ShuttingDown,
    /// The request could not be served (worker transport failure, cache write failure, …).
    Error {
        /// A human-readable failure message.
        message: String,
    },
}

/// The fixed analysis inputs a running service applies to every request: which rules are
/// active, the validation level, the import search path, and the cache-key ingredients.
#[derive(Clone, Debug)]
pub struct ServiceSettings {
    /// The active rule selection.
    pub selection: RuleSelection,
    /// The safe-write validation level for `format` requests.
    pub level: ValidationLevel,
    /// The import search path handed to the worker.
    pub search_path: Vec<PathBuf>,
    /// The run-wide cache-key ingredients (per-file source digest is added per request).
    pub keys: CacheKeyBuilder,
}

/// One unit of work handed to the controller thread: a request and where to send its reply.
struct Job {
    request: ServiceRequest,
    reply: SyncSender<ServiceResponse>,
}

/// The controller-thread state: the sole owner of the worker plus the per-service bookkeeping.
struct Controller<P: SourceParser> {
    parser: P,
    settings: ServiceSettings,
    cache: FormatCache,
    served: u64,
    generation: u64,
    versions: HashMap<String, u64>,
}

impl<P: SourceParser> Controller<P> {
    /// Serve one request. This is the *only* place the worker is touched, and it runs on the
    /// single controller thread — so no two analyses ever overlap (the stop-rule guarantee).
    fn handle(&mut self, request: ServiceRequest) -> ServiceResponse {
        match request {
            ServiceRequest::Shutdown => ServiceResponse::ShuttingDown,
            ServiceRequest::Health => ServiceResponse::Health {
                served: self.served,
                worker_generation: self.generation,
            },
            ServiceRequest::Format { path, text, version } => self.analyze(path, &text, version, true),
            ServiceRequest::Check { path, text, version } => self.analyze(path, &text, version, false),
        }
    }

    fn analyze(&mut self, path: String, text: &str, version: Option<u64>, include_formatted: bool) -> ServiceResponse {
        if let Some(version) = version
            && let Some(&latest) = self.versions.get(&path)
            && version <= latest
        {
            return ServiceResponse::Stale { path, version, latest };
        }
        if let Some(version) = version {
            self.versions.insert(path.clone(), version);
        }
        self.served = self.served.saturating_add(1);

        let key = self.settings.keys.key_for(text);
        match analyze_file(
            &mut self.parser,
            &self.settings.selection,
            &path,
            text,
            self.settings.level,
            &self.settings.search_path,
            &self.cache,
            &key,
        ) {
            Ok(analysis) => response_from_analysis(analysis, include_formatted),
            Err(error) => ServiceResponse::Error {
                message: error.to_string(),
            },
        }
    }
}

/// Frame an [`analyze_file`] result as a [`ServiceResponse`]. `include_formatted` distinguishes
/// a `format` request (returns the new text) from a `check` request (reports only).
fn response_from_analysis(analysis: FileAnalysis, include_formatted: bool) -> ServiceResponse {
    let FileAnalysis {
        path,
        outcome,
        from_cache,
    } = analysis;
    match outcome {
        AnalysisOutcome::Broken { status: _, diagnostics } => ServiceResponse::Broken {
            path,
            diagnostics: diagnostics.iter().map(ParseFinding::from).collect(),
        },
        AnalysisOutcome::Analyzed {
            diagnostics,
            formatted,
            diff,
        } => {
            let changed = formatted.is_some();
            ServiceResponse::Analyzed {
                path,
                changed,
                formatted: if include_formatted { formatted } else { None },
                diff,
                findings: diagnostics,
                from_cache,
            }
        }
    }
}

/// A long-lived format service backed by a single worker-owning controller thread.
///
/// Construct it with [`FormatService::spawn`]; submit requests with [`FormatService::submit`]
/// (blocking) or [`FormatService::try_submit`] (bounded, returns [`ServiceResponse::Busy`]);
/// stop it with [`FormatService::shutdown`] or by dropping it (both end the controller thread
/// and, in turn, the worker session).
pub struct FormatService {
    tx: Option<SyncSender<Job>>,
    handle: Option<JoinHandle<()>>,
}

impl FormatService {
    /// Spawn the controller thread and return a handle to the running service.
    ///
    /// `make_parser` builds the worker *inside* the controller thread, so the worker (which
    /// need not be `Send`) is owned solely by that thread from birth. `capacity` bounds the
    /// request queue: past it, [`try_submit`](Self::try_submit) reports `busy`.
    ///
    /// # Errors
    /// Returns the message from `make_parser` if the worker cannot be constructed.
    pub fn spawn<P, F>(
        settings: ServiceSettings,
        cache: FormatCache,
        capacity: usize,
        make_parser: F,
    ) -> Result<Self, String>
    where
        P: SourceParser,
        F: FnOnce() -> Result<P, String> + Send + 'static,
    {
        let (tx, rx) = sync_channel::<Job>(capacity);
        let (ready_tx, ready_rx) = sync_channel::<Result<(), String>>(1);
        let handle = std::thread::spawn(move || {
            let parser = match make_parser() {
                Ok(parser) => parser,
                Err(error) => {
                    // Startup failed: report it and end the thread without serving.
                    ready_tx.send(Err(error)).ok();
                    return;
                }
            };
            ready_tx.send(Ok(())).ok();
            let mut controller = Controller {
                parser,
                settings,
                cache,
                served: 0,
                generation: 1,
                versions: HashMap::new(),
            };
            serve_loop(&mut controller, &rx);
            // `controller` (and its worker) drops here, ending the worker session cleanly.
        });

        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                tx: Some(tx),
                handle: Some(handle),
            }),
            Ok(Err(error)) => {
                handle.join().ok();
                Err(error)
            }
            Err(_) => {
                handle.join().ok();
                Err("format service controller thread died during startup".to_owned())
            }
        }
    }

    /// Submit a request and block until the controller replies. Waits for a queue slot if the
    /// bounded queue is momentarily full (use [`try_submit`](Self::try_submit) to fail fast).
    ///
    /// Returns [`ServiceResponse::Error`] if the controller thread is gone.
    #[must_use]
    pub fn submit(&self, request: ServiceRequest) -> ServiceResponse {
        let (reply_tx, reply_rx) = sync_channel::<ServiceResponse>(1);
        let job = Job {
            request,
            reply: reply_tx,
        };
        match self.tx.as_ref() {
            Some(tx) => match tx.send(job) {
                Ok(()) => reply_rx.recv().unwrap_or_else(|_| Self::gone()),
                Err(_) => Self::gone(),
            },
            None => Self::gone(),
        }
    }

    /// Submit a request without blocking on a full queue: returns [`ServiceResponse::Busy`]
    /// immediately if no queue slot is free, turning overload into a retryable signal rather
    /// than unbounded memory growth.
    ///
    /// Returns [`ServiceResponse::Error`] if the controller thread is gone.
    #[must_use]
    pub fn try_submit(&self, request: ServiceRequest) -> ServiceResponse {
        let (reply_tx, reply_rx) = sync_channel::<ServiceResponse>(1);
        let job = Job {
            request,
            reply: reply_tx,
        };
        match self.tx.as_ref() {
            Some(tx) => match tx.try_send(job) {
                Ok(()) => reply_rx.recv().unwrap_or_else(|_| Self::gone()),
                Err(TrySendError::Full(_)) => ServiceResponse::Busy,
                Err(TrySendError::Disconnected(_)) => Self::gone(),
            },
            None => Self::gone(),
        }
    }

    /// Stop the service: drop the sender so the controller loop ends, then join the thread so
    /// the worker session is fully torn down before returning.
    pub fn shutdown(mut self) {
        self.stop();
    }

    /// Drop the sender (ending the controller loop) and join the controller thread.
    fn stop(&mut self) {
        drop(self.tx.take());
        if let Some(handle) = self.handle.take() {
            handle.join().ok();
        }
    }

    fn gone() -> ServiceResponse {
        ServiceResponse::Error {
            message: "format service is not running".to_owned(),
        }
    }
}

impl Drop for FormatService {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The controller loop: serve jobs FIFO until a shutdown reply or a dropped sender ends it.
fn serve_loop<P: SourceParser>(controller: &mut Controller<P>, rx: &Receiver<Job>) {
    while let Ok(job) = rx.recv() {
        let response = controller.handle(job.request);
        let stopping = matches!(response, ServiceResponse::ShuttingDown);
        job.reply.send(response).ok();
        if stopping {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use lean_fmt_diagnostics::RuleSelection;
    use lean_fmt_edit::TextRange;
    use lean_fmt_worker::{
        ModuleHeader, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary, ValidateResponse, WorkerError,
    };
    use tempfile::TempDir;

    use super::{FormatService, ServiceRequest, ServiceResponse, ServiceSettings};
    use crate::cache::FormatCache;
    use crate::config::FormatterConfig;
    use crate::run::CacheKeyBuilder;
    use crate::validate::ValidationLevel;

    /// A stub parser that (a) flags any overlapping call — proving single-flight — and (b)
    /// returns a fixed clean/dirty parse response.
    struct StubWorker {
        response: ParseFileResponse,
        in_flight: Arc<AtomicUsize>,
        max_seen: Arc<AtomicUsize>,
    }

    impl StubWorker {
        fn ok(trivia: Vec<TextRange>) -> ParseFileResponse {
            ParseFileResponse {
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
                    trivia_runs: trivia,
                    docstrings: Vec::new(),
                },
            }
        }

        fn dirty(trivia: Vec<TextRange>, max_seen: Arc<AtomicUsize>) -> Self {
            Self {
                response: Self::ok(trivia),
                in_flight: Arc::new(AtomicUsize::new(0)),
                max_seen,
            }
        }

        fn enter(&self) {
            let now = self.in_flight.fetch_add(1, Ordering::SeqCst).saturating_add(1);
            // Record the peak concurrency ever observed inside a worker call.
            self.max_seen.fetch_max(now, Ordering::SeqCst);
            // A tiny spin so overlapping calls, if any were possible, would actually overlap.
            for _ in 0..1000 {
                std::hint::spin_loop();
            }
            self.in_flight.fetch_sub(1, Ordering::SeqCst);
        }
    }

    impl super::SourceParser for StubWorker {
        fn parse_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            self.enter();
            Ok(self.response.clone())
        }

        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            Ok(ValidateResponse {
                valid: true,
                diagnostics: Vec::new(),
                diagnostics_truncated: false,
            })
        }
    }

    fn settings() -> ServiceSettings {
        ServiceSettings {
            selection: RuleSelection::new(
                vec!["text/trailing-whitespace".to_owned()],
                Vec::new(),
                Vec::new(),
                Vec::new(),
                BTreeMap::new(),
            ),
            level: ValidationLevel::Syntax,
            search_path: Vec::new(),
            keys: CacheKeyBuilder::new(
                &FormatterConfig::default(),
                "0.1.0",
                "tc",
                "rt",
                ValidationLevel::Syntax,
            ),
        }
    }

    fn spawn_service(max_seen: Arc<AtomicUsize>, capacity: usize) -> (FormatService, TempDir) {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        // Trailing whitespace at 10..12 lives in the trivia run 10..13.
        let service = FormatService::spawn(settings(), cache, capacity, move || {
            Ok(StubWorker::dirty(vec![TextRange::new(10, 13)], max_seen))
        })
        .unwrap();
        (service, dir)
    }

    #[test]
    fn format_request_returns_formatted_text() {
        let (service, _dir) = spawn_service(Arc::new(AtomicUsize::new(0)), 8);
        let response = service.submit(ServiceRequest::Format {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: None,
        });
        let ServiceResponse::Analyzed { changed, formatted, .. } = response else {
            panic!("expected an analyzed response, got {response:?}");
        };
        assert!(changed, "the dirty file would change");
        assert_eq!(formatted.as_deref(), Some("def a := 1\n"), "trailing spaces stripped");
    }

    #[test]
    fn check_request_reports_without_returning_formatted_text() {
        let (service, _dir) = spawn_service(Arc::new(AtomicUsize::new(0)), 8);
        let response = service.submit(ServiceRequest::Check {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: None,
        });
        let ServiceResponse::Analyzed { changed, formatted, .. } = response else {
            panic!("expected an analyzed response, got {response:?}");
        };
        assert!(changed, "check still reports that the file would change");
        assert!(formatted.is_none(), "check does not return formatted text");
    }

    #[test]
    fn concurrent_requests_never_overlap_in_the_worker() {
        let max_seen = Arc::new(AtomicUsize::new(0));
        let (service, _dir) = spawn_service(Arc::clone(&max_seen), 64);
        let service = Arc::new(service);

        // Fire many requests from many threads at once; every one is served by the single
        // controller thread, so the worker never sees two calls in flight.
        let mut handles = Vec::new();
        for index in 0..16 {
            let service = Arc::clone(&service);
            handles.push(std::thread::spawn(move || {
                service.submit(ServiceRequest::Format {
                    path: format!("F{index}.lean"),
                    text: "def a := 1  \n".to_owned(),
                    version: None,
                })
            }));
        }
        for handle in handles {
            let response = handle.join().unwrap();
            assert!(matches!(response, ServiceResponse::Analyzed { .. }));
        }
        assert_eq!(
            max_seen.load(Ordering::SeqCst),
            1,
            "the worker was never touched by two requests at once"
        );
    }

    #[test]
    fn a_stale_version_is_rejected() {
        let (service, _dir) = spawn_service(Arc::new(AtomicUsize::new(0)), 8);
        // Version 5 lands first.
        let first = service.submit(ServiceRequest::Format {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: Some(5),
        });
        assert!(matches!(first, ServiceResponse::Analyzed { .. }));
        // A later request for an older version 3 is dropped as stale.
        let stale = service.submit(ServiceRequest::Format {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: Some(3),
        });
        let ServiceResponse::Stale { version, latest, .. } = stale else {
            panic!("expected a stale response, got {stale:?}");
        };
        assert_eq!(version, 3);
        assert_eq!(latest, 5);
        // A newer version 6 is accepted again.
        let newer = service.submit(ServiceRequest::Format {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: Some(6),
        });
        assert!(matches!(newer, ServiceResponse::Analyzed { .. }));
    }

    #[test]
    fn health_reports_requests_served_without_touching_the_worker() {
        let max_seen = Arc::new(AtomicUsize::new(0));
        let (service, _dir) = spawn_service(Arc::clone(&max_seen), 8);
        let _served = service.submit(ServiceRequest::Check {
            path: "A.lean".to_owned(),
            text: "def a := 1  \n".to_owned(),
            version: None,
        });
        let health = service.submit(ServiceRequest::Health);
        let ServiceResponse::Health {
            served,
            worker_generation,
        } = health
        else {
            panic!("expected a health response, got {health:?}");
        };
        assert_eq!(served, 1, "one analysis request was served");
        assert_eq!(worker_generation, 1);
    }

    #[test]
    fn shutdown_stops_the_service_gracefully() {
        let (service, _dir) = spawn_service(Arc::new(AtomicUsize::new(0)), 8);
        assert!(matches!(
            service.submit(ServiceRequest::Shutdown),
            ServiceResponse::ShuttingDown
        ));
        // After a shutdown reply, the controller has stopped: further requests find it gone.
        assert!(matches!(
            service.submit(ServiceRequest::Health),
            ServiceResponse::Error { .. }
        ));
        service.shutdown();
    }

    #[test]
    fn a_startup_failure_is_reported() {
        let dir = TempDir::new().unwrap();
        let cache = FormatCache::disabled(dir.path().join("cache"));
        let result =
            FormatService::spawn::<StubWorker, _>(settings(), cache, 8, || Err("no worker installed".to_owned()));
        assert_eq!(result.err().as_deref(), Some("no worker installed"));
    }
}
