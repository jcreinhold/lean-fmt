//! Differential correctness gate and end-to-end measurement for the pinned superset
//! environment, through a real installed worker.
//!
//! The claim `--pinned` rests on: parsing a file against the whole-project superset yields the
//! *same* result the rules consume as parsing it against its own header imports. This probe
//! proves it empirically. For each sampled project file it parses twice through one real worker
//! — once unpinned (own-header imports), once pinned (the superset) — and asserts the
//! **rule-feeding projection is byte-identical**: `status`, the module header (`imports`,
//! `is_module`, `import_spans`), the syntax summary (`command_regions`, `declaration_headers`,
//! `tactic_blocks`), and the source model (`trivia_runs`, `docstrings`). Identical projection ⇒
//! identical formatted output, because the rules read nothing else. A divergence on a file that
//! did *not* fall back is a real unsoundness and fails the test.
//!
//! It also measures the end-to-end shape the optimization is about: the one-time superset import
//! time, whether the union fit under the pinned RSS ceiling (`Pinned` vs `FellBack` — the signal
//! for whether grouped pinning is ever needed), the `fell_back` rate, and mean unpinned vs.
//! pinned per-file parse time.
//!
//! By default it runs against this repo's own small, always-built `lean/` `LeanFmt` package, so it
//! validates the mechanism with no external setup. Point it at a large library (mathlib) to run
//! the full-scale gate:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//! LEAN_FMT_PINNED_PROJECT="$HOME/Code/mathlib4" \
//! LEAN_FMT_PINNED_SAMPLE=200 \
//!   cargo test -p lean-fmt-worker-child --test pinned -- --ignored --nocapture
//! ```
#![allow(
    clippy::unwrap_used,
    clippy::unwrap_in_result,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::print_stdout,
    clippy::arithmetic_side_effects
)]

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lean_fmt_cli::{InstallWorkerArgs, install_worker_command};
use lean_fmt_worker::toolchain::{InstalledWorker, ToolchainId, resolve_in};
use lean_fmt_worker::{FormatterWorker, ParseFileResponse, PinOutcome};

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

/// The project whose files are diffed. Default: this repo's `lean/` `LeanFmt` package (small and
/// always built); override with `LEAN_FMT_PINNED_PROJECT` to point at a large library.
fn project_root() -> PathBuf {
    std::env::var_os("LEAN_FMT_PINNED_PROJECT").map_or_else(
        || {
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../lean")
                .canonicalize()
                .expect("resolve the default lean/ project root")
        },
        PathBuf::from,
    )
}

/// The module search path the imports resolve against: the project's built oleans, matching the
/// product's own `project_search_path`. On the current Lake layout the module tree lives under
/// `.lake/build/lib/lean`; older layouts put it directly under `.lake/build/lib`. Use the most
/// specific directory that exists, and exactly one — offering the base dir alongside the nested
/// root makes Lean's resolver reject the project's own imports.
///
/// A project with Lake dependencies (mathlib) needs every dependency's module root too. Set
/// `LEAN_FMT_PINNED_LIB` to a colon-separated path list (e.g. the output of `lake env printenv
/// LEAN_PATH`) to supply the full search path; each existing entry is used verbatim.
fn project_lib(root: &Path) -> Vec<PathBuf> {
    if let Some(explicit) = std::env::var_os("LEAN_FMT_PINNED_LIB") {
        return std::env::split_paths(&explicit).filter(|dir| dir.is_dir()).collect();
    }
    let base = root.join(".lake").join("build").join("lib");
    let nested = base.join("lean");
    if nested.is_dir() {
        vec![nested]
    } else if base.is_dir() {
        vec![base]
    } else {
        Vec::new()
    }
}

/// Every `.lean` file under the sampled root (excluding `.lake`), path-sorted and capped at the
/// sample size (`LEAN_FMT_PINNED_SAMPLE`, default 200 — the whole default project is well under
/// it). `LEAN_FMT_PINNED_SUBDIR` restricts the walk to a subdirectory of the project (e.g.
/// `Mathlib`), so a sample of a multi-target repo stays within one built library instead of
/// straying into sibling targets (`Archive`, `Counterexamples`) whose oleans may be unbuilt.
fn sample_files(root: &Path) -> Vec<PathBuf> {
    let cap: usize = std::env::var("LEAN_FMT_PINNED_SAMPLE")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(200);
    let walk_root = match std::env::var_os("LEAN_FMT_PINNED_SUBDIR") {
        Some(subdir) => root.join(subdir),
        None => root.to_path_buf(),
    };
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(&walk_root).sort_by_file_name() {
        let entry = entry.expect("walk the project");
        let path = entry.path();
        if path.components().any(|c| c.as_os_str() == ".lake") {
            continue;
        }
        if path.extension().and_then(|ext| ext.to_str()) == Some("lean") {
            files.push(path.to_path_buf());
        }
    }
    files.truncate(cap);
    files
}

