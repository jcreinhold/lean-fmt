//! Rule selection: resolve which rules are active for a given file.
//!
//! Selection is layered with strict precedence: command-line flags override config,
//! which overrides each rule's built-in default. Within the CLI and config layers an
//! explicit ignore beats an explicit select, so a narrowly-ignored rule stays off even
//! when its category is selected. Per-file ignores are checked first and win outright.

use std::collections::BTreeMap;

use crate::rules::{Rule, registry};

/// A selector token: a rule id (`text/trailing-whitespace`), a category
/// (`imports`), or the wildcard `all`.
///
/// Matching is exact against the rule id, exact against the category token, or the
/// literal `all`.
fn selector_matches(selector: &str, rule: &Rule) -> bool {
    selector == "all" || selector == rule.id() || selector == rule.category().as_str()
}

fn any_matches(selectors: &[String], rule: &Rule) -> bool {
    selectors.iter().any(|selector| selector_matches(selector, rule))
}

/// The outcome of resolving one layer for one rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LayerDecision {
    /// The layer explicitly turns the rule on.
    Select,
    /// The layer explicitly turns the rule off (wins over select in the same layer).
    Ignore,
    /// The layer says nothing about this rule.
    Unset,
}

fn resolve_layer(select: &[String], ignore: &[String], rule: &Rule) -> LayerDecision {
    // Ignore beats select within a layer so a broad select + narrow ignore works.
    if any_matches(ignore, rule) {
        LayerDecision::Ignore
    } else if any_matches(select, rule) {
        LayerDecision::Select
    } else {
        LayerDecision::Unset
    }
}

/// A resolved rule selection built from CLI flags and config.
///
/// Construct with [`RuleSelection::new`], then query [`RuleSelection::is_active`] for a
/// specific rule and file. The resolver holds only owned strings so it never depends on
/// the config crate, keeping the dependency edge one-directional.
#[derive(Debug, Clone, Default)]
pub struct RuleSelection {
    cli_select: Vec<String>,
    cli_ignore: Vec<String>,
    config_select: Vec<String>,
    config_ignore: Vec<String>,
    per_file_ignores: BTreeMap<String, Vec<String>>,
}

impl RuleSelection {
    /// Build a selection from the two layers plus per-file ignores.
    ///
    /// `per_file_ignores` maps a path prefix to the selectors ignored for files under
    /// it; the matching convention is the caller's (relative-path prefix in practice).
    #[must_use]
    pub fn new(
        cli_select: Vec<String>,
        cli_ignore: Vec<String>,
        config_select: Vec<String>,
        config_ignore: Vec<String>,
        per_file_ignores: BTreeMap<String, Vec<String>>,
    ) -> Self {
        Self {
            cli_select,
            cli_ignore,
            config_select,
            config_ignore,
            per_file_ignores,
        }
    }

    /// Whether `rule` is active for the file at root-relative path `file`.
    ///
    /// Resolution order: a per-file ignore matching both `file` and the rule kills it;
    /// otherwise the CLI layer decides if it has an opinion; otherwise config decides;
    /// otherwise the rule's own `default_enabled`.
    #[must_use]
    pub fn is_active(&self, rule: &Rule, file: &str) -> bool {
        for (prefix, selectors) in &self.per_file_ignores {
            if path_matches_prefix(file, prefix) && any_matches(selectors, rule) {
                return false;
            }
        }
        match resolve_layer(&self.cli_select, &self.cli_ignore, rule) {
            LayerDecision::Select => return true,
            LayerDecision::Ignore => return false,
            LayerDecision::Unset => {}
        }
        match resolve_layer(&self.config_select, &self.config_ignore, rule) {
            LayerDecision::Select => true,
            LayerDecision::Ignore => false,
            LayerDecision::Unset => rule.default_enabled(),
        }
    }

    /// The ids of all registry rules active for `file`, in registry order.
    #[must_use]
    pub fn active_rule_ids(&self, file: &str) -> Vec<String> {
        registry()
            .iter()
            .filter(|rule| self.is_active(rule, file))
            .map(|rule| rule.id().to_owned())
            .collect()
    }
}

/// Whether `file` sits under `prefix`, matching on `/` component boundaries. An empty
/// prefix matches everything.
fn path_matches_prefix(file: &str, prefix: &str) -> bool {
    if prefix.is_empty() {
        return true;
    }
    match file.strip_prefix(prefix) {
        Some(rest) => rest.is_empty() || rest.starts_with('/'),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::panic,
        clippy::arithmetic_side_effects
    )]

    use std::collections::BTreeMap;

    use super::RuleSelection;
    use crate::rules::rule_by_id;

    fn rule(id: &str) -> &'static crate::rules::Rule {
        rule_by_id(id).unwrap()
    }

    #[test]
    fn defaults_apply_with_no_selection() {
        let selection = RuleSelection::default();
        assert!(selection.is_active(rule("text/trailing-whitespace"), "A.lean"));
        // Performance rule ships off.
        assert!(!selection.is_active(rule("performance/large-file"), "A.lean"));
    }

    #[test]
    fn cli_select_overrides_config_ignore() {
        let selection = RuleSelection::new(
            vec!["text/trailing-whitespace".to_owned()],
            Vec::new(),
            Vec::new(),
            vec!["text".to_owned()],
            BTreeMap::new(),
        );
        // Config ignores the whole text category, but the CLI re-selects the rule.
        assert!(selection.is_active(rule("text/trailing-whitespace"), "A.lean"));
    }

    #[test]
    fn ignore_beats_select_within_a_layer() {
        let selection = RuleSelection::new(
            vec!["imports".to_owned()],
            vec!["imports/sorted".to_owned()],
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        assert!(!selection.is_active(rule("imports/sorted"), "A.lean"));
    }

    #[test]
    fn category_selector_activates_default_off_rule() {
        let selection = RuleSelection::new(
            vec!["performance".to_owned()],
            Vec::new(),
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        assert!(selection.is_active(rule("performance/large-file"), "A.lean"));
    }

    #[test]
    fn per_file_ignore_wins_over_cli_select() {
        let mut per_file = BTreeMap::new();
        per_file.insert("Vendor".to_owned(), vec!["all".to_owned()]);
        let selection = RuleSelection::new(vec!["all".to_owned()], Vec::new(), Vec::new(), Vec::new(), per_file);
        // Under Vendor/, everything is ignored despite the CLI selecting all.
        assert!(!selection.is_active(rule("text/trailing-whitespace"), "Vendor/A.lean"));
        // Elsewhere the CLI select stands.
        assert!(selection.is_active(rule("text/trailing-whitespace"), "Src/A.lean"));
    }

    #[test]
    fn active_rule_ids_reflects_selection() {
        let all_off = RuleSelection::new(
            Vec::new(),
            vec!["all".to_owned()],
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        assert!(all_off.active_rule_ids("A.lean").is_empty());

        let only_imports = RuleSelection::new(
            vec!["imports".to_owned()],
            vec!["all".to_owned()],
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        // Ignore-all beats select within the CLI layer, so nothing is active.
        assert!(only_imports.active_rule_ids("A.lean").is_empty());
    }
}
