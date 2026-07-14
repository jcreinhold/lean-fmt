//! End-to-end behavioral golden over the test corpus, through a real installed worker.
//!
//! For every corpus file this asserts the two properties the worker-free structural golden
//! (`lean-fmt-project/tests/corpus.rs`) cannot check without Lean:
//!
//! - **Clean files are idempotent.** A non-`broken` file parses, and if formatting changes it,
//!   re-formatting the output changes nothing — formatting is a fixpoint.
//! - **Broken files stay broken.** A `broken` file is reported [`AnalysisOutcome::Broken`],
//!   never formatted.
//!
//! Like the other worker-child tests, this needs `CARGO_BIN_EXE_lean-fmt-worker-child` (only
//! exposed to this package) and a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test corpus -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_project::{AnalysisOutcome, CacheKeyBuilder, FormatCache, FormatterConfig, ValidationLevel, analyze_file};
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

/// The corpus root, resolved relative to this crate (workspace-relative, no machine path).
fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../lean-fmt-project/tests/fixtures/corpus")
}

/// Every `.lean` corpus file as `(category, path, contents)`, sorted for deterministic order.
fn corpus_files(root: &Path) -> Vec<(String, PathBuf, String)> {
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(root).sort_by_file_name() {
        let entry = entry.expect("walk the corpus");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("lean") {
            continue;
        }
        let category = path
            .strip_prefix(root)
            .expect("under root")
            .components()
            .next()
            .map(|component| component.as_os_str().to_string_lossy().into_owned())
            .expect("a category");
        let contents = std::fs::read_to_string(path).expect("read a corpus file");
        files.push((category, path.to_path_buf(), contents));
    }
    files
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn corpus_formats_idempotently_and_broken_files_stay_broken() -> Result<(), String> {
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

    let config = FormatterConfig::default();
    // The default-enabled rule set, as a real `check`/`fix` run would use.
    let selection = RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new());
    let keys = CacheKeyBuilder::new(
        &config,
        "0.1.0",
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        ValidationLevel::Syntax,
        None,
    );
    // Disabled cache so every analysis genuinely re-parses (idempotence must not be masked).
    let cache = FormatCache::disabled(temp.path().join("cache"));

    let files = corpus_files(&corpus_root());
    assert!(!files.is_empty(), "the corpus is non-empty");

    for (category, path, contents) in &files {
        let label = path.display().to_string();
        let key = keys.key_for(contents);
        let analysis = analyze_file(
            &mut worker,
            &selection,
            &label,
            contents,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key,
        )
        .map_err(|error| format!("{label}: {error}"))?;

        if category == "broken" {
            assert!(
                matches!(analysis.outcome, AnalysisOutcome::Broken { .. }),
                "{label}: a broken file must be reported broken, got {:?}",
                analysis.outcome
            );
            continue;
        }

        // Clean file: it must parse and be analyzed.
        let AnalysisOutcome::Analyzed { formatted, .. } = analysis.outcome else {
            return Err(format!("{label}: expected a clean file to be analyzed, got broken"));
        };

        // If formatting changed it, re-formatting the output must be a fixpoint.
        if let Some(formatted) = formatted {
            let key2 = keys.key_for(&formatted);
            let second = analyze_file(
                &mut worker,
                &selection,
                &label,
                &formatted,
                ValidationLevel::Syntax,
                &[],
                &cache,
                &key2,
            )
            .map_err(|error| format!("{label} (reformat): {error}"))?;
            let AnalysisOutcome::Analyzed { formatted: again, .. } = second.outcome else {
                return Err(format!("{label}: reformatting a clean file made it broken"));
            };
            assert!(
                again.is_none(),
                "{label}: formatting is not idempotent — the output still changes"
            );
        }
    }

    Ok(())
}
