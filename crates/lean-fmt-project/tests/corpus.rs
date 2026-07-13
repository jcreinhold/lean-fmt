//! Worker-free golden suite over the test corpus.
//!
//! This computes a *structural* baseline of `tests/fixtures/corpus` — per-category file counts,
//! byte totals, line totals, and declared disposition, plus whole-corpus totals — and compares
//! it to the committed `baseline.json`. The baseline is a pure function of the file contents (no
//! timings, no machine paths), so the test is reproducible on any machine and needs no Lean
//! worker. It fails if the corpus drifts from the committed baseline; regenerate with:
//!
//! ```sh
//! LEAN_FMT_UPDATE_BASELINE=1 cargo test -p lean-fmt-project --test corpus
//! ```
//!
//! The *behavioral* golden — that clean files format idempotently and broken files stay broken —
//! needs a real worker and lives in `lean-fmt-worker-child/tests/corpus.rs` (env-gated).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The corpus root, resolved relative to this crate so no absolute/machine path is baked in.
fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/corpus")
}

/// The committed structural baseline path.
fn baseline_path() -> PathBuf {
    corpus_root().join("baseline.json")
}

/// The declared disposition of a category: `broken` files are expected to fail parsing; every
/// other category is expected to parse cleanly. (The parse claim itself is verified by the
/// env-gated worker test; here it is a declared structural attribute.)
fn disposition_of(category: &str) -> &'static str {
    if category == "broken" { "broken" } else { "clean" }
}

/// The per-category structural summary.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct CategorySummary {
    files: usize,
    bytes: usize,
    lines: usize,
    disposition: String,
}

/// The whole-corpus structural baseline.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct CorpusBaseline {
    categories: BTreeMap<String, CategorySummary>,
    total_files: usize,
    total_bytes: usize,
    total_lines: usize,
}

/// Compute the structural baseline by walking the corpus. Deterministic: the same files always
/// yield the same summary, regardless of filesystem ordering (categories are a sorted map).
fn compute_baseline(root: &Path) -> CorpusBaseline {
    let mut categories: BTreeMap<String, CategorySummary> = BTreeMap::new();
    let mut total_files = 0usize;
    let mut total_bytes = 0usize;
    let mut total_lines = 0usize;

    for entry in walkdir::WalkDir::new(root).sort_by_file_name() {
        let entry = entry.expect("walk the corpus");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("lean") {
            continue;
        }
        let category = path
            .strip_prefix(root)
            .expect("corpus file under root")
            .components()
            .next()
            .map(|component| component.as_os_str().to_string_lossy().into_owned())
            .expect("a category directory");

        let contents = std::fs::read_to_string(path).expect("read a corpus file");
        let bytes = contents.len();
        let lines = contents.lines().count();

        let summary = categories.entry(category.clone()).or_insert_with(|| CategorySummary {
            files: 0,
            bytes: 0,
            lines: 0,
            disposition: disposition_of(&category).to_owned(),
        });
        summary.files = summary.files.saturating_add(1);
        summary.bytes = summary.bytes.saturating_add(bytes);
        summary.lines = summary.lines.saturating_add(lines);

        total_files = total_files.saturating_add(1);
        total_bytes = total_bytes.saturating_add(bytes);
        total_lines = total_lines.saturating_add(lines);
    }

    CorpusBaseline {
        categories,
        total_files,
        total_bytes,
        total_lines,
    }
}

/// The categories the corpus is expected to carry, with their dispositions.
const EXPECTED: &[(&str, &str)] = &[
    ("broken", "broken"),
    ("comment-heavy", "clean"),
    ("custom-syntax", "clean"),
    ("large", "clean"),
    ("mathlib-style", "clean"),
    ("medium", "clean"),
    ("small", "clean"),
];

#[test]
fn corpus_has_every_expected_category_with_the_right_disposition() {
    let baseline = compute_baseline(&corpus_root());
    for (category, disposition) in EXPECTED {
        let summary = baseline
            .categories
            .get(*category)
            .unwrap_or_else(|| panic!("category {category} is missing from the corpus"));
        assert!(summary.files > 0, "category {category} has no files");
        assert_eq!(summary.disposition, *disposition, "category {category} disposition");
    }
    assert_eq!(
        baseline.categories.len(),
        EXPECTED.len(),
        "no unexpected categories present"
    );
    assert!(baseline.total_files >= EXPECTED.len(), "at least one file per category");
}

#[test]
fn structural_baseline_matches_the_committed_json() {
    let baseline = compute_baseline(&corpus_root());
    let rendered = format!("{}\n", serde_json::to_string_pretty(&baseline).unwrap());

    if std::env::var_os("LEAN_FMT_UPDATE_BASELINE").is_some() {
        std::fs::write(baseline_path(), &rendered).expect("write baseline.json");
        return;
    }

    let committed = std::fs::read_to_string(baseline_path()).expect(
        "baseline.json is committed; generate it with LEAN_FMT_UPDATE_BASELINE=1 cargo test -p lean-fmt-project --test corpus",
    );
    let committed: CorpusBaseline = serde_json::from_str(&committed).expect("parse committed baseline.json");
    assert_eq!(
        baseline, committed,
        "the corpus drifted from the committed baseline; regenerate with LEAN_FMT_UPDATE_BASELINE=1"
    );
}
