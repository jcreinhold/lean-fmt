//! Worker-free benchmark harness over the test corpus (`cargo bench -p lean-fmt-project`).
//!
//! This measures the deterministic, Lean-free hot paths the formatter runs on every file — the
//! source digest, the per-file cache key, and unified-diff rendering — over the whole corpus.
//! It needs no Lean worker, uses only a crate-relative corpus path (no machine paths), and
//! prints a human-readable throughput report; it asserts no timing numbers, so it is
//! reproducible anywhere. The full worker-driven formatting benchmark is env-gated and lives in
//! `lean-fmt-worker-child/tests/corpus.rs`.
//!
//! Uses a custom harness (`harness = false`) rather than an extra benchmark dependency, so
//! `cargo bench` stays buildable on stable with no new third-party crates.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::print_stdout,
    clippy::arithmetic_side_effects
)]

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lean_fmt_diagnostics::RuleSelection;
use lean_fmt_edit::unified_diff;
use lean_fmt_project::{CacheKeyBuilder, FormatterConfig, ValidationLevel, source_digest};

/// The corpus root, crate-relative so no absolute path is baked into the benchmark.
fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/corpus")
}

/// Read every `.lean` file in the corpus as `(path, contents)`.
fn load_corpus(root: &Path) -> Vec<(String, String)> {
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(root).sort_by_file_name() {
        let entry = entry.expect("walk the corpus");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("lean") {
            continue;
        }
        let contents = std::fs::read_to_string(path).expect("read a corpus file");
        files.push((path.display().to_string(), contents));
    }
    files
}

/// Time `body` over `iterations` full passes of the corpus and report throughput.
fn bench(name: &str, files: &[(String, String)], iterations: u32, mut body: impl FnMut(&str, &str)) {
    // One untimed warm-up pass.
    for (path, contents) in files {
        body(path, contents);
    }
    let start = Instant::now();
    for _ in 0..iterations {
        for (path, contents) in files {
            body(path, contents);
        }
    }
    let elapsed = start.elapsed();
    let passes = u64::from(iterations);
    let per_pass = elapsed.checked_div(iterations).unwrap_or(Duration::ZERO);
    let total_files = passes.saturating_mul(files.len() as u64);
    let per_file = elapsed
        .checked_div(total_files.min(u64::from(u32::MAX)) as u32)
        .unwrap_or(Duration::ZERO);
    println!("{name:<28} {iterations:>6} passes  {per_pass:>12?}/pass  {per_file:>12?}/file");
}

fn main() {
    let files = load_corpus(&corpus_root());
    let bytes: usize = files.iter().map(|(_, contents)| contents.len()).sum();
    println!(
        "lean-fmt corpus benchmark: {} file(s), {} byte(s) (worker-free paths)",
        files.len(),
        bytes
    );

    let config = FormatterConfig::default();
    let keys = CacheKeyBuilder::new(
        &config,
        "0.1.0",
        "leanprover/lean4:bench",
        "runtime-digest",
        ValidationLevel::Syntax,
        None,
    );
    let _selection = RuleSelection::new(
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        std::collections::BTreeMap::new(),
    );

    bench("source_digest", &files, 2000, |_path, contents| {
        let digest = source_digest(contents);
        std::hint::black_box(digest);
    });

    bench("cache_key", &files, 2000, |_path, contents| {
        let key = keys.key_for(contents);
        std::hint::black_box(key);
    });

    // A representative edit: strip one trailing space appended to the source, then diff.
    bench("unified_diff", &files, 2000, |path, contents| {
        let modified = format!("{contents} ");
        let diff = unified_diff(&modified, contents, path);
        std::hint::black_box(diff);
    });

    println!("done");
}
