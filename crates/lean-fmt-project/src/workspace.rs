//! Lake workspace discovery and source enumeration.
//!
//! Mirrors the *idea* of `lean-dup`'s workspace resolution (module-to-path and
//! Lake-layout conventions live here so callers do not duplicate them), adapted for
//! the formatter: results are filtered through [`FormatterConfig`], `.lake` source is
//! never scanned, and multiple module roots are supported (no single-root assumption).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use walkdir::WalkDir;

use crate::config::FormatterConfig;
use crate::error::{Error, Result};

/// A validated Lake project root and the lakefile that identifies it.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectRoot {
    /// The canonicalized Lake project root directory.
    pub root: PathBuf,
    /// The lakefile (`lakefile.toml` or `lakefile.lean`) at the root.
    pub lakefile: PathBuf,
}

impl ProjectRoot {
    /// Discover the Lake root for a requested path. Accepts the path itself or its
    /// `lean/` subdirectory (the layout this repo uses). Rejects non-Lake paths.
    ///
    /// # Errors
    /// Returns [`Error::WorkspaceMissing`] if the path does not exist and
    /// [`Error::NotLakeWorkspace`] if neither it nor its `lean/` child holds a lakefile.
    pub fn discover(requested: &Path) -> Result<Self> {
        let requested = normalize_existing(requested)?;
        if let Some(lakefile) = lakefile_path(&requested) {
            return Ok(Self {
                root: requested,
                lakefile,
            });
        }
        let nested = requested.join("lean");
        if let Some(lakefile) = lakefile_path(&nested) {
            return Ok(Self { root: nested, lakefile });
        }
        Err(Error::NotLakeWorkspace(requested))
    }
}

/// A single Lean source file with its inferred dotted module name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SourceFile {
    /// Dotted module name (e.g. `LeanFmt.Capability`).
    pub module: String,
    /// Absolute path to the `.lean` file.
    pub path: PathBuf,
}

/// A fully resolved workspace: the root, its module roots, and the source files
/// selected for formatting after config filtering.
#[derive(Debug, Clone, Serialize)]
pub struct ResolvedWorkspace {
    /// The path the caller requested.
    pub requested_root: PathBuf,
    /// The resolved Lake root.
    pub root: PathBuf,
    /// The lakefile at the root.
    pub lakefile: PathBuf,
    /// Every module root discovered in the lakefile.
    pub module_roots: Vec<String>,
    /// The module roots actually enumerated (all, or a single requested root).
    pub selected_roots: Vec<String>,
    /// The `.lean` source files selected after include/exclude filtering.
    pub source_files: Vec<SourceFile>,
}

/// Resolve a workspace from a requested path, an optional single module root, and a
/// config for include/exclude filtering.
///
/// # Errors
/// Returns an error if the path is not a Lake project, has no module roots, or yields
/// no source files after include/exclude filtering.
pub fn resolve(
    requested_root: &Path,
    module_root: Option<&str>,
    config: &FormatterConfig,
) -> Result<ResolvedWorkspace> {
    let project = ProjectRoot::discover(requested_root)?;
    let discovered_roots = discover_module_roots(&project)?;
    let selected_roots = match module_root {
        Some(name) => vec![name.to_owned()],
        None => discovered_roots.clone(),
    };
    let source_files = enumerate_sources(&project.root, &selected_roots, config)?;
    if source_files.is_empty() {
        return Err(Error::NoSourceFiles {
            root: project.root,
            selected: selected_roots.join(", "),
        });
    }
    Ok(ResolvedWorkspace {
        requested_root: requested_root.to_path_buf(),
        root: project.root,
        lakefile: project.lakefile,
        module_roots: discovered_roots,
        selected_roots,
        source_files,
    })
}

/// Resolve an explicit list of files into [`SourceFile`]s.
///
/// Each must exist and be a `.lean` file. Module names are inferred relative to the
/// nearest enclosing Lake root when one exists, otherwise from the file stem.
///
/// # Errors
/// Returns [`Error::WorkspaceMissing`] for a missing path and [`Error::NotALeanFile`]
/// for a path that is not a readable `.lean` file.
pub fn resolve_files(files: &[PathBuf]) -> Result<Vec<SourceFile>> {
    let mut resolved = Vec::with_capacity(files.len());
    for file in files {
        let path = normalize_existing(file)?;
        if !path.is_file() || path.extension().and_then(|ext| ext.to_str()) != Some("lean") {
            return Err(Error::NotALeanFile(path));
        }
        let module = infer_module(&path);
        resolved.push(SourceFile { module, path });
    }
    Ok(resolved)
}

