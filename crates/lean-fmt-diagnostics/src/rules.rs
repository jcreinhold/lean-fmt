//! The rule registry: stable identities and metadata for every lint lean-fmt can emit.
//!
//! Each rule has a hand-assigned, stable [`RuleId`] (never derived from its display
//! text — see the stop-rule for prompt 13) plus a category, a one-line summary, a
//! default severity, and whether it runs by default. The registry is the single source
//! of truth the CLI, the config selector, and the Lean side all agree on.

use lean_fmt_edit::RuleId;
use serde::Serialize;

/// The family a rule belongs to. Categories double as coarse selectors: selecting
/// `imports` activates every rule whose category is [`RuleCategory::Imports`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleCategory {
    /// Whitespace, trailing space, blank-line, and encoding hygiene.
    Text,
    /// Import block ordering, grouping, and deduplication.
    Imports,
    /// Blank-line layout and block-structure (namespace/section/end) delimiters.
    Layout,
    /// Declaration headers, binders, and signature spacing.
    Declaration,
    /// Tactic-block structure and indentation.
    Tactic,
    /// Safety rails that preserve meaning (comments, pragmas).
    Safety,
    /// Cost heuristics that guard formatter throughput.
    Performance,
}

impl RuleCategory {
    /// The stable lowercase selector token for this category (e.g. `"imports"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Imports => "imports",
            Self::Layout => "layout",
            Self::Declaration => "declaration",
            Self::Tactic => "tactic",
            Self::Safety => "safety",
            Self::Performance => "performance",
        }
    }

    /// Every category, in registry order.
    #[must_use]
    pub const fn all() -> &'static [Self] {
        &[
            Self::Text,
            Self::Imports,
            Self::Layout,
            Self::Declaration,
            Self::Tactic,
            Self::Safety,
            Self::Performance,
        ]
    }
}

/// How loud a finding is. Severity is metadata only here; the CLI decides how each
/// level affects its exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// A violation that should fail `check`.
    Error,
    /// A violation worth reporting but not failing on by default.
    Warning,
    /// Advisory signal, never fails.
    Info,
}

/// Static metadata for one rule.
///
/// The `id` is the stable public identity; everything else is presentation and default
/// policy. Rules are constructed only inside [`registry`] so the identities stay in one
/// place.
#[derive(Debug, Clone)]
pub struct Rule {
    id: &'static str,
    category: RuleCategory,
    summary: &'static str,
    default_severity: Severity,
    default_enabled: bool,
}

impl Rule {
    /// The stable rule identity as a borrowed [`RuleId`]-compatible string.
    #[must_use]
    pub const fn id(&self) -> &'static str {
        self.id
    }

    /// The stable rule identity as an owned [`RuleId`].
    #[must_use]
    pub fn rule_id(&self) -> RuleId {
        RuleId::new(self.id)
    }

    /// The category this rule belongs to.
    #[must_use]
    pub const fn category(&self) -> RuleCategory {
        self.category
    }

    /// The one-line human summary.
    #[must_use]
    pub const fn summary(&self) -> &'static str {
        self.summary
    }

    /// The severity this rule emits at unless overridden.
    #[must_use]
    pub const fn default_severity(&self) -> Severity {
        self.default_severity
    }

    /// Whether the rule is active with no explicit selection.
    #[must_use]
    pub const fn default_enabled(&self) -> bool {
        self.default_enabled
    }
}

/// A serializable view of a [`Rule`] for machine-readable `lean-fmt rules` output.
#[derive(Debug, Clone, Serialize)]
pub struct RuleInfo {
    /// Stable rule identity.
    pub id: String,
    /// Category selector token.
    pub category: RuleCategory,
    /// One-line summary.
    pub summary: String,
    /// Default severity.
    pub default_severity: Severity,
    /// Whether the rule runs by default.
    pub default_enabled: bool,
}

impl From<&Rule> for RuleInfo {
    fn from(rule: &Rule) -> Self {
        Self {
            id: rule.id.to_owned(),
            category: rule.category,
            summary: rule.summary.to_owned(),
            default_severity: rule.default_severity,
            default_enabled: rule.default_enabled,
        }
    }
}

