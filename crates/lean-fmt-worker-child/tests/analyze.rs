//! End-to-end single-file analysis through a real installed worker: install a worker, then
//! drive `analyze_file` over clean, dirty, and broken in-memory fixtures and check the
//! outcome (findings, formatted output that re-parses, and a reported parse failure).
//!
//! Like `parse_file.rs`/`validate.rs`, this lives in the child crate because
//! `CARGO_BIN_EXE_lean-fmt-worker-child` is only exposed to this package's own tests, and it
//! needs a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test analyze -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_project::{AnalysisOutcome, CacheKey, FormatCache, ValidationLevel, analyze_file};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::{ToolchainId, resolve_in};

fn install_args(install_dir: &Path, sysroot: &Path, toolchain: &str) -> InstallWorkerArgs {
    InstallWorkerArgs {
        toolchain: Some(toolchain.to_owned()),
        sysroot: Some(sysroot.to_path_buf()),
        install_dir: Some(install_dir.to_path_buf()),
        worker_child: Some(PathBuf::from(env!("CARGO_BIN_EXE_lean-fmt-worker-child"))),
        source_dir: None,
        force: false,
    }
}

/// A selection with just the trailing-whitespace rule active — a deterministic,
/// safe-to-apply fix to exercise the format/diff path end-to-end.
fn trailing_whitespace_only() -> RuleSelection {
    RuleSelection::new(
        vec!["text/trailing-whitespace".to_owned()],
        Vec::new(),
        Vec::new(),
        Vec::new(),
        BTreeMap::new(),
    )
}

fn key(digest: &str) -> CacheKey {
    CacheKey::new("0.1.0", "cfg", "tc", digest, Vec::new(), "rt", "Syntax")
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn analyze_clean_dirty_and_broken_files_through_installed_worker() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let id = ToolchainId::parse(&toolchain).map_err(|error| error.to_string())?;
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;
    let dest = temp.path().join("workers");

    install_worker_command(&install_args(&dest, &sysroot, &toolchain))?;
    let installed = resolve_in(&dest, &id).map_err(|error| error.to_string())?;
    let mut worker = FormatterWorker::from_installed(&installed);

    let cache_dir = temp.path().join("cache");
    let cache = FormatCache::new(&cache_dir);
    let selection = trailing_whitespace_only();

    // 1. A dirty file (trailing whitespace) is analyzed, formatted, and diffed. The fix
    //    passes the safe-write gate (the cleaned text re-parses), so we get formatted output
    //    that no longer has the trailing spaces.
    let dirty = "import Init\n\ndef a : Nat := 1  \n";
    let dirty_analysis = analyze_file(
        &mut worker,
        &selection,
        "Dirty.lean",
        dirty,
        ValidationLevel::Syntax,
        &[],
        &cache,
        &key("dirty-digest"),
    )
    .map_err(|error| error.to_string())?;
    match &dirty_analysis.outcome {
        AnalysisOutcome::Analyzed {
            diagnostics,
            formatted,
            diff,
        } => {
            assert!(
                !diagnostics.is_empty(),
                "the dirty file has a finding: {dirty_analysis:?}"
            );
            let formatted = formatted
                .as_deref()
                .expect("the trailing-whitespace fix produced output");
            assert_eq!(
                formatted, "import Init\n\ndef a : Nat := 1\n",
                "trailing spaces stripped"
            );
            assert!(!formatted.contains("1  \n"), "no trailing spaces remain");
            assert!(diff.is_some(), "a change produces a diff");
        }
        other @ AnalysisOutcome::Broken { .. } => {
            return Err(format!("expected the dirty file to be analyzed, got {other:?}"));
        }
    }
    assert!(!dirty_analysis.from_cache);

    // 2. A clean file yields no findings and no formatting.
    let clean = "import Init\n\ndef a : Nat := 1\n";
    let clean_analysis = analyze_file(
        &mut worker,
        &selection,
        "Clean.lean",
        clean,
        ValidationLevel::Syntax,
        &[],
        &cache,
        &key("clean-digest"),
    )
    .map_err(|error| error.to_string())?;
    match &clean_analysis.outcome {
        AnalysisOutcome::Analyzed {
            diagnostics,
            formatted,
            diff,
        } => {
            assert!(
                diagnostics.is_empty(),
                "a clean file has no findings: {clean_analysis:?}"
            );
            assert!(formatted.is_none(), "nothing to format");
            assert!(diff.is_none(), "no diff");
        }
        other @ AnalysisOutcome::Broken { .. } => {
            return Err(format!("expected the clean file to be analyzed, got {other:?}"));
        }
    }

    // 3. A broken file (header parse failure) is reported, never formatted.
    let broken = "import\n";
    let broken_analysis = analyze_file(
        &mut worker,
        &selection,
        "Broken.lean",
        broken,
        ValidationLevel::Syntax,
        &[],
        &cache,
        &key("broken-digest"),
    )
    .map_err(|error| error.to_string())?;
    match &broken_analysis.outcome {
        AnalysisOutcome::Broken { diagnostics, .. } => {
            assert!(
                !diagnostics.is_empty(),
                "a broken file reports parse diagnostics: {broken_analysis:?}"
            );
        }
        other @ AnalysisOutcome::Analyzed { .. } => {
            return Err(format!("expected the broken file to be reported, got {other:?}"));
        }
    }

    // 4. Re-analyzing the dirty file is served from the cache (same analysis, no re-parse).
    let cached = analyze_file(
        &mut worker,
        &selection,
        "Dirty.lean",
        dirty,
        ValidationLevel::Syntax,
        &[],
        &cache,
        &key("dirty-digest"),
    )
    .map_err(|error| error.to_string())?;
    assert!(cached.from_cache, "the second run hits the cache");
    assert_eq!(
        cached.outcome, dirty_analysis.outcome,
        "a cache hit returns the same analysis"
    );

    Ok(())
}
