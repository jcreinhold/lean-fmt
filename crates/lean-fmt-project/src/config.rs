//! Formatter configuration: schema, defaults, discovery, and load.
//!
//! Config lives in a `lean-fmt.toml` file at the Lake project root (or an explicit
//! path passed on the command line). Every field has a default, so a project with no
//! config file resolves to [`FormatterConfig::default`].

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::{Error, Result};

/// The canonical config file name discovered at a project root.
pub const CONFIG_FILE_NAME: &str = "lean-fmt.toml";

fn default_line_width() -> usize {
    100
}

fn default_exclude() -> Vec<String> {
    // `.lake` is always excluded regardless of config (it holds build output and
    // vendored dependency source, never project source). Listing it here documents
    // the default; [`FormatterConfig::is_excluded`] enforces it unconditionally.
    vec![".lake".to_owned()]
}

/// Resolved formatter configuration.
///
/// `include`/`exclude` are path prefixes relative to the project root (v1 semantics:
/// a relative source path matches if it starts with the prefix, on component
/// boundaries). Glob support is deferred to a later prompt; the prefix model is
/// enough to scope discovery and is documented as such so callers do not assume globs.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct FormatterConfig {
    /// Target line width for layout rules (advisory until layout rules land).
    #[serde(default = "default_line_width")]
    pub line_width: usize,

    /// If non-empty, only source files whose root-relative path starts with one of
    /// these prefixes are formatted. Empty means "all discovered files".
    #[serde(default)]
    pub include: Vec<String>,

    /// Source files whose root-relative path starts with one of these prefixes are
    /// skipped. `.lake` is always excluded in addition to these.
    #[serde(default = "default_exclude")]
    pub exclude: Vec<String>,

    /// Rule selectors turned on for the project (rule id, category, or `all`). Empty
    /// means "use each rule's built-in default". Resolved against the registry by the
    /// diagnostics selector; command-line `--select` overrides this.
    #[serde(default)]
    pub select: Vec<String>,

    /// Rule selectors turned off for the project. An ignore beats a select in the same
    /// layer, so a broad `select` plus a narrow `ignore` works as expected.
    #[serde(default)]
    pub ignore: Vec<String>,

    /// Per-path-prefix ignore lists: files under the key prefix additionally ignore the
    /// listed selectors. A per-file ignore wins over both config and CLI selects.
    #[serde(default)]
    pub per_file_ignores: BTreeMap<String, Vec<String>>,
}

impl Default for FormatterConfig {
    fn default() -> Self {
        Self {
            line_width: default_line_width(),
            include: Vec::new(),
            exclude: default_exclude(),
            select: Vec::new(),
            ignore: Vec::new(),
            per_file_ignores: BTreeMap::new(),
        }
    }
}

impl FormatterConfig {
    /// Load config from an explicit path. The file must exist and parse.
    ///
    /// # Errors
    /// Returns [`Error::Io`] if the file cannot be read and [`Error::Config`] if it
    /// contains invalid TOML or unknown fields.
    pub fn load_from(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|source| Error::Io {
            message: "could not read config file",
            path: path.to_path_buf(),
            source,
        })?;
        toml::from_str(&text).map_err(|source| Error::Config {
            path: path.to_path_buf(),
            source: Box::new(source),
        })
    }

    /// Discover and load config for a project root. Returns [`FormatterConfig::default`]
    /// when no `lean-fmt.toml` is present at the root.
    ///
    /// # Errors
    /// Returns an error if a `lean-fmt.toml` exists but cannot be read or parsed.
    pub fn discover(root: &Path) -> Result<Self> {
        let candidate = root.join(CONFIG_FILE_NAME);
        if candidate.exists() {
            Self::load_from(&candidate)
        } else {
            Ok(Self::default())
        }
    }

    /// Whether a root-relative path should be skipped. Any path containing a `.lake`
    /// component is always excluded (build output / vendored dependency source, wherever
    /// it sits); otherwise the path is excluded if it starts with a configured prefix.
    #[must_use]
    pub fn is_excluded(&self, relative: &Path) -> bool {
        if has_dot_lake_component(relative) {
            return true;
        }
        self.exclude.iter().any(|prefix| path_has_prefix(relative, prefix))
    }

    /// Whether a root-relative path is included. When `include` is empty every path
    /// is included; otherwise the path must start with one of the include prefixes.
    #[must_use]
    pub fn is_included(&self, relative: &Path) -> bool {
        self.include.is_empty() || self.include.iter().any(|prefix| path_has_prefix(relative, prefix))
    }

    /// Whether a root-relative path passes both the include and exclude filters.
    #[must_use]
    pub fn accepts(&self, relative: &Path) -> bool {
        self.is_included(relative) && !self.is_excluded(relative)
    }
}

