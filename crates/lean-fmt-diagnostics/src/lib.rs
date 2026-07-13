//! Diagnostic and rule-report model for lean-fmt.
//!
//! Owns the rule registry — stable [`RuleId`](lean_fmt_edit::RuleId)s, categories,
//! severities, and defaults — plus the selection resolver that decides which rules are
//! active for a file given CLI flags and config, and the execution engine that runs the
//! active rules over a parsed source model. Rules are added one module at a time; the
//! text-cleanup rules land first.

mod declaration;
mod engine;
mod imports;
mod layout;
mod rules;
mod selection;
mod text;

pub use engine::{RuleContext, check};
pub use rules::{Rule, RuleCategory, RuleInfo, Severity, all_rule_ids, registry, rule_by_id};
pub use selection::RuleSelection;
