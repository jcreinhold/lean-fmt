//! End-to-end performance probe over the test corpus, through a real installed worker.
//!
//! This is the worker-driven counterpart to the worker-free benchmark in
//! `lean-fmt-project/benches/corpus.rs`. It measures the workloads that only exist once a real
//! Lean worker is in the loop — install cold start, cold vs. warm parse, cache miss vs. cache
//! hit, the fix/patch path, and server round-trip latency — and prints one
//! `name=<workload> ... elapsed_us=<n>` line per workload, in the style of the `lean-rs` probes.
//!
//! Following the `lean-rs` performance discipline (`~/Code/lean-rs/docs/performance.md`): the
//! printed numbers are **operating checks, not portable baselines** — capture before/after on the
//! same machine. The one assertion here is a *relative*, machine-independent perf budget: a warm
//! cache hit must be materially cheaper than the cold parse it replaces, so the caching
//! optimization is proven to pay off rather than asserted against a fragile absolute time.
//!
//! Like the other worker-child tests it needs `CARGO_BIN_EXE_lean-fmt-worker-child` (only exposed
//! to this package) and a real Lean sysroot, so it is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test perf -- --ignored --nocapture
//! ```
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::print_stdout,
    clippy::arithmetic_side_effects
)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_project::FormatService;
use lean_fmt_project::{
    AnalysisOutcome, CacheKeyBuilder, FormatCache, FormatterConfig, ServiceRequest, ServiceResponse, ServiceSettings,
    ValidationLevel, analyze_file,
};
use lean_fmt_worker::FormatterWorker;
use lean_fmt_worker::toolchain::{InstalledWorker, ToolchainId, resolve_in};

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

/// Every clean (`.lean`, non-`broken`) corpus file as `(path, contents)`, deterministically ordered.
fn clean_corpus(root: &Path) -> Vec<(String, String)> {
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
        if category == "broken" {
            continue;
        }
        let contents = std::fs::read_to_string(path).expect("read a corpus file");
        files.push((path.display().to_string(), contents));
    }
    files
}

/// Mean per-file microseconds over `n` files.
fn mean_us(total: Duration, n: usize) -> u128 {
    if n == 0 { 0 } else { total.as_micros() / n as u128 }
}