/// Return true when any component of `path` is exactly `.lake`.
fn has_dot_lake_component(path: &Path) -> bool {
    path.components().any(|component| component.as_os_str() == ".lake")
}

/// Return true when `path` starts with `prefix` on component boundaries. This avoids
/// matching `Foobar` against the prefix `Foo` while still matching `Foo/Bar.lean`.
fn path_has_prefix(path: &Path, prefix: &str) -> bool {
    let prefix_path = PathBuf::from(prefix);
    let mut prefix_components = prefix_path.components();
    let mut path_components = path.components();
    loop {
        match (prefix_components.next(), path_components.next()) {
            (None, _) => return true,
            (Some(_), None) => return false,
            (Some(a), Some(b)) if a != b => return false,
            (Some(_), Some(_)) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::path::Path;

    use super::{FormatterConfig, path_has_prefix};

    #[test]
    fn default_excludes_dot_lake_always() {
        let config = FormatterConfig::default();
        assert!(config.is_excluded(Path::new(".lake/build/lib/Foo.lean")));
        // `.lake` is excluded even when nested below a module directory.
        assert!(config.is_excluded(Path::new("Pkg/.lake/vendored/Dep.lean")));
        assert!(!config.is_excluded(Path::new("Foo/Bar.lean")));
    }

    #[test]
    fn prefix_matches_on_component_boundary() {
        assert!(path_has_prefix(Path::new("Foo/Bar.lean"), "Foo"));
        assert!(!path_has_prefix(Path::new("Foobar/Baz.lean"), "Foo"));
    }

    #[test]
    fn include_restricts_to_prefixes() {
        let config = FormatterConfig {
            include: vec!["Src".to_owned()],
            ..FormatterConfig::default()
        };
        assert!(config.accepts(Path::new("Src/A.lean")));
        assert!(!config.accepts(Path::new("Test/A.lean")));
    }

    #[test]
    fn parses_toml_with_known_fields() {
        let config: FormatterConfig =
            toml::from_str("line_width = 80\ninclude = [\"Src\"]\nexclude = [\"Vendor\"]\n").unwrap();
        assert_eq!(config.line_width, 80);
        assert_eq!(config.include, vec!["Src".to_owned()]);
        // `.lake` is still excluded on top of the configured exclude list.
        assert!(config.is_excluded(Path::new(".lake/x.lean")));
        assert!(config.is_excluded(Path::new("Vendor/x.lean")));
    }

    #[test]
    fn rejects_unknown_fields() {
        assert!(toml::from_str::<FormatterConfig>("bogus = 1\n").is_err());
    }

    #[test]
    fn parses_rule_selection_fields() {
        let config: FormatterConfig = toml::from_str(concat!(
            "select = [\"imports\"]\n",
            "ignore = [\"performance/large-file\"]\n",
            "[per_file_ignores]\n",
            "Vendor = [\"all\"]\n",
        ))
        .unwrap();
        assert_eq!(config.select, vec!["imports".to_owned()]);
        assert_eq!(config.ignore, vec!["performance/large-file".to_owned()]);
        assert_eq!(config.per_file_ignores.get("Vendor"), Some(&vec!["all".to_owned()]));
    }
}
