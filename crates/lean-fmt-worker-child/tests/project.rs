//! End-to-end project modes through a real installed worker: install a worker, build a
//! fixture project with mixed clean/dirty/broken files, and drive `run_project` across it.
//! Asserts the four load-bearing properties — deterministic (path-sorted) order, a nonzero
//! exit code, no abort on the broken file, and that fix mode writes only the dirty file.
//!
//! Like the other worker-child tests, this needs `CARGO_BIN_EXE_lean-fmt-worker-child` (only
//! exposed to this package) and a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test project -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::path::{Path, PathBuf};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_project::{
    CacheKeyBuilder, FileReport, FormatCache, FormatterConfig, RunMode, SourceFile, ValidationLevel, run_project,
};
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

fn source_file(dir: &Path, name: &str, contents: &str) -> SourceFile {
    let path = dir.join(name);
    std::fs::write(&path, contents).unwrap();
    SourceFile {
        module: name.trim_end_matches(".lean").to_owned(),
        path,
    }
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn project_modes_over_mixed_files_through_installed_worker() -> Result<(), String> {
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

    // A fixture project: one clean file, one with trailing whitespace, one that does not parse.
    let project = temp.path().join("project");
    std::fs::create_dir_all(&project).map_err(|error| error.to_string())?;
    let clean = source_file(&project, "Clean.lean", "import Init\n\ndef a : Nat := 1\n");
    let dirty = source_file(&project, "Dirty.lean", "import Init\n\ndef b : Nat := 2  \n");
    let broken = source_file(&project, "Broken.lean", "import\n");
    let dirty_path = dirty.path.clone();

    let config = FormatterConfig::default();
    let selection = RuleSelection::new(
        vec!["text/trailing-whitespace".to_owned()],
        Vec::new(),
        Vec::new(),
        Vec::new(),
        std::collections::BTreeMap::new(),
    );
    let keys = CacheKeyBuilder::new(
        &config,
        "0.1.0",
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        ValidationLevel::Syntax,
        None,
    );
    let cache = FormatCache::new(temp.path().join("cache"));

    // Files handed to the engine out of alphabetical order — the run must sort them.
    let files = vec![dirty, broken, clean];

    // 1. Check: deterministic order, mixed statuses, no abort on the broken file, exit 1.
    let checked = run_project(
        &mut worker,
        RunMode::Check,
        &files,
        &selection,
        &keys,
        ValidationLevel::Syntax,
        &[],
        &cache,
        |_message| {},
    );
    let paths: Vec<&str> = checked.reports.iter().map(FileReport::path).collect();
    let mut sorted = paths.clone();
    sorted.sort_unstable();
    assert_eq!(paths, sorted, "check reports are path-sorted");
    assert_eq!(
        checked.reports.len(),
        3,
        "all three files reported; no abort on the broken one"
    );
    let summary = checked.summary();
    assert_eq!(summary.clean, 1, "the clean file: {checked:?}");
    assert_eq!(summary.changed, 1, "the dirty file would change: {checked:?}");
    assert_eq!(
        summary.broken, 1,
        "the broken file is reported, not formatted: {checked:?}"
    );
    assert_eq!(checked.exit_code(), 1, "pending changes / broken → nonzero");
    // Check never writes: the dirty file is untouched on disk.
    let after_check = std::fs::read_to_string(&dirty_path).map_err(|error| error.to_string())?;
    assert_eq!(
        after_check, "import Init\n\ndef b : Nat := 2  \n",
        "check did not modify the file"
    );

    // 2. Fix: the dirty file is rewritten through the safe-write gate; broken stays broken.
    let fixed = run_project(
        &mut worker,
        RunMode::Fix,
        &files,
        &selection,
        &keys,
        ValidationLevel::Syntax,
        &[],
        &cache,
        |_message| {},
    );
    assert_eq!(
        fixed.summary().wrote,
        1,
        "exactly the dirty file was written: {fixed:?}"
    );
    let after_fix = std::fs::read_to_string(&dirty_path).map_err(|error| error.to_string())?;
    assert_eq!(
        after_fix, "import Init\n\ndef b : Nat := 2\n",
        "the trailing spaces were stripped on disk"
    );

    Ok(())
}