/// One full pass of the corpus through `analyze_file`, returning the elapsed time. The cache and
/// key builder are supplied by the caller so cold/warm and miss/hit passes share one code path.
fn analyze_pass(
    worker: &mut FormatterWorker,
    selection: &RuleSelection,
    keys: &CacheKeyBuilder,
    cache: &FormatCache,
    files: &[(String, String)],
) -> Duration {
    let start = Instant::now();
    for (path, contents) in files {
        let key = keys.key_for(contents);
        let analysis = analyze_file(
            worker,
            selection,
            path,
            contents,
            ValidationLevel::Syntax,
            &[],
            cache,
            &key,
        )
        .expect("analyze a clean corpus file");
        std::hint::black_box(&analysis);
    }
    start.elapsed()
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn corpus_performance_probe() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let id = ToolchainId::parse(&toolchain).map_err(|error| error.to_string())?;
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;
    let dest = temp.path().join("workers");

    // --- Workload: install (one-time cold cost of materializing an installed worker). ---
    let install_start = Instant::now();
    install_worker_command(&install_args(&dest, &sysroot, &toolchain))?;
    let installed: InstalledWorker = resolve_in(&dest, &id).map_err(|error| error.to_string())?;
    let install_elapsed = install_start.elapsed();
    println!("name=install elapsed_us={}", install_elapsed.as_micros());

    let config = FormatterConfig::default();
    let selection = RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new());
    let keys = CacheKeyBuilder::new(
        &config,
        "0.1.0",
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        ValidationLevel::Syntax,
        None,
    );

    let files = clean_corpus(&corpus_root());
    assert!(!files.is_empty(), "the corpus has clean files");
    let n = files.len();

    let mut worker = FormatterWorker::from_installed(&installed);

    // --- Workload: cold parse (first warm-session pass, cache disabled → every file parses). ---
    let disabled = FormatCache::disabled(temp.path().join("cache-off"));
    let cold = analyze_pass(&mut worker, &selection, &keys, &disabled, &files);
    println!(
        "name=cold_parse files={n} total_us={} mean_us={}/file",
        cold.as_micros(),
        mean_us(cold, n)
    );

    // --- Workload: warm parse (steady-state re-parse through the already-warm session). ---
    let warm = analyze_pass(&mut worker, &selection, &keys, &disabled, &files);
    println!(
        "name=warm_parse files={n} total_us={} mean_us={}/file",
        warm.as_micros(),
        mean_us(warm, n)
    );

    // --- Workload: cache miss vs. cache hit (the caching optimization, before/after). ---
    let enabled = FormatCache::new(temp.path().join("cache-on"));
    let miss = analyze_pass(&mut worker, &selection, &keys, &enabled, &files);
    println!(
        "name=cache_miss files={n} total_us={} mean_us={}/file",
        miss.as_micros(),
        mean_us(miss, n)
    );
    let hit = analyze_pass(&mut worker, &selection, &keys, &enabled, &files);
    println!(
        "name=cache_hit files={n} total_us={} mean_us={}/file",
        hit.as_micros(),
        mean_us(hit, n)
    );

    // --- Workload: fix / patching (a dirty file that produces formatted edits). ---
    let (dirty_path, clean_src) = files.first().cloned().expect("at least one clean file");
    let dirty_src = format!("{clean_src}   \n"); // trailing whitespace the text rules will strip
    let fix_start = Instant::now();
    let key = keys.key_for(&dirty_src);
    let fixed = analyze_file(
        &mut worker,
        &selection,
        &dirty_path,
        &dirty_src,
        ValidationLevel::Syntax,
        &[],
        &disabled,
        &key,
    )
    .map_err(|error| error.to_string())?;
    let fix_elapsed = fix_start.elapsed();
    let AnalysisOutcome::Analyzed { formatted, .. } = fixed.outcome else {
        return Err("fix workload: a clean-but-dirty file must analyze, not break".to_owned());
    };
    assert!(
        formatted.is_some(),
        "fix workload: trailing whitespace must produce an edit"
    );
    println!("name=fix elapsed_us={}", fix_elapsed.as_micros());

    // --- Workload: server round-trip latency through the FormatService actor. ---
    let settings = ServiceSettings {
        selection: RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new()),
        level: ValidationLevel::Syntax,
        search_path: Vec::new(),
        keys: keys.clone(),
    };
    // `installed` is not needed after this point, so move it into the controller closure.
    let service = FormatService::spawn(
        settings,
        FormatCache::disabled(temp.path().join("cache-svc")),
        64,
        move || Ok(FormatterWorker::from_installed(&installed)),
    )?;
    let server_start = Instant::now();
    for (path, contents) in &files {
        let response = service.submit(ServiceRequest::Format {
            path: path.clone(),
            text: contents.clone(),
            version: None,
        });
        let ServiceResponse::Analyzed { .. } = response else {
            return Err(format!(
                "server workload: expected Analyzed for {path}, got {response:?}"
            ));
        };
    }
    let server_elapsed = server_start.elapsed();
    println!(
        "name=server_roundtrip files={n} total_us={} mean_us={}/file",
        server_elapsed.as_micros(),
        mean_us(server_elapsed, n)
    );
    service.shutdown();

    // --- Perf budget: the warm cache hit must be materially cheaper than the cold parse it
    // replaces. This is a relative, machine-independent guard on the caching optimization: a hit
    // skips the entire worker IPC + parse + rule run, so it should be a large multiple faster; we
    // assert a conservative 2x to stay robust to noise while still catching a cache that stopped
    // paying off. ---
    let hit_us = hit.as_micros().max(1);
    let miss_us = miss.as_micros().max(1);
    assert!(
        hit_us.saturating_mul(2) <= miss_us,
        "perf budget: warm cache hit ({hit_us}us) is not at least 2x cheaper than cache miss ({miss_us}us) \
         over {n} files — the caching optimization has regressed"
    );

    Ok(())
}
