//! End-to-end `parse_file` round-trip: install a worker, then parse in-memory Lean
//! source snapshots through the *installed* worker and check the parse outcome.
//!
//! Like `install_worker.rs`, this lives in the child crate because
//! `CARGO_BIN_EXE_lean-fmt-worker-child` is only exposed to this package's own tests,
//! and it needs a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test parse_file -- --ignored --nocapture
//! ```
//!
//! The load-bearing case is import-dependent notation: it builds a fixture module `B`
//! (defining a custom `notation`) to `.olean`, and confirms a snapshot importing `B`
//! and using that notation parses cleanly with `B`'s build dir on the search path, but
//! degrades (no crash) with it absent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::path::{Path, PathBuf};
use std::process::Command;

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_edit::SourceMap;
use lean_fmt_worker::toolchain::{ToolchainId, resolve_in};
use lean_fmt_worker::{FormatterWorker, ParseStatus};

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

/// Compile a tiny module defining a custom `notation` to `<dir>/NotationFixture.olean`,
/// returning `dir` (the search-path entry that makes the notation importable).
fn build_notation_olean(sysroot: &Path, dir: &Path) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|error| format!("create fixture dir: {error}"))?;
    let src = dir.join("NotationFixture.lean");
    std::fs::write(
        &src,
        "import Init\nnamespace NotationFixture\nnotation:65 a \" \u{2295}fix \" b => a + b\nend NotationFixture\n",
    )
    .map_err(|error| format!("write fixture source: {error}"))?;
    let olean = dir.join("NotationFixture.olean");
    let lean_bin = sysroot.join("bin").join("lean");
    // `lean` requires the input to live under its working directory (its inferred
    // package root); run from the fixture dir with relative paths so a temp-dir source
    // is accepted. A clean env drops any inherited Lake root; the compiler finds its own
    // libs via baked rpaths.
    let status = Command::new(&lean_bin)
        .current_dir(dir)
        .env_clear()
        .env("PATH", sysroot.join("bin"))
        .arg("-o")
        .arg("NotationFixture.olean")
        .arg("NotationFixture.lean")
        .status()
        .map_err(|error| format!("spawn lean to build fixture olean: {error}"))?;
    if !status.success() {
        return Err(format!("lean failed to build NotationFixture.olean (status {status})"));
    }
    if !olean.is_file() {
        return Err(format!("expected {} but it was not produced", olean.display()));
    }
    Ok(dir.to_path_buf())
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn parse_file_round_trip_through_installed_worker() -> Result<(), String> {
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

    // 1. A simple self-contained snapshot parses cleanly.
    let simple_src = "import Init\n\ndef foo : Nat := 1\ntheorem bar : foo = 1 := rfl\n";
    let simple = worker
        .parse_file("Simple.lean", simple_src, &[])
        .map_err(|error| error.to_string())?;
    assert_eq!(simple.status, ParseStatus::Ok, "simple snapshot parses ok: {simple:?}");
    assert!(simple.diagnostics.is_empty(), "no diagnostics for a clean snapshot");
    assert_eq!(simple.syntax_summary.command_count, 2, "two top-level commands");
    assert_eq!(simple.module_header.imports, vec!["Init".to_owned()]);

    // Every command carries a byte-anchored region, and the line/column Lean reported
    // must match a Rust `SourceMap` over the same source — the cross-side faithfulness
    // check that our codepoint-based column counting agrees with Lean's `FileMap`.
    let regions = &simple.syntax_summary.command_regions;
    assert_eq!(regions.len(), 2, "one region per top-level command: {regions:?}");
    let map = SourceMap::new(simple_src);
    for region in regions {
        assert!(
            region.range.is_well_formed(simple_src.len()),
            "region byte range within source bounds: {region:?}"
        );
        assert_eq!(
            map.line_column_range(region.range),
            region.line_column,
            "Rust SourceMap must reproduce Lean's line/column for {region:?}"
        );
        // The byte slice for the region is the command's source text.
        assert!(map.slice(region.range).is_some(), "region slice is in-bounds");
    }

    // 2. A syntactically broken snapshot degrades with structured diagnostics, no crash.
    let broken = worker
        .parse_file("Broken.lean", "import Init\n\ndef foo : Nat := \n", &[])
        .map_err(|error| error.to_string())?;
    assert_eq!(
        broken.status,
        ParseStatus::Degraded,
        "broken snapshot degrades: {broken:?}"
    );
    assert!(!broken.diagnostics.is_empty(), "broken snapshot reports diagnostics");
    assert_eq!(broken.diagnostics[0].severity, "error");

    // 3. Import-dependent notation: build the defining module, then parse a snapshot
    //    that uses its notation — clean with the module on the search path.
    let fixture_dir = build_notation_olean(&sysroot, &temp.path().join("fix"))?;
    let notation_src = "import NotationFixture\nopen NotationFixture\ndef z : Nat := 2 \u{2295}fix 3\n";
    let on_path = worker
        .parse_file("UsesNotation.lean", notation_src, std::slice::from_ref(&fixture_dir))
        .map_err(|error| error.to_string())?;
    assert_eq!(
        on_path.status,
        ParseStatus::Ok,
        "notation parses with its module on the search path: {on_path:?}"
    );
    assert!(
        on_path.diagnostics.is_empty(),
        "no diagnostics when notation is available"
    );
    assert!(on_path.module_header.imports.contains(&"NotationFixture".to_owned()));

    // 4. Same snapshot, module absent from the search path: degrade, do not crash.
    let off_path = worker
        .parse_file("UsesNotation.lean", notation_src, &[])
        .map_err(|error| error.to_string())?;
    assert_eq!(
        off_path.status,
        ParseStatus::Degraded,
        "missing notation module degrades: {off_path:?}"
    );
    assert!(!off_path.diagnostics.is_empty(), "degrade reports diagnostics");

    Ok(())
}
