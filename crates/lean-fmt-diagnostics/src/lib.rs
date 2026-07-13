//! Diagnostic and rule-report model for lean-fmt.
//!
//! Owns the rule registry — stable [`RuleId`](lean_fmt_edit::RuleId)s, categories,
//! severities, and defaults — plus the selection resolver that decides which rules are
//! active for a file given CLI flags and config. Concrete rule logic (what each rule
//! actually flags) lands in later prompts; this crate fixes the identities and the
//! selection semantics everything else agrees on.

mod rules;
mod selection;

pub use rules::{Rule, RuleCategory, RuleInfo, Severity, all_rule_ids, registry, rule_by_id};
pub use selection::RuleSelection;
