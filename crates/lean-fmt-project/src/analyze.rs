//! The single-file analysis engine: everything the three project modes need for one file.
//!
//! [`analyze_file`] is the reusable driver that prompt 27's project orchestration runs
//! across a workspace. It wires the already-built pieces into one pass:
//!
//! 1. consult the [`FormatCache`] — a hit skips parse *and* analysis entirely;
//! 2. parse the source through the warm worker ([`SourceParser`]);
//! 3. build a [`RuleContext`] from the parse response and run the active rules
//!    ([`check`](lean_fmt_diagnostics::check));
//! 4. merge each finding's fix into one conflict-checked [`EditSet`];
//! 5. produce the formatted output by applying that edit set through the safe-write gate
//!    ([`safe_apply`]) at the requested [`ValidationLevel`], and render the unified diff;
//! 6. store the result in the cache.
//!
//! It introduces no new rule and no new Lean surface — it is pure orchestration over
//! `lean-fmt-diagnostics`, `lean-fmt-edit`, `lean-fmt-worker`, and this crate's own
//! [`safe_apply`]/[`FormatCache`].
//!
//! **Conservative by design.** A file that does not parse cleanly ([`ParseStatus::Ok`]) is
//! reported as [`AnalysisOutcome::Broken`] and never formatted. If a fix set fails the
//! safe-write gate (overlapping fixes, or an edit that breaks the file), the findings are
//! still reported but **no** formatted output is emitted — a wrong merge is never written.
//! Multi-rule fix-conflict *resolution* (ordering/priority) is deferred to its own prompt.

use std::path::PathBuf;

use lean_fmt_diagnostics::{RuleContext, RuleSelection, check};
use lean_fmt_edit::{Diagnostic, EditSet, unified_diff};
use lean_fmt_worker::{
    FormatterWorker, ParseDiagnostic, ParseFileResponse, ParseStatus, ValidateResponse, WorkerError,
};

use crate::cache::{CacheKey, CacheLookup, FormatCache};
use crate::error::Error;
use crate::validate::{ValidationLevel, ValidationOutcome, safe_apply};

/// The parse capability [`analyze_file`] needs, as a trait so the engine is unit-testable
/// with a stub and driven by the real warm [`FormatterWorker`] in production.
///
/// Both methods mirror the worker's own `parse_file`/`validate`: the first re-parses a
/// snapshot, the second parses *and* elaborates it (the [`ValidationLevel::Elab`] gate).
pub trait SourceParser {
    /// Parse `source` (labelled `file`), resolving imports against `search_path`.
    ///
    /// # Errors
    /// Returns a [`WorkerError`] if the worker cannot be reached or the request fails.
    fn parse_source(
        &mut self,
        file: &str,
        source: &str,
        search_path: &[PathBuf],
    ) -> Result<ParseFileResponse, WorkerError>;

    /// Parse *and elaborate* `source`, for the stricter [`ValidationLevel::Elab`] gate.
    ///
    /// # Errors
    /// Returns a [`WorkerError`] if the worker cannot be reached or the request fails.
    fn validate_source(
        &mut self,
        file: &str,
        source: &str,
        search_path: &[PathBuf],
    ) -> Result<ValidateResponse, WorkerError>;
}

impl SourceParser for FormatterWorker {
    fn parse_source(
        &mut self,
        file: &str,
        source: &str,
        search_path: &[PathBuf],
    ) -> Result<ParseFileResponse, WorkerError> {
        self.parse_file(file, source, search_path)
    }

    fn validate_source(
        &mut self,
        file: &str,
        source: &str,
        search_path: &[PathBuf],
    ) -> Result<ValidateResponse, WorkerError> {
        self.validate(file, source, search_path)
    }
}

/// The full analysis of one file: its outcome plus whether it came from the cache.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileAnalysis {
    /// The root-relative path analyzed.
    pub path: String,
    /// What the analysis found.
    pub outcome: AnalysisOutcome,
    /// Whether this analysis was served from the cache rather than freshly computed.
    pub from_cache: bool,
}

/// What analyzing one file produced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AnalysisOutcome {
    /// The file did not parse cleanly, so it was not formatted; the parse diagnostics say
    /// why. Never cached — a broken file is recomputed every run until it is fixed.
    Broken {
        /// The non-`Ok` parse status (`Degraded` or `Error`).
        status: ParseStatus,
        /// The parse diagnostics reported by the worker.
        diagnostics: Vec<ParseDiagnostic>,
    },
    /// The file parsed and was analyzed.
    Analyzed {
        /// The rule findings (empty for an already-clean file).
        diagnostics: Vec<Diagnostic>,
        /// The formatted text, when fixes applied cleanly through the safe-write gate and
        /// changed the source. `None` when there were no fixes, the fixes were a no-op, or
        /// the fix set failed the gate (findings are still reported).
        formatted: Option<String>,
        /// The unified diff from the source to `formatted`, when there is one.
        diff: Option<String>,
    },
}

