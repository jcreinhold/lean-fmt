//! End-to-end `lean_fmt_validate` round-trip: install a worker, then parse-and-elaborate
//! in-memory snapshots through the *installed* worker and check the elaboration verdict.
//!
//! Like `parse_file.rs`, this lives in the child crate because
//! `CARGO_BIN_EXE_lean-fmt-worker-child` is only exposed to this package's own tests, and
//! it needs a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test validate -- --ignored --nocapture
//! ```
//!
//! The load-bearing case is the Syntax-vs-Elab contrast: a snapshot that references an
//! undefined name **parses** (`parse_file` ⇒ `Ok`) but **fails to elaborate** (`validate`
//! ⇒ `valid = false`), and `safe_apply` at `ValidationLevel::Elab` therefore rejects an
//! edit producing it while `Syntax` would accept it.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::path::{Path, PathBuf};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_edit::{EditSet, TextEdit, TextRange};
use lean_fmt_project::{SafeApplyError, ValidationLevel, safe_apply};
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

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn validate_round_trip_through_installed_worker() -> Result<(), String> {
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

    // 1. A well-typed snapshot both parses and elaborates: valid.
    let good = "import Init\n\ndef a : Nat := 1\n";
    let good_v = worker
        .validate("Good.lean", good, &[])
        .map_err(|error| error.to_string())?;
    assert!(good_v.valid, "well-typed snapshot elaborates: {good_v:?}");
    assert!(good_v.diagnostics.is_empty(), "no diagnostics for a clean snapshot");

    // 2. A snapshot that PARSES but references an undefined name FAILS elaboration.
    let undefined = "import Init\n\ndef a : Nat := undefinedName\n";
    let parsed = worker
        .parse_file("Undef.lean", undefined, &[])
        .map_err(|error| error.to_string())?;
    assert_eq!(
        parsed.status,
        ParseStatus::Ok,
        "the undefined-name snapshot still PARSES ok: {parsed:?}"
    );
    let validated = worker
        .validate("Undef.lean", undefined, &[])
        .map_err(|error| error.to_string())?;
    assert!(
        !validated.valid,
        "the undefined-name snapshot FAILS elaboration: {validated:?}"
    );
    assert!(
        !validated.diagnostics.is_empty(),
        "elaboration failure reports diagnostics"
    );
    assert!(
        validated
            .diagnostics
            .iter()
            .any(|d| d.message.contains("Unknown identifier")),
        "the diagnostic names the unknown identifier: {validated:?}"
    );

    // 3. Drive it through the gate: the edit `1` -> `undefinedName` is accepted at Syntax
    //    (parses) but rejected at Elab (fails to elaborate). Same edit, stricter gate.
    let base = "import Init\n\ndef a : Nat := 1\n";
    let start = base.find('1').expect("literal present");
    let set = EditSet {
        edits: vec![TextEdit::replace(
            TextRange::new(start, start + 1),
            "1",
            "undefinedName",
        )],
    };

    let accepted = safe_apply(base, &set, ValidationLevel::Syntax, |patched| {
        worker
            .parse_file("Gate.lean", patched, &[])
            .expect("worker parse succeeds")
            .into()
    })
    .map_err(|error| format!("Syntax gate should accept a parsing edit: {error}"))?;
    assert!(accepted.contains("undefinedName"), "Syntax accepted the edited source");

    let elab_result = safe_apply(base, &set, ValidationLevel::Elab, |patched| {
        worker
            .validate("Gate.lean", patched, &[])
            .expect("worker validate succeeds")
            .into()
    });
    match elab_result {
        Err(SafeApplyError::Validation { level, diagnostics }) => {
            assert_eq!(level, ValidationLevel::Elab);
            assert!(!diagnostics.is_empty(), "Elab rejection carries diagnostics");
        }
        other => return Err(format!("Elab gate must reject a non-elaborating edit, got {other:?}")),
    }

    Ok(())
}
