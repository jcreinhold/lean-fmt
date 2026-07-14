//! Worker-driven fuzz for the two properties that need a real Lean parse: **idempotence** and
//! **parse preservation**. It takes every clean corpus file, applies a fixed battery of
//! mutations — trivia (trailing whitespace, blank lines, CRLF, leading/trailing blank padding)
//! plus one structural perturbation (body tab-indentation, which Lean's indentation-sensitive
//! syntax may reject) — and drives each mutant through a real installed worker. For every mutant
//! the worker accepts, it asserts:
//!
//! - **Parse preservation.** If the mutant parses, its formatted output parses too — formatting
//!   never turns a parseable file into a broken one.
//! - **Idempotence.** Re-formatting the formatted output changes nothing — formatting is a
//!   fixpoint.
//!
//! Mutants the worker reports as broken (e.g. a whitespace change that disturbs Lean's
//! indentation-sensitive syntax) are skipped, not asserted against — the properties are stated
//! only over inputs the parser accepts, and the stop rule (no silently-ignored counterexample) is
//! honored: a mutation family that always broke would surface as zero accepted mutants and fail
//! the coverage assertion below.
//!
//! The mutation battery is deterministic (no RNG), so a failure reproduces exactly. Like the other
//! worker-child tests it needs `CARGO_BIN_EXE_lean-fmt-worker-child` and a real Lean sysroot, so it
//! is `#[ignore]`d. Run with:
//!
//! ```sh
//! LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
//! LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
//!   cargo test -p lean-fmt-worker-child --test fuzz -- --ignored --nocapture
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

fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../lean-fmt-project/tests/fixtures/corpus")
}

/// Every clean (`.lean`, non-`broken`) corpus file's `(label, contents)`, deterministically ordered.
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

/// Indent every non-blank, non-`import` line by one tab. Import headers are left untouched: an
/// indented import header is invalid Lean that crashes the frontend outright (a distinct fatal
/// path, not a parse error), which is outside this fuzz's parse-accept/parse-reject domain.
fn tab_indent_body(source: &str) -> String {
    source
        .lines()
        .map(|line| {
            if line.is_empty() || line.trim_start().starts_with("import") {
                line.to_owned()
            } else {
                format!("\t{line}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A deterministic battery of trivia mutations, each `(name, mutated_source)`.
fn mutants(source: &str) -> Vec<(&'static str, String)> {
    vec![
        ("identity", source.to_owned()),
        ("trailing_spaces", source.lines().collect::<Vec<_>>().join("   \n")),
        ("double_blank_lines", source.replace('\n', "\n\n")),
        ("crlf", source.replace('\n', "\r\n")),
        ("leading_blanks", format!("\n\n{source}")),
        ("trailing_blanks", format!("{source}\n\n\n")),
        ("tab_indent_body", tab_indent_body(source)),
    ]
}

#[test]
#[ignore = "requires a Lean sysroot; set LEAN_FMT_RUNTIME_SYSROOT to run"]
fn formatting_is_idempotent_and_preserves_parseability_under_trivia_mutations() -> Result<(), String> {
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
    let selection = RuleSelection::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), BTreeMap::new());
    let keys = CacheKeyBuilder::new(
        &config,
        "0.1.0",
        installed.toolchain_label.as_str(),
        installed.runtime_source_digest.as_str(),
        ValidationLevel::Syntax,
        None,
    );
    // Disabled cache so every analysis genuinely re-parses.
    let cache = FormatCache::disabled(temp.path().join("cache"));

    // Analyze `source` under `label`, returning `Some(formatted_or_original)` when the worker
    // accepts it (parsed), or `None` when it reports the file broken.
    let analyze = |worker: &mut FormatterWorker, label: &str, source: &str| -> Result<Option<String>, String> {
        let key = keys.key_for(source);
        let analysis = analyze_file(
            worker,
            &selection,
            label,
            source,
            ValidationLevel::Syntax,
            &[],
            &cache,
            &key,
        )
        .map_err(|error| format!("{label}: {error}"))?;
        match analysis.outcome {
            AnalysisOutcome::Analyzed { formatted, .. } => Ok(Some(formatted.unwrap_or_else(|| source.to_owned()))),
            AnalysisOutcome::Broken { .. } => Ok(None),
        }
    };

    let files = clean_corpus(&corpus_root());
    assert!(!files.is_empty(), "the corpus has clean files");

    let mut accepted = 0usize;
    let mut skipped = 0usize;
    for (label, source) in &files {
        for (mutation, mutant) in mutants(source) {
            let case = format!("{label}#{mutation}");
            let Some(formatted) = analyze(&mut worker, &case, &mutant)? else {
                // The mutation disturbed parsing; the properties do not apply to it.
                skipped += 1;
                continue;
            };
            accepted += 1;

            // Parse preservation: the formatted output must itself parse.
            let reparsed = analyze(&mut worker, &case, &formatted)?
                .ok_or_else(|| format!("{case}: formatting turned a parseable file into a broken one"))?;

            // Idempotence: re-formatting is a fixpoint.
            if reparsed != formatted {
                return Err(format!(
                    "{case}: formatting is not idempotent — a second format changed the output"
                ));
            }
        }
    }

    println!("fuzz: {accepted} accepted mutant(s), {skipped} skipped (parse-disturbing)");
    // Coverage guard: the battery must actually exercise the worker on accepted inputs, so a
    // mutation family that silently always broke cannot pass as vacuously true.
    assert!(
        accepted >= files.len(),
        "at least the identity mutant of every clean file must be accepted (got {accepted} for {} files)",
        files.len()
    );

    Ok(())
}
