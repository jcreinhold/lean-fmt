//! Parallel project execution: fan [`process_one_file`] out across a fleet of independent
//! worker children, one per OS thread.
//!
//! The serial [`run_project`](crate::run_project) drives every file through one warm worker,
//! `&mut self`-serialized. That is deterministic and simple, but single-threaded — a cold pass
//! over a large library pays each file's ~200 ms–1 s Lean import cost strictly one at a time.
//! Because the underlying worker pool's lease mutably borrows the pool (one live lease per
//! pool) and the worker is not `Send`, true parallelism means **N independent workers = N child
//! processes**, each built and owned inside its own thread. This module is that scheduler.
//!
//! It hides one volatile decision — *how the batch is spread across resources* — behind the same
//! `files -> ProjectRun` contract the serial path already honors. Three properties carry over
//! unchanged and are tested:
//!
//! - **Deterministic order** — work is claimed out of order off a shared cursor, but each report
//!   is tagged with its file's path-sorted index and the results are re-sorted before returning,
//!   so the output is byte-identical to the serial path regardless of completion order.
//! - **Partial-failure survival** — a per-file failure is a [`FileReport::Failed`] (via
//!   [`process_one_file`]); a worker that fails to *start* simply processes no files and its peers
//!   drain the cursor. Only when no worker can start at all does the run return an error.
//! - **No shared mutable worker** — each thread constructs and solely owns its worker (the
//!   [`FormatService`](crate::FormatService) pattern), so nothing crosses the non-`Send` boundary.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use lean_fmt_diagnostics::RuleSelection;

use crate::analyze::SourceParser;
use crate::cache::FormatCache;
use crate::run::{CacheKeyBuilder, FileReport, ProjectRun, RunMode, process_one_file};
use crate::validate::ValidationLevel;
use crate::workspace::SourceFile;

/// How to spread a run across worker children.
///
/// `jobs` is the number of parallel workers, already resolved from the resource budget and any
/// `-j`/`--jobs` override by the caller (see `LeanResourceBudget::worker_count`); the fleet
/// floors it at 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FleetPlan {
    /// The number of parallel worker children to run.
    pub jobs: usize,
}

