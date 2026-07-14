//! The `lean-fmt clean` command: remove the on-disk result cache, and optionally the
//! installed worker, for a project.
//!
//! This is pure filesystem removal — it needs no worker and does no analysis, so it is
//! dispatched directly by [`crate::run`] rather than through the report path. The command's
//! contract is stated as a post-condition ("after this, the cache is gone"), so removing a
//! target that is already absent is a success, not an error: there is no failure mode to
//! report when the desired end state already holds.

use std::path::Path;
use std::process::ExitCode;

use serde::Serialize;

use lean_fmt_worker::toolchain::{ToolchainId, install_dir};

use crate::{CleanArgs, OutputFormat, cache_root_for};

/// Parse-free entry point: clean the targets, render the report, and map to an exit code.
#[must_use]
pub(crate) fn run(args: &CleanArgs) -> ExitCode {
    match clean(args).and_then(|report| render(&report, args.format)) {
        Ok(rendered) => {
            print!("{rendered}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("lean-fmt: {error}");
            ExitCode::FAILURE
        }
    }
}

/// What each requested target came to.
#[derive(Debug, Serialize)]
pub(crate) struct CleanReport {
    /// Directories that existed and were removed.
    removed: Vec<String>,
    /// Directories that were already absent (still a success).
    absent: Vec<String>,
}

/// Remove the cache (always) and the installed worker (with `--workers`).
///
/// # Errors
/// A human-readable string if a directory exists but cannot be removed, or if a resolved
/// target has no parent directory (a filesystem root — never true for a constructed path,
/// but a guard against a pathological `LEAN_FMT_WORKERS_DIR` override).
fn clean(args: &CleanArgs) -> Result<CleanReport, String> {
    let mut removed = Vec::new();
    let mut absent = Vec::new();

    let cache = cache_root_for(&args.root);
    record(&remove_tree(&cache)?, &cache, &mut removed, &mut absent);

    if args.workers {
        let id = ToolchainId::from_lake_root(&args.root).unwrap_or_else(|_| ToolchainId::pinned());
        let dir = install_dir(&id);
        record(&remove_tree(&dir)?, &dir, &mut removed, &mut absent);
    }

    Ok(CleanReport { removed, absent })
}

/// The result of one removal attempt.
enum Outcome {
    /// The directory existed and is gone.
    Removed,
    /// The directory was not there to begin with.
    Absent,
}

/// Recursively remove `path`, treating "not found" as success.
///
/// # Errors
/// A message if `path` is a filesystem root (refused) or exists but cannot be removed.
fn remove_tree(path: &Path) -> Result<Outcome, String> {
    if path.parent().is_none() {
        return Err(format!("refusing to remove {} (filesystem root)", path.display()));
    }
    match std::fs::remove_dir_all(path) {
        Ok(()) => Ok(Outcome::Removed),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Outcome::Absent),
        Err(error) => Err(format!("could not remove {}: {error}", path.display())),
    }
}

/// File an outcome under the right list for the report.
fn record(outcome: &Outcome, path: &Path, removed: &mut Vec<String>, absent: &mut Vec<String>) {
    let display = path.display().to_string();
    match outcome {
        Outcome::Removed => removed.push(display),
        Outcome::Absent => absent.push(display),
    }
}

/// Render the report as text or a single JSON object.
///
/// # Errors
/// [`serde_json`] serialization failure (JSON format only).
fn render(report: &CleanReport, format: OutputFormat) -> Result<String, String> {
    match format {
        OutputFormat::Json => serde_json::to_string_pretty(report)
            .map(|json| format!("{json}\n"))
            .map_err(|error| error.to_string()),
        OutputFormat::Text => {
            let mut out = String::new();
            for path in &report.removed {
                out.push_str("removed: ");
                out.push_str(path);
                out.push('\n');
            }
            for path in &report.absent {
                out.push_str("nothing to remove: ");
                out.push_str(path);
                out.push('\n');
            }
            Ok(out)
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::*;

    fn args_for(root: &Path, workers: bool) -> CleanArgs {
        CleanArgs {
            root: root.to_path_buf(),
            workers,
            format: OutputFormat::Text,
        }
    }

    #[test]
    fn removes_an_existing_cache_then_reports_absent_on_a_second_run() {
        let root = TempDir::new().unwrap();
        let cache = cache_root_for(root.path());
        fs::create_dir_all(cache.join("sub")).unwrap();
        fs::write(cache.join("sub").join("entry"), b"x").unwrap();

        let first = clean(&args_for(root.path(), false)).unwrap();
        assert_eq!(first.removed.len(), 1);
        assert!(first.absent.is_empty());
        assert!(!cache.exists(), "cache dir removed");

        // Idempotent: the desired end state already holds, so a second run is a success.
        let second = clean(&args_for(root.path(), false)).unwrap();
        assert!(second.removed.is_empty());
        assert_eq!(second.absent.len(), 1);
    }

    #[test]
    fn remove_tree_is_idempotent_and_guards_the_filesystem_root() {
        // The removal core shared by the cache and the `--workers` install dir. Tested
        // directly so the test never mutates the process environment.
        let temp = TempDir::new().unwrap();
        let dir = temp.path().join("target");
        fs::create_dir_all(dir.join("nested")).unwrap();

        assert!(matches!(remove_tree(&dir).unwrap(), Outcome::Removed));
        assert!(!dir.exists());
        assert!(matches!(remove_tree(&dir).unwrap(), Outcome::Absent));

        // A path with no parent is a filesystem root: refused, never removed.
        assert!(remove_tree(Path::new("/")).is_err());
    }

    #[test]
    fn text_render_labels_removed_and_absent() {
        let report = CleanReport {
            removed: vec!["/a".into()],
            absent: vec!["/b".into()],
        };
        let text = render(&report, OutputFormat::Text).unwrap();
        assert!(text.contains("removed: /a"));
        assert!(text.contains("nothing to remove: /b"));
    }
}