/// The full rule registry, in stable presentation order.
///
/// IDs are hand-assigned `category/slug` strings and must never change once shipped;
/// downstream config files and `--select` flags reference them. One rule per category
/// seeds the registry so selection and reporting have real entries to resolve against;
/// concrete rule logic lands in later prompts.
#[must_use]
pub fn registry() -> &'static [Rule] {
    const RULES: &[Rule] = &[
        Rule {
            id: "text/trailing-whitespace",
            category: RuleCategory::Text,
            summary: "Trailing whitespace at end of line.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "text/final-newline",
            category: RuleCategory::Text,
            summary: "File ends with exactly one trailing newline.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "imports/sorted",
            category: RuleCategory::Imports,
            summary: "Import statements are sorted and deduplicated.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "layout/blank-lines",
            category: RuleCategory::Layout,
            summary: "Excess consecutive blank lines between commands.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "layout/end-name",
            category: RuleCategory::Layout,
            summary: "A bare `end` closing a named block carries the block's name.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "declaration/header-spacing",
            category: RuleCategory::Declaration,
            summary: "Spacing around declaration headers and binders.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "tactic/block-indent",
            category: RuleCategory::Tactic,
            summary: "Tactic block indentation is consistent.",
            default_severity: Severity::Warning,
            default_enabled: true,
        },
        Rule {
            id: "safety/preserve-comments",
            category: RuleCategory::Safety,
            summary: "Formatting never drops or reorders comments.",
            default_severity: Severity::Error,
            default_enabled: true,
        },
        Rule {
            id: "performance/large-file",
            category: RuleCategory::Performance,
            summary: "File exceeds the size where formatting is skipped by default.",
            default_severity: Severity::Info,
            default_enabled: false,
        },
    ];
    RULES
}

/// Look up a rule by its stable id.
#[must_use]
pub fn rule_by_id(id: &str) -> Option<&'static Rule> {
    registry().iter().find(|rule| rule.id == id)
}

/// Every rule id in registry order.
#[must_use]
pub fn all_rule_ids() -> Vec<String> {
    registry().iter().map(|rule| rule.id.to_owned()).collect()
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

    use super::{RuleCategory, all_rule_ids, registry, rule_by_id};

    #[test]
    fn ids_are_unique_and_category_prefixed() {
        let ids = all_rule_ids();
        let mut sorted = ids.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), ids.len(), "rule ids must be unique");
        for rule in registry() {
            let prefix = format!("{}/", rule.category().as_str());
            assert!(
                rule.id().starts_with(&prefix),
                "id {} should start with its category prefix {prefix}",
                rule.id()
            );
        }
    }

    #[test]
    fn every_category_has_a_rule() {
        for category in RuleCategory::all() {
            assert!(
                registry().iter().any(|rule| rule.category() == *category),
                "category {} has no rule",
                category.as_str()
            );
        }
    }

    #[test]
    fn lookup_round_trips() {
        for id in all_rule_ids() {
            assert_eq!(rule_by_id(&id).unwrap().id(), id);
        }
        assert!(rule_by_id("no/such-rule").is_none());
    }

    #[test]
    fn performance_rule_is_off_by_default() {
        let rule = rule_by_id("performance/large-file").unwrap();
        assert!(!rule.default_enabled());
    }

    /// Captured verbatim from `LeanFmt.Rules.allRuleIdsJson` (see prompt 13). The Lean
    /// side tags diagnostics with these ids; they must equal the Rust registry ids in
    /// order, or selection and reporting disagree across the worker boundary.
    const LEAN_RULE_IDS_JSON: &str = r#"["text/trailing-whitespace","text/final-newline","imports/sorted","layout/blank-lines","layout/end-name","declaration/header-spacing","tactic/block-indent","safety/preserve-comments","performance/large-file"]"#;

    #[test]
    fn rust_and_lean_rule_ids_agree() {
        let lean_ids: Vec<String> = serde_json::from_str(LEAN_RULE_IDS_JSON).unwrap();
        assert_eq!(all_rule_ids(), lean_ids);
    }
}