/// Drive [`process_one_file`] across `files` using `plan.jobs` independent workers.
///
/// `make_parser` builds one worker; it is invoked once per thread so each worker is constructed
/// and owned inside the thread that uses it (never moved across the non-`Send` boundary), and it
/// encapsulates any per-worker setup — pinning the superset environment, for instance — so the
/// fleet stays ignorant of parse strategy. With `plan.jobs <= 1` the run stays on a single
/// worker in the calling thread. `progress` is called once per completed file with
/// `(files_done, total, path)` — the running completion count, the file total, and the path of
/// the file just finished — from whichever worker finished it.
///
/// # Errors
///
/// Returns the first worker startup error only when *no* worker could be started (so no file was
/// processed). A worker that starts and then hits a per-file problem does not error the run — that
/// file becomes a [`FileReport::Failed`] and the run continues.
#[allow(clippy::too_many_arguments)]
pub fn run_project_fleet<P, M>(
    make_parser: M,
    mode: RunMode,
    files: &[SourceFile],
    selection: &RuleSelection,
    keys: &CacheKeyBuilder,
    level: ValidationLevel,
    search_path: &[PathBuf],
    cache: &FormatCache,
    plan: FleetPlan,
    progress: impl Fn(usize, usize, &str) + Sync,
) -> Result<ProjectRun, String>
where
    P: SourceParser,
    M: Fn() -> Result<P, String> + Sync,
{
    // Deterministic base order: every report is tagged with its index here and the results are
    // re-sorted by it before returning, so completion order never leaks into the output.
    let mut ordered: Vec<&SourceFile> = files.iter().collect();
    ordered.sort_by(|left, right| left.path.cmp(&right.path));
    let total = ordered.len();

    let jobs = plan.jobs.max(1);
    if jobs <= 1 || total <= 1 {
        // One worker: no threads, no scheduling — the single-file body run serially. Byte
        // identical to the fleet path (same `process_one_file`, same order), just cheaper.
        let mut parser = make_parser()?;
        let mut reports = Vec::with_capacity(total);
        for (index, file) in ordered.iter().enumerate() {
            let report = process_one_file(&mut parser, mode, file, selection, keys, level, search_path, cache);
            progress(index.saturating_add(1), total, report.path());
            reports.push(report);
        }
        return Ok(ProjectRun { mode, reports });
    }

    let cursor = AtomicUsize::new(0);
    let done = AtomicUsize::new(0);
    // Share every worker-visible value by reference; each spawned closure `move`s only these
    // `Copy` references in, never the atomics or borrowed inputs themselves.
    let cursor = &cursor;
    let done = &done;
    let ordered = &ordered;
    let progress = &progress;
    let make_parser = &make_parser;

    // Each worker: build its own parser, then claim indices off the shared cursor until the list
    // is exhausted. A self-balancing queue — a worker stuck on a cold import does not hold back
    // the others, and a worker that never starts simply claims nothing.
    let outcomes: Vec<WorkerOutcome> = std::thread::scope(|scope| {
        // Collect every handle *before* joining any: spawning must complete up front so the
        // workers run concurrently. A spawn→join chain (no `collect`) would join each worker
        // before spawning the next, serializing the whole fleet — so this collect is load-bearing.
        #[allow(clippy::needless_collect)]
        let handles: Vec<_> = (0..jobs)
            .map(|_| {
                scope.spawn(move || {
                    let mut parser = match make_parser() {
                        Ok(parser) => parser,
                        Err(error) => return WorkerOutcome::startup_failed(error),
                    };
                    let mut local: Vec<(usize, FileReport)> = Vec::new();
                    loop {
                        let index = cursor.fetch_add(1, Ordering::Relaxed);
                        let Some(file) = ordered.get(index) else { break };
                        let report =
                            process_one_file(&mut parser, mode, file, selection, keys, level, search_path, cache);
                        let completed = done.fetch_add(1, Ordering::Relaxed).saturating_add(1);
                        progress(completed, total, report.path());
                        local.push((index, report));
                    }
                    WorkerOutcome::completed(local)
                })
            })
            .collect();
        // A worker thread never panics (per-file failures are captured, not unwound); treat a
        // join error defensively as a worker that produced nothing.
        handles
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .unwrap_or_else(|_| WorkerOutcome::startup_failed("worker thread panicked".to_owned()))
            })
            .collect()
    });

    let mut tagged: Vec<(usize, FileReport)> = Vec::with_capacity(total);
    let mut first_error: Option<String> = None;
    for outcome in outcomes {
        match outcome {
            WorkerOutcome::Completed(reports) => tagged.extend(reports),
            WorkerOutcome::StartupFailed(error) => {
                first_error.get_or_insert(error);
            }
        }
    }

    // No file processed at all means every worker failed to start — surface why. If even one
    // worker started, it drained the whole cursor, so a startup failure in the others cost only
    // parallelism, not coverage, and is not an error.
    if tagged.is_empty() && total > 0 {
        return Err(first_error.unwrap_or_else(|| "no worker could be started".to_owned()));
    }

    tagged.sort_by_key(|(index, _)| *index);
    let reports = tagged.into_iter().map(|(_, report)| report).collect();
    Ok(ProjectRun { mode, reports })
}

/// What one worker thread produced: either the index-tagged reports it completed, or a startup
/// error meaning it built no parser and processed nothing.
enum WorkerOutcome {
    Completed(Vec<(usize, FileReport)>),
    StartupFailed(String),
}

impl WorkerOutcome {
    fn completed(reports: Vec<(usize, FileReport)>) -> Self {
        Self::Completed(reports)
    }