fn infer_module(path: &Path) -> String {
    if let Some(root) = enclosing_lake_root(path)
        && let Ok(relative) = path.strip_prefix(&root)
    {
        return module_from_relative(relative);
    }
    path.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn enclosing_lake_root(path: &Path) -> Option<PathBuf> {
    let mut current = path.parent();
    while let Some(dir) = current {
        if lakefile_path(dir).is_some() {
            return Some(dir.to_path_buf());
        }
        current = dir.parent();
    }
    None
}

fn module_from_relative(relative: &Path) -> String {
    let mut parts: Vec<String> = relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy().into_owned())
        .collect();
    if let Some(last) = parts.last_mut()
        && let Some(stripped) = last.strip_suffix(".lean")
    {
        *last = stripped.to_owned();
    }
    parts.join(".")
}

fn normalize_existing(path: &Path) -> Result<PathBuf> {
    if path.exists() {
        path.canonicalize().map_err(|source| Error::Io {
            message: "could not canonicalize path",
            path: path.to_path_buf(),
            source,
        })
    } else {
        Err(Error::WorkspaceMissing(path.to_path_buf()))
    }
}

fn lakefile_path(root: &Path) -> Option<PathBuf> {
    let toml = root.join("lakefile.toml");
    if toml.exists() {
        return Some(toml);
    }
    let lean = root.join("lakefile.lean");
    if lean.exists() {
        return Some(lean);
    }
    None
}

fn discover_module_roots(project: &ProjectRoot) -> Result<Vec<String>> {
    let is_toml = project.lakefile.file_name().and_then(|n| n.to_str()) == Some("lakefile.toml");
    let mut roots = if is_toml {
        discover_toml_roots(&project.lakefile)?
    } else {
        discover_lean_lakefile_roots(&project.lakefile)?
    };
    if roots.is_empty() {
        roots = discover_top_level_roots(&project.root)?;
    }
    roots.sort();
    roots.dedup();
    if roots.is_empty() {
        return Err(Error::NoModuleRoots(project.root.clone()));
    }
    Ok(roots)
}

fn read_to_string(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).map_err(|source| Error::Io {
        message: "could not read lakefile",
        path: path.to_path_buf(),
        source,
    })
}

fn discover_toml_roots(lakefile: &Path) -> Result<Vec<String>> {
    let text = read_to_string(lakefile)?;
    let parsed: toml::Value = toml::from_str(&text).map_err(|source| Error::LakefileToml {
        path: lakefile.to_path_buf(),
        source: Box::new(source),
    })?;
    let roots = parsed
        .get("lean_lib")
        .and_then(toml::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.get("name"))
        .filter_map(toml::Value::as_str)
        .map(ToOwned::to_owned)
        .collect();
    Ok(roots)
}

fn discover_lean_lakefile_roots(lakefile: &Path) -> Result<Vec<String>> {
    let text = read_to_string(lakefile)?;
    let roots = text
        .lines()
        .filter_map(|line| {
            let rest = line.trim_start().strip_prefix("lean_lib ")?;
            let raw = rest.split_whitespace().next()?;
            let root = raw
                .trim_matches('`')
                .trim_start_matches('\u{ab}')
                .trim_end_matches('\u{bb}')
                .to_owned();
            (!root.is_empty()).then_some(root)
        })
        .collect();
    Ok(roots)
}

fn discover_top_level_roots(root: &Path) -> Result<Vec<String>> {
    let mut roots = Vec::new();
    let entries = std::fs::read_dir(root).map_err(|source| Error::Io {
        message: "could not read workspace directory",
        path: root.to_path_buf(),
        source,
    })?;
    for entry in entries {
        let entry = entry.map_err(|source| Error::Io {
            message: "could not read workspace directory entry",
            path: root.to_path_buf(),
            source,
        })?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("lean")
            && let Some(stem) = path.file_stem().and_then(|stem| stem.to_str())
            && stem != "lakefile"
        {
            roots.push(stem.to_owned());
        }
    }
    Ok(roots)
}

fn enumerate_sources(root: &Path, module_roots: &[String], config: &FormatterConfig) -> Result<Vec<SourceFile>> {
    let mut sources = BTreeMap::<String, PathBuf>::new();
    for module_root in module_roots {
        insert_if_source(root, &module_to_file(root, module_root), config, &mut sources)?;

        let mut module_dir = root.to_path_buf();
        for part in module_root.split('.') {
            module_dir.push(part);
        }
        if !module_dir.exists() {
            continue;
        }
        for entry in WalkDir::new(&module_dir)
            .into_iter()
            .filter_map(std::result::Result::ok)
            .filter(|entry| entry.file_type().is_file())
        {
            insert_if_source(root, entry.path(), config, &mut sources)?;
        }
    }
    Ok(sources
        .into_iter()
        .map(|(module, path)| SourceFile { module, path })
        .collect())
}