/// The names of the rule-feeding projection fields on which `a` and `b` differ. Empty ⇒ the two
/// parses are interchangeable for every formatter rule. This is the exact set the rules read;
/// nothing outside it (e.g. `diagnostics`, `fell_back`) can change formatted output.
fn projection_diff(a: &ParseFileResponse, b: &ParseFileResponse) -> Vec<&'static str> {
    let mut fields = Vec::new();
    if a.status != b.status {
        fields.push("status");
    }
    if a.module_header.imports != b.module_header.imports {
        fields.push("module_header.imports");
    }
    if a.module_header.is_module != b.module_header.is_module {
        fields.push("module_header.is_module");
    }
    if a.module_header.import_spans != b.module_header.import_spans {
        fields.push("module_header.import_spans");
    }
    if a.syntax_summary.command_regions != b.syntax_summary.command_regions {
        fields.push("syntax_summary.command_regions");
    }
    if a.syntax_summary.declaration_headers != b.syntax_summary.declaration_headers {
        fields.push("syntax_summary.declaration_headers");
    }
    if a.syntax_summary.tactic_blocks != b.syntax_summary.tactic_blocks {
        fields.push("syntax_summary.tactic_blocks");
    }
    if a.source_model.trivia_runs != b.source_model.trivia_runs {
        fields.push("source_model.trivia_runs");
    }
    if a.source_model.docstrings != b.source_model.docstrings {
        fields.push("source_model.docstrings");
    }
    fields
}

fn mean_us(total: Duration, n: usize) -> u128 {
    if n == 0 { 0 } else { total.as_micros() / n as u128 }
}

