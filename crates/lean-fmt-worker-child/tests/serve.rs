//! End-to-end format-service test through a real installed worker: install a worker, spawn a
//! long-lived [`FormatService`] whose controller thread owns it, and drive `format`/`check`/
//! `health`/`shutdown` requests across it. Asserts the load-bearing property — a format request
//! works over server mode (dirty text comes back stripped through the real safe-write gate) —
//! plus stale-version rejection and graceful shutdown.
//!
//! Like the other worker-child tests, this needs `CARGO_BIN_EXE_lean-fmt-worker-child` (only
//! exposed to this package) and a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test serve -- --ignored --nocapture
//! ```
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::path::{Path, PathBuf};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_project::{
    CacheKeyBuilder, FormatCache, FormatService, FormatterConfig, ServiceRequest, ServiceResponse, ServiceSettings,
    ValidationLevel,
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

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn format_service_serves_requests_through_installed_worker() -> Result<(), String> {
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

    let config = FormatterConfig::default();
    let selection = RuleSelection::new(
        vec!["text/trailing-whitespace".to_owned()],
        Vec::new(),
        Vec::new(),
        Vec::new(),
        std::collections::BTreeMap::new(),
    );
    let settings = ServiceSettings {
        selection,
        level: ValidationLevel::Syntax,
        search_path: Vec::new(),
        keys: CacheKeyBuilder::new(
            &config,
            "0.1.0",
            installed.toolchain_label.as_str(),
            installed.runtime_source_digest.as_str(),
            ValidationLevel::Syntax,
        ),
    };
    let cache = FormatCache::new(temp.path().join("cache"));

    // The worker is built inside the controller thread and owned solely by it.
    let service = FormatService::spawn(settings, cache, 16, move || {
        Ok::<FormatterWorker, String>(FormatterWorker::from_installed(&installed))
    })?;

    // 1. A format request on dirty text: the trailing spaces come back stripped through the
    //    real safe-write gate — "format request works over server mode".
    let formatted = service.submit(ServiceRequest::Format {
        path: "A.lean".to_owned(),
        text: "import Init\n\ndef a : Nat := 1  \n".to_owned(),
        version: Some(1),
    });
    let ServiceResponse::Analyzed { changed, formatted, .. } = formatted else {
        return Err(format!("expected an analyzed response, got {formatted:?}"));
    };
    assert!(changed, "the dirty file would change: {formatted:?}");
    assert_eq!(
        formatted.as_deref(),
        Some("import Init\n\ndef a : Nat := 1\n"),
        "trailing spaces stripped through the real worker"
    );

    // 2. A check request on clean text: no change, no formatted text.
    let checked = service.submit(ServiceRequest::Check {
        path: "B.lean".to_owned(),
        text: "import Init\n\ndef b : Nat := 2\n".to_owned(),
        version: None,
    });
    let ServiceResponse::Analyzed { changed, formatted, .. } = checked else {
        return Err(format!("expected an analyzed response, got {checked:?}"));
    };
    assert!(!changed, "the clean file would not change");
    assert!(formatted.is_none(), "check does not return formatted text");

    // 3. A broken file is reported, never formatted.
    let broken = service.submit(ServiceRequest::Format {
        path: "C.lean".to_owned(),
        text: "import\n".to_owned(),
        version: None,
    });
    assert!(
        matches!(broken, ServiceResponse::Broken { .. }),
        "a non-parsing file is reported broken: {broken:?}"
    );

    // 4. A stale re-send of A.lean at an older version is rejected.
    let stale = service.submit(ServiceRequest::Format {
        path: "A.lean".to_owned(),
        text: "import Init\n\ndef a : Nat := 1  \n".to_owned(),
        version: Some(1),
    });
    assert!(
        matches!(stale, ServiceResponse::Stale { .. }),
        "a stale version is rejected: {stale:?}"
    );

    // 5. Health reports the requests served without touching the worker.
    let health = service.submit(ServiceRequest::Health);
    let ServiceResponse::Health { served, .. } = health else {
        return Err(format!("expected a health response, got {health:?}"));
    };
    assert!(served >= 3, "served counts the analyzed requests: {served}");

    // 6. Graceful shutdown: the service acknowledges and stops.
    assert!(matches!(
        service.submit(ServiceRequest::Shutdown),
        ServiceResponse::ShuttingDown
    ));
    service.shutdown();

    Ok(())
}