    fn startup_failed(error: String) -> Self {
        Self::StartupFailed(error)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use lean_fmt_diagnostics::RuleSelection;
    use lean_fmt_worker::{
        ModuleHeader, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary, ValidateResponse, WorkerError,
    };
    use tempfile::TempDir;

    use super::{FleetPlan, run_project_fleet};
    use crate::analyze::SourceParser;
    use crate::cache::FormatCache;
    use crate::config::FormatterConfig;
    use crate::run::{CacheKeyBuilder, FileReport, RunMode, run_project};
    use crate::validate::ValidationLevel;
    use crate::workspace::SourceFile;

    fn empty_header() -> ModuleHeader {
        ModuleHeader {
            imports: Vec::new(),
            is_module: false,
            import_spans: Vec::new(),
        }
    }

    fn empty_summary() -> SyntaxSummary {
        SyntaxSummary {
            command_count: 0,
            command_kinds: Vec::new(),
            command_regions: Vec::new(),
            declaration_headers: Vec::new(),
            tactic_blocks: Vec::new(),
        }
    }

    /// A worker stub that parses every file to a clean, unchanged model and records how many
    /// files it saw. Optional jitter perturbs completion order to prove the sort restores it.
    struct StubWorker {
        seen: usize,
        jitter: bool,
    }

    impl SourceParser for StubWorker {
        fn parse_source(
            &mut self,
            _file: &str,
            source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            self.seen = self.seen.saturating_add(1);
            if self.jitter {
                // Vary per-file cost so workers finish interleaved, not in claim order.
                let jitter_ms = u64::from(u8::try_from(source.len() % 5).unwrap_or(0));
                std::thread::sleep(std::time::Duration::from_millis(jitter_ms));
            }
            Ok(clean_response())
        }

        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            Ok(valid_response())
        }
    }

    fn clean_response() -> ParseFileResponse {
        ParseFileResponse {
            status: ParseStatus::Ok,
            diagnostics: Vec::new(),
            diagnostics_truncated: false,
            module_header: empty_header(),
            syntax_summary: empty_summary(),
            source_model: SourceModel::default(),
            fell_back: false,
        }
    }

    fn valid_response() -> ValidateResponse {
        ValidateResponse {
            valid: true,
            diagnostics: Vec::new(),
            diagnostics_truncated: false,
        }
    }