#[test]
#[ignore = "requires a Lean sysroot and a built project; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn pinned_superset_matches_per_file_projection() -> Result<(), String> {
    let sysroot = std::env::var_os("LEAN_FMT_RUNTIME_SYSROOT")
        .map(PathBuf::from)
        .ok_or_else(|| "LEAN_FMT_RUNTIME_SYSROOT is not set".to_owned())?;
    let toolchain =
        std::env::var("LEAN_FMT_RUNTIME_TOOLCHAIN").unwrap_or_else(|_| "leanprover/lean4:v4.32.0-rc1".to_owned());
    let id = ToolchainId::parse(&toolchain).map_err(|error| error.to_string())?;
    let temp = tempfile::tempdir().map_err(|error| error.to_string())?;
    let dest = temp.path().join("workers");

    install_worker_command(&install_args(&dest, &sysroot, &toolchain))?;
    let installed: InstalledWorker = resolve_in(&dest, &id).map_err(|error| error.to_string())?;

    let root = project_root();
    let search_path = project_lib(&root);
    let files = sample_files(&root);
    if files.is_empty() {
        return Err(format!("no .lean files under {}", root.display()));
    }
    if search_path.is_empty() {
        return Err(format!(
            "no built oleans under {} (.lake/build/lib); build the project or set LEAN_FMT_PINNED_LIB",
            root.display()
        ));
    }
    let contents: Vec<(String, String)> = files
        .iter()
        .map(|path| {
            (
                path.display().to_string(),
                std::fs::read_to_string(path).expect("read a project file"),
            )
        })
        .collect();
    let n = contents.len();
    println!("name=pinned_diff project={} files={n}", root.display());

    let timeout_secs: u64 = std::env::var("LEAN_FMT_PINNED_TIMEOUT_SECS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(120);
    let mut worker = FormatterWorker::from_installed(&installed).request_timeout(Duration::from_secs(timeout_secs));

    // --- Baseline: parse every file per-file (own-header imports). A per-file worker error
    // (e.g. a heavy import closure exceeding the unpinned RSS ceiling) is a real cold-start
    // failure mode, not a harness failure: record it as `None` and exclude the file from the
    // differential rather than aborting the run. ---
    let baseline_start = Instant::now();
    let mut unpinned_errors = 0usize;
    let baseline: Vec<Option<ParseFileResponse>> = contents
        .iter()
        .map(
            |(path, source)| match worker.parse_file(path.clone(), source.clone(), &search_path) {
                Ok(response) => Some(response),
                Err(error) => {
                    unpinned_errors += 1;
                    println!("name=unpinned_error file={path} error={error}");
                    None
                }
            },
        )
        .collect();
    let baseline_elapsed = baseline_start.elapsed();
    println!(
        "name=unpinned_parse files={n} errors={unpinned_errors} total_us={} mean_us={}/file",
        baseline_elapsed.as_micros(),
        mean_us(baseline_elapsed, n)
    );

    // --- Pin the superset: the one-time import that the whole optimization turns on. ---
    let union = lean_fmt_project::superset_union(
        &files
            .iter()
            .map(|path| lean_fmt_project::SourceFile {
                module: String::new(),
                path: path.clone(),
            })
            .collect::<Vec<_>>(),
    );
    println!("name=superset union_imports={}", union.len());
    let pin_start = Instant::now();
    let outcome = worker
        .setup_pinned_env(union, &search_path)
        .map_err(|error| error.to_string())?;
    let pin_elapsed = pin_start.elapsed();
    match &outcome {
        PinOutcome::Pinned { id, resident_imports } => {
            println!(
                "name=pin outcome=pinned resident_imports={resident_imports} one_time_import_us={} id={id}",
                pin_elapsed.as_micros()
            );
        }
        PinOutcome::FellBack { reason } => {
            // The union did not fit or did not resolve: this is the correct graceful degrade,
            // and the data point that says grouped pinning would be needed here. There is no
            // pinned parse to diff, so report and stop — not a soundness failure.
            println!(
                "name=pin outcome=fell_back one_time_import_us={} reason={reason:?}",
                pin_elapsed.as_micros()
            );
            println!("name=result gate=skipped-fellback");
            return Ok(());
        }
    }
    assert!(worker.is_pinned(), "a Pinned outcome leaves the worker pinned");

    // --- Pinned pass: parse every file against the superset and diff the projection against the
    // per-file baseline. Only files that both modes parsed are compared; a pinned parse error is
    // recorded like a baseline error. ---
    let pinned_start = Instant::now();
    let mut fell_back = 0usize;
    let mut pinned_errors = 0usize;
    let mut compared = 0usize;
    let mut divergent: Vec<(String, Vec<&'static str>)> = Vec::new();
    for ((path, source), base) in contents.iter().zip(baseline.iter()) {
        let pinned = match worker.parse_file(path.clone(), source.clone(), &search_path) {
            Ok(response) => response,
            Err(error) => {
                pinned_errors += 1;
                println!("name=pinned_error file={path} error={error}");
                continue;
            }
        };
        if pinned.fell_back {
            fell_back += 1;
        }
        let Some(base) = base else { continue };
        compared += 1;
        let diff = projection_diff(base, &pinned);
        if !diff.is_empty() {
            println!(
                "name=divergence-detail file={path} base_status={:?} pinned_status={:?} \
                 pinned_fell_back={} base_diags={} pinned_diags={} base_imports={} pinned_imports={}",
                base.status,
                pinned.status,
                pinned.fell_back,
                base.diagnostics.len(),
                pinned.diagnostics.len(),
                base.module_header.imports.len(),
                pinned.module_header.imports.len(),
            );
            for diag in base.diagnostics.iter().take(2) {
                println!(
                    "name=base-diag file={path} sev={} line={} col={} msg={:?}",
                    diag.severity,
                    diag.line,
                    diag.column,
                    diag.message.chars().take(140).collect::<String>(),
                );
            }
            divergent.push((path.clone(), diff));
        }
    }
    let pinned_elapsed = pinned_start.elapsed();
    println!(
        "name=pinned_parse files={n} errors={pinned_errors} total_us={} mean_us={}/file",
        pinned_elapsed.as_micros(),
        mean_us(pinned_elapsed, n)
    );
    println!(
        "name=fell_back files={fell_back} rate={:.3}",
        fell_back as f64 / n as f64
    );
    println!("name=compared files={compared} of={n}");

    for (path, fields) in &divergent {
        println!("name=divergence file={path} fields={fields:?}");
    }
    println!(
        "name=result gate={} compared={compared} divergent={}",
        if divergent.is_empty() { "pass" } else { "FAIL" },
        divergent.len()
    );

    assert!(
        divergent.is_empty(),
        "{} of {compared} compared files diverged in the rule-feeding projection between per-file \
         and pinned parses; pinning is unsound for these files",
        divergent.len(),
    );
    assert!(
        compared > 0,
        "no file was parsed by both modes, so the gate proved nothing"
    );
    Ok(())
}