fn insert_if_source(
    root: &Path,
    path: &Path,
    config: &FormatterConfig,
    sources: &mut BTreeMap<String, PathBuf>,
) -> Result<()> {
    if !path.is_file() || path.extension().and_then(|ext| ext.to_str()) != Some("lean") {
        return Ok(());
    }
    let relative = path.strip_prefix(root).map_err(|source| Error::Io {
        message: "could not relativize Lean source path",
        path: path.to_path_buf(),
        source: std::io::Error::other(source),
    })?;
    // Stop-rule: never scan `.lake` source; config always excludes it.
    if !config.accepts(relative) {
        return Ok(());
    }
    sources.insert(module_from_relative(relative), path.to_path_buf());
    Ok(())
}

fn module_to_file(root: &Path, module: &str) -> PathBuf {
    let mut path = root.to_path_buf();
    for part in module.split('.') {
        path.push(part);
    }
    path.set_extension("lean");
    path
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::fs;

    use tempfile::TempDir;

    use super::{ProjectRoot, resolve, resolve_files};
    use crate::config::FormatterConfig;

    fn write(dir: &std::path::Path, rel: &str, contents: &str) {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, contents).unwrap();
    }

    #[test]
    fn discovers_toml_lakefile_roots_and_sources() {
        let temp = TempDir::new().unwrap();
        write(
            temp.path(),
            "lakefile.toml",
            "name = \"Fixture\"\n[[lean_lib]]\nname = \"Fixture\"\n[[lean_lib]]\nname = \"Other\"\n",
        );
        write(temp.path(), "Fixture.lean", "import Fixture.Basic\n");
        write(temp.path(), "Fixture/Basic.lean", "theorem t : True := .intro\n");
        write(temp.path(), "Other.lean", "#check Nat\n");

        let resolved = resolve(temp.path(), None, &FormatterConfig::default()).unwrap();
        assert_eq!(resolved.module_roots, vec!["Fixture", "Other"]);
        let modules: Vec<_> = resolved.source_files.iter().map(|s| s.module.as_str()).collect();
        assert_eq!(modules, vec!["Fixture", "Fixture.Basic", "Other"]);
    }

    #[test]
    fn discovers_lean_lakefile_roots() {
        let temp = TempDir::new().unwrap();
        write(
            temp.path(),
            "lakefile.lean",
            "import Lake\nopen Lake DSL\n@[default_target]\nlean_lib LeanFmt where\n",
        );
        write(temp.path(), "LeanFmt.lean", "import LeanFmt.Capability\n");
        write(temp.path(), "LeanFmt/Capability.lean", "def x := 1\n");

        let resolved = resolve(temp.path(), None, &FormatterConfig::default()).unwrap();
        assert_eq!(resolved.selected_roots, vec!["LeanFmt"]);
        assert_eq!(resolved.source_files.len(), 2);
    }

    #[test]
    fn accepts_nested_lean_subdirectory_workspace() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lean/lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "lean/Pkg.lean", "def a := 1\n");
        let project = ProjectRoot::discover(temp.path()).unwrap();
        assert!(project.root.ends_with("lean"));
        let resolved = resolve(temp.path(), None, &FormatterConfig::default()).unwrap();
        assert_eq!(resolved.selected_roots, vec!["Pkg"]);
    }

    #[test]
    fn rejects_non_lake_root() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "notes.txt", "hello\n");
        let err = ProjectRoot::discover(temp.path()).unwrap_err();
        assert!(matches!(err, crate::error::Error::NotLakeWorkspace(_)));
    }

    #[test]
    fn errors_when_manifest_present_but_no_sources() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Empty\"\n");
        let err = resolve(temp.path(), None, &FormatterConfig::default()).unwrap_err();
        assert!(matches!(err, crate::error::Error::NoSourceFiles { .. }));
    }

    #[test]
    fn never_scans_dot_lake_source() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg.lean", "def a := 1\n");
        write(temp.path(), "Pkg/.lake/vendored/Dep.lean", "def leaked := 1\n");
        let resolved = resolve(temp.path(), None, &FormatterConfig::default()).unwrap();
        assert!(
            resolved
                .source_files
                .iter()
                .all(|s| !s.path.to_string_lossy().contains(".lake")),
            "resolved files must never include .lake source: {:?}",
            resolved.source_files
        );
    }

    #[test]
    fn resolves_explicit_file_list() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "lakefile.toml", "[[lean_lib]]\nname = \"Pkg\"\n");
        write(temp.path(), "Pkg/Basic.lean", "def a := 1\n");
        let files = vec![temp.path().join("Pkg/Basic.lean")];
        let resolved = resolve_files(&files).unwrap();
        assert_eq!(resolved.len(), 1);
        assert_eq!(resolved[0].module, "Pkg.Basic");
    }

    #[test]
    fn explicit_non_lean_file_is_rejected() {
        let temp = TempDir::new().unwrap();
        write(temp.path(), "notes.txt", "x\n");
        let files = vec![temp.path().join("notes.txt")];
        assert!(matches!(
            resolve_files(&files).unwrap_err(),
            crate::error::Error::NotALeanFile(_)
        ));
    }
}