/// The cached payload for an [`AnalysisOutcome::Analyzed`] file. Only analyzed files are
/// cached; the diff is recomputed on read (it is a pure function of source and `formatted`).
#[derive(serde::Serialize, serde::Deserialize)]
struct CachedAnalysis {
    diagnostics: Vec<Diagnostic>,
    formatted: Option<String>,
}

/// Why [`analyze_file`] could not complete. Distinct from a *reported* broken file — this
/// is an infrastructure failure (worker transport or cache write), not a finding.
#[derive(Debug, thiserror::Error)]
pub enum AnalyzeError {
    /// The worker could not be reached or a request failed.
    #[error("worker failed while analyzing {path}: {source}")]
    Worker {
        /// The file being analyzed when the worker failed.
        path: String,
        /// The underlying worker error.
        source: WorkerError,
    },
    /// The analysis succeeded but could not be written to the cache.
    #[error(transparent)]
    Cache(#[from] Error),
}

/// Analyze one file end-to-end, returning everything the check/fix/diff modes need.
///
/// `key` is the [`CacheKey`] guarding this file's cached result (built by the caller from
/// the semantic inputs). A cache hit returns the stored analysis without touching the
/// worker; a miss parses, runs the active `selection` of rules, formats through the
/// safe-write gate at `level`, and stores the result. `search_path` is the import search
/// path passed to the worker.
///
/// # Errors
///
/// Returns [`AnalyzeError::Worker`] if the worker cannot be reached, or
/// [`AnalyzeError::Cache`] if the freshly computed analysis cannot be cached. A file that
/// merely fails to parse is **not** an error — it is a reported [`AnalysisOutcome::Broken`].
pub fn analyze_file<P: SourceParser>(
    parser: &mut P,
    selection: &RuleSelection,
    path: &str,
    source: &str,
    level: ValidationLevel,
    search_path: &[PathBuf],
    cache: &FormatCache,
    key: &CacheKey,
) -> Result<FileAnalysis, AnalyzeError> {
    // 1. Cache hit: reconstruct the analysis without parsing or re-running rules.
    if let CacheLookup::Hit(cached) = cache.lookup::<CachedAnalysis>(path, key) {
        let diff = diff_of(source, cached.formatted.as_deref(), path);
        return Ok(FileAnalysis {
            path: path.to_owned(),
            outcome: AnalysisOutcome::Analyzed {
                diagnostics: cached.diagnostics,
                formatted: cached.formatted,
                diff,
            },
            from_cache: true,
        });
    }

    // 2. Parse. A file that does not parse cleanly is reported, never formatted or cached.
    let response = parser
        .parse_source(path, source, search_path)
        .map_err(|source| AnalyzeError::Worker {
            path: path.to_owned(),
            source,
        })?;
    if response.status != ParseStatus::Ok {
        return Ok(FileAnalysis {
            path: path.to_owned(),
            outcome: AnalysisOutcome::Broken {
                status: response.status,
                diagnostics: response.diagnostics,
            },
            from_cache: false,
        });
    }

    // 3. Run the active rules over the parsed model.
    let diagnostics = {
        let ctx = RuleContext::new(source, path, &response.source_model.trivia_runs)
            .with_imports(&response.module_header.import_spans)
            .with_regions(&response.syntax_summary.command_regions)
            .with_decls(&response.syntax_summary.declaration_headers)
            .with_tactics(&response.syntax_summary.tactic_blocks);
        check(&ctx, selection)
    };

    // 4. Merge every finding's fix into one conflict-checked edit set.
    let merged = merge_fixes(&diagnostics);

    // 5. Format through the safe-write gate. A no-op fix or a gate rejection yields no
    //    formatted output — the findings are still reported, but nothing wrong is emitted.
    let formatted = if merged.edits.is_empty() {
        None
    } else {
        let mut transport: Option<WorkerError> = None;
        let applied = safe_apply(source, &merged, level, |patched| {
            let outcome = match level {
                ValidationLevel::Elab => parser
                    .validate_source(path, patched, search_path)
                    .map(ValidationOutcome::from),
                ValidationLevel::None | ValidationLevel::Syntax => parser
                    .parse_source(path, patched, search_path)
                    .map(ValidationOutcome::from),
            };
            match outcome {
                Ok(outcome) => outcome,
                Err(error) => {
                    transport = Some(error);
                    ValidationOutcome {
                        accepted: false,
                        diagnostics: Vec::new(),
                    }
                }
            }
        });
        if let Some(source) = transport {
            return Err(AnalyzeError::Worker {
                path: path.to_owned(),
                source,
            });
        }
        match applied {
            // The gate accepted a fix that actually changed the file.
            Ok(output) if output != source => Some(output),
            // A no-op fix (edits cancelled out) — nothing to write.
            Ok(_) => None,
            // The gate rejected the fix set (overlap or a break): report findings, emit
            // no formatted output. Never write a wrong merge.
            Err(_) => None,
        }
    };

    let diff = diff_of(source, formatted.as_deref(), path);

    // 6. Cache the analyzed result.
    cache.store(
        path,
        key,
        CachedAnalysis {
            diagnostics: diagnostics.clone(),
            formatted: formatted.clone(),
        },
    )?;

    Ok(FileAnalysis {
        path: path.to_owned(),
        outcome: AnalysisOutcome::Analyzed {
            diagnostics,
            formatted,
            diff,
        },
        from_cache: false,
    })
}

/// The unified diff from `source` to `formatted`, or `None` when there is no change.
fn diff_of(source: &str, formatted: Option<&str>, path: &str) -> Option<String> {
    let formatted = formatted?;
    let diff = unified_diff(source, formatted, path);
    if diff.is_empty() { None } else { Some(diff) }
}

/// Concatenate every finding's fix into one [`EditSet`]. Application ([`EditSet::apply`],
/// via [`safe_apply`]) sorts and conflict-checks the result, so overlapping fixes from
/// different rules are rejected there rather than silently merged.
fn merge_fixes(diagnostics: &[Diagnostic]) -> EditSet {
    let mut edits = Vec::new();
    for diagnostic in diagnostics {
        if let Some(fix) = &diagnostic.fix {
            edits.extend(fix.edits.iter().cloned());
        }
    }
    EditSet { edits }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::collections::BTreeMap;

    use lean_fmt_worker::{ModuleHeader, SourceModel, SyntaxSummary};

    use super::{
        AnalysisOutcome, ParseDiagnostic, ParseFileResponse, ParseStatus, SourceParser, ValidateResponse, WorkerError,
        analyze_file,
    };
    use crate::cache::{CacheKey, FormatCache};
    use crate::validate::ValidationLevel;
    use lean_fmt_diagnostics::RuleSelection;
    use lean_fmt_edit::TextRange;

    /// An all-empty module header (no imports, not a `module` header).
    fn empty_header() -> ModuleHeader {
        ModuleHeader {
            imports: Vec::new(),
            is_module: false,
            import_spans: Vec::new(),
        }
    }

    /// An all-empty syntax summary (no commands parsed).
    fn empty_summary() -> SyntaxSummary {
        SyntaxSummary {
            command_count: 0,
            command_kinds: Vec::new(),
            command_regions: Vec::new(),
            declaration_headers: Vec::new(),
            tactic_blocks: Vec::new(),
        }
    }

    /// A stub worker returning a fixed parse response, counting how often it was called.
    struct StubWorker {
        response: ParseFileResponse,
        parse_calls: usize,
    }

    impl StubWorker {
        fn ok_with_trivia(trivia: Vec<TextRange>) -> Self {
            Self {
                response: ParseFileResponse {
                    status: ParseStatus::Ok,
                    diagnostics: Vec::new(),
                    diagnostics_truncated: false,
                    module_header: empty_header(),
                    syntax_summary: empty_summary(),
                    source_model: SourceModel {
                        trivia_runs: trivia,
                        docstrings: Vec::new(),
                    },
                },
                parse_calls: 0,
            }
        }

        fn broken() -> Self {
            let mut response = ParseFileResponse {
                status: ParseStatus::Error,
                diagnostics: vec![ParseDiagnostic {
                    severity: "error".to_owned(),
                    message: "unexpected token".to_owned(),
                    file: "<snapshot>".to_owned(),
                    line: 1,
                    column: 0,
                    end_line: None,
                    end_column: None,
                }],
                diagnostics_truncated: false,
                module_header: empty_header(),
                syntax_summary: empty_summary(),
                source_model: SourceModel::default(),
            };
            response.status = ParseStatus::Error;
            Self {
                response,
                parse_calls: 0,
            }
        }
    }

    impl SourceParser for StubWorker {
        fn parse_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[std::path::PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            self.parse_calls = self.parse_calls.saturating_add(1);
            Ok(self.response.clone())
        }

        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[std::path::PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            Ok(ValidateResponse {
                valid: true,
                diagnostics: Vec::new(),
                diagnostics_truncated: false,
            })
        }
    }

    /// A worker that panics if asked to parse — proves a cache hit never touches it.
    struct PanicWorker;
    impl SourceParser for PanicWorker {
        fn parse_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[std::path::PathBuf],
        ) -> Result<ParseFileResponse, WorkerError> {
            panic!("a cache hit must not parse");
        }
        fn validate_source(
            &mut self,
            _file: &str,
            _source: &str,
            _search_path: &[std::path::PathBuf],
        ) -> Result<ValidateResponse, WorkerError> {
            panic!("a cache hit must not validate");
        }
    }