    /// An empty rule selection: no rule fires, so every file is analyzed clean and unchanged —
    /// enough to exercise scheduling, ordering, and counting without rule-specific output.
    fn empty_selection() -> RuleSelection {
        RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new())
    }

    fn write_corpus(dir: &TempDir, count: usize) -> Vec<SourceFile> {
        (0..count)
            .map(|index| {
                let path = dir.path().join(format!("File{index:03}.lean"));
                // Distinct content per file so the jitter sleep varies and digests differ.
                std::fs::write(&path, format!("-- file {index}\n{}\n", "x".repeat(index % 7))).unwrap();
                SourceFile {
                    module: format!("File{index:03}"),
                    path,
                }
            })
            .collect()
    }

    fn keys() -> CacheKeyBuilder {
        CacheKeyBuilder::new(
            &FormatterConfig::default(),
            "test-version",
            "test-toolchain",
            "test-runtime",
            ValidationLevel::Syntax,
            None,
        )
    }

    #[test]
    fn fleet_matches_serial_output_byte_for_byte() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 40);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();

        let mut serial_worker = StubWorker { seen: 0, jitter: false };
        let serial = run_project(
            &mut serial_worker,
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            |_| {},
        );

        let parallel = run_project_fleet(
            || Ok::<_, String>(StubWorker { seen: 0, jitter: true }),
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 4 },
            |_, _, _| {},
        )
        .expect("fleet run should succeed");

        assert_eq!(
            serial.reports, parallel.reports,
            "parallel output must equal serial output"
        );
    }

    #[test]
    fn fleet_processes_every_file_exactly_once() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 50);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();
        let total_seen = AtomicUsize::new(0);

        let run = run_project_fleet(
            || Ok::<_, String>(CountingWorker { seen: &total_seen }),
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 8 },
            |_, _, _| {},
        )
        .expect("fleet run should succeed");

        assert_eq!(run.reports.len(), 50);
        assert_eq!(total_seen.load(Ordering::Relaxed), 50, "each file parsed exactly once");
        // Reports are path-sorted regardless of which worker finished them.
        let paths: Vec<&str> = run.reports.iter().map(FileReport::path).collect();
        let mut sorted = paths.clone();
        sorted.sort_unstable();
        assert_eq!(paths, sorted, "reports must be in path-sorted order");
    }

    /// A worker sharing one atomic counter across all threads, to prove no file is double-counted
    /// or dropped under contention.
    struct CountingWorker<'a> {
        seen: &'a AtomicUsize,
    }

    impl SourceParser for CountingWorker<'_> {
        fn parse_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            self.seen.fetch_add(1, Ordering::Relaxed);
            Ok(clean_response())
        }

        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            Ok(valid_response())
        }
    }

    #[test]
    fn one_worker_startup_failure_is_covered_by_peers() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 30);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();

        // The first worker to try to start fails; every later one succeeds. The run must still
        // process all 30 files (the survivors drain the cursor).
        let attempts = AtomicUsize::new(0);
        let run = run_project_fleet(
            || {
                if attempts.fetch_add(1, Ordering::Relaxed) == 0 {
                    Err("simulated startup failure".to_owned())
                } else {
                    Ok(StubWorker { seen: 0, jitter: false })
                }
            },
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 4 },
            |_, _, _| {},
        )
        .expect("run should survive one worker failing to start");
        assert_eq!(run.reports.len(), 30);
    }

    #[test]
    fn all_workers_failing_to_start_is_an_error() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 10);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();

        let result = run_project_fleet(
            || Err::<StubWorker, _>("cannot start".to_owned()),
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 4 },
            |_, _, _| {},
        );
        assert!(result.is_err(), "a run where no worker starts must be an error");
    }

    #[test]
    fn progress_is_called_once_per_file() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 25);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();
        let seen_totals = Mutex::new(Vec::new());

        let run = run_project_fleet(
            || Ok::<_, String>(StubWorker { seen: 0, jitter: true }),
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 4 },
            |done, total, _path| {
                assert_eq!(total, 25);
                seen_totals.lock().unwrap().push(done);
            },
        )
        .expect("fleet run should succeed");

        assert_eq!(run.reports.len(), 25);
        let mut progress_counts = seen_totals.into_inner().unwrap();
        assert_eq!(progress_counts.len(), 25, "progress fires exactly once per file");
        progress_counts.sort_unstable();
        assert_eq!(
            progress_counts,
            (1..=25).collect::<Vec<_>>(),
            "each completion count is distinct"
        );
    }

    #[test]
    fn single_job_matches_serial() {
        let dir = TempDir::new().unwrap();
        let files = write_corpus(&dir, 12);
        let cache = FormatCache::disabled(dir.path().join(".cache"));
        let selection = empty_selection();
        let keys = keys();
        let search = Vec::new();

        let mut serial_worker = StubWorker { seen: 0, jitter: false };
        let serial = run_project(
            &mut serial_worker,
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            |_| {},
        );

        let single = run_project_fleet(
            || Ok::<_, String>(StubWorker { seen: 0, jitter: false }),
            RunMode::Check,
            &files,
            &selection,
            &keys,
            ValidationLevel::Syntax,
            &search,
            &cache,
            FleetPlan { jobs: 1 },
            |_, _, _| {},
        )
        .expect("single-job fleet run should succeed");

        assert_eq!(serial.reports, single.reports);
    }
}