    fn select(rule: &str) -> RuleSelection {
        RuleSelection::new(
            vec![rule.to_owned()],
            Vec::new(),
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        )
    }

    fn key() -> CacheKey {
        CacheKey::new("0.1.0", "cfg", "tc", "src-digest", Vec::new(), "rt", "Syntax")
    }

    #[test]
    fn a_dirty_file_is_formatted_and_diffed() {
        // `def a := 1  \n`: the two trailing spaces (bytes 10..12) sit in a trivia run, so
        // `text/trailing-whitespace` fires with a delete fix. The engine applies it through
        // the safe-write gate and reports the diff.
        let source = "def a := 1  \n";
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let mut worker = StubWorker::ok_with_trivia(vec![TextRange::new(10, 13)]);

        let analysis = analyze_file(
            &mut worker,
            &select("text/trailing-whitespace"),
            "A.lean",
            source,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();

        match &analysis.outcome {
            AnalysisOutcome::Analyzed {
                diagnostics,
                formatted,
                diff,
            } => {
                assert_eq!(diagnostics.len(), 1, "one trailing-whitespace finding");
                assert_eq!(formatted.as_deref(), Some("def a := 1\n"), "trailing spaces stripped");
                assert!(diff.as_ref().is_some_and(|d| d.contains("def a := 1")), "diff rendered");
            }
            broken @ AnalysisOutcome::Broken { .. } => panic!("expected an analyzed outcome, got {broken:?}"),
        }
        assert!(!analysis.from_cache);
    }

    #[test]
    fn a_clean_file_yields_no_findings_and_no_formatting() {
        let source = "def a := 1\n";
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let mut worker = StubWorker::ok_with_trivia(Vec::new());

        let analysis = analyze_file(
            &mut worker,
            &select("text/trailing-whitespace"),
            "A.lean",
            source,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();

        match &analysis.outcome {
            AnalysisOutcome::Analyzed {
                diagnostics,
                formatted,
                diff,
            } => {
                assert!(diagnostics.is_empty(), "a clean file has no findings");
                assert!(formatted.is_none(), "nothing to format");
                assert!(diff.is_none(), "no diff");
            }
            broken @ AnalysisOutcome::Broken { .. } => panic!("expected an analyzed outcome, got {broken:?}"),
        }
    }

    #[test]
    fn a_broken_file_is_reported_not_formatted() {
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let mut worker = StubWorker::broken();

        let analysis = analyze_file(
            &mut worker,
            &select("text/trailing-whitespace"),
            "Broken.lean",
            "def a := ",
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();

        match &analysis.outcome {
            AnalysisOutcome::Broken { status, diagnostics } => {
                assert_eq!(*status, ParseStatus::Error);
                assert_eq!(diagnostics.len(), 1);
            }
            analyzed @ AnalysisOutcome::Analyzed { .. } => panic!("expected a broken outcome, got {analyzed:?}"),
        }
        // A broken file is not cached: a second run re-parses (no hit to reconstruct).
        let mut again = StubWorker::broken();
        let second = analyze_file(
            &mut again,
            &select("text/trailing-whitespace"),
            "Broken.lean",
            "def a := ",
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();
        assert!(matches!(second.outcome, AnalysisOutcome::Broken { .. }));
        assert_eq!(
            again.parse_calls, 1,
            "the broken file was parsed again, not served from cache"
        );
    }

    #[test]
    fn a_second_run_is_served_from_cache_without_parsing() {
        let source = "def a := 1  \n";
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());

        // First run: a miss, stores the analysis.
        let mut worker = StubWorker::ok_with_trivia(vec![TextRange::new(10, 13)]);
        let first = analyze_file(
            &mut worker,
            &select("text/trailing-whitespace"),
            "A.lean",
            source,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();
        assert!(!first.from_cache);

        // Second run with a worker that panics if touched: the hit reconstructs the same
        // analysis without parsing.
        let mut panic_worker = PanicWorker;
        let second = analyze_file(
            &mut panic_worker,
            &select("text/trailing-whitespace"),
            "A.lean",
            source,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key(),
        )
        .unwrap();
        assert!(second.from_cache);
        assert_eq!(
            second.outcome, first.outcome,
            "a cache hit returns the same analysis a fresh run would"
        );
    }
}
