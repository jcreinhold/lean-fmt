//! The rule-execution engine: run the active rules over a parsed source model.
//!
//! [`check`] is the single entrypoint. It walks the registry in order, asks the
//! [`RuleSelection`] whether each rule is active for the file, and runs the rules that
//! have an implementation, collecting their [`Diagnostic`]s. Rules with no implementation
//! yet (most of the registry) are simply skipped, so the engine grows one rule at a time.

use lean_fmt_edit::{Diagnostic, ImportRecord, SyntaxRegion, TextRange};

use crate::imports;
use crate::layout;
use crate::rules::registry;
use crate::selection::RuleSelection;
use crate::text;

/// The input one rule checks.
///
/// `trivia_runs` are the parser-derived non-token byte spans (the worker's
/// `source_model.trivia_runs`, from the trivia model). Text rules consult them so they
/// only ever edit bytes that lie outside every token — never, say, the trailing spaces
/// inside a multi-line string literal.
pub struct RuleContext<'a> {
    /// The full source text.
    pub source: &'a str,
    /// The root-relative path, used for per-file rule selection.
    pub path: &'a str,
    /// Non-token byte spans (whitespace/comment runs), sorted and disjoint.
    pub trivia_runs: &'a [TextRange],
    /// Per-`import` records (module name + statement byte range), in source order.
    /// Syntax-aware rules (e.g. `imports/sorted`) read these; pure-text rules ignore
    /// them. Defaults to empty for contexts built without a parsed header.
    pub imports: &'a [ImportRecord],
    /// Per top-level command regions (byte range + kind), in parse order. Layout rules
    /// (e.g. `layout/blank-lines`) key on these boundaries so they only ever edit trivia
    /// *between* commands. Defaults to empty for contexts built without a parsed body.
    pub regions: &'a [SyntaxRegion],
}

impl<'a> RuleContext<'a> {
    /// Construct a context from source text, its path, and the parsed trivia runs.
    /// The import records default to empty; attach them with [`Self::with_imports`].
    #[must_use]
    pub const fn new(source: &'a str, path: &'a str, trivia_runs: &'a [TextRange]) -> Self {
        Self {
            source,
            path,
            trivia_runs,
            imports: &[],
            regions: &[],
        }
    }

    /// Attach the parsed per-`import` records, for syntax-aware import rules.
    #[must_use]
    pub fn with_imports(mut self, imports: &'a [ImportRecord]) -> Self {
        self.imports = imports;
        self
    }

    /// Attach the parsed top-level command regions, for layout rules.
    #[must_use]
    pub fn with_regions(mut self, regions: &'a [SyntaxRegion]) -> Self {
        self.regions = regions;
        self
    }

    /// Whether `range` lies entirely within a single trivia run — i.e. editing it cannot
    /// touch any token. A range that straddles a token boundary is not trivia-safe.
    #[must_use]
    pub fn is_trivia(&self, range: TextRange) -> bool {
        self.trivia_runs
            .iter()
            .any(|run| run.start <= range.start && range.end <= run.end)
    }
}

/// The signature every rule implementation shares.
type RuleFn = fn(&RuleContext<'_>) -> Vec<Diagnostic>;

/// Map a stable rule id to its implementation, if one exists yet.
fn rule_impl(id: &str) -> Option<RuleFn> {
    match id {
        "text/trailing-whitespace" => Some(text::trailing_whitespace),
        "text/final-newline" => Some(text::final_newline),
        "imports/sorted" => Some(imports::sorted),
        "layout/blank-lines" => Some(layout::blank_lines),
        "layout/end-name" => Some(layout::end_name),
        _ => None,
    }
}

/// Run every active, implemented rule over `ctx` and collect the diagnostics, in registry
/// order.
#[must_use]
pub fn check(ctx: &RuleContext<'_>, selection: &RuleSelection) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    for rule in registry() {
        if !selection.is_active(rule, ctx.path) {
            continue;
        }
        if let Some(run_rule) = rule_impl(rule.id()) {
            diagnostics.extend(run_rule(ctx));
        }
    }
    diagnostics
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

    use lean_fmt_edit::TextRange;

    use super::{RuleContext, check};
    use crate::selection::RuleSelection;

    /// The complement of `tokens` within `[0, len)`: the trivia runs a real parse would
    /// report. Lets tests describe token spans and derive the trivia model from them.
    fn trivia_complement(len: usize, tokens: &[TextRange]) -> Vec<TextRange> {
        let mut runs = Vec::new();
        let mut cursor = 0usize;
        for token in tokens {
            if token.start > cursor {
                runs.push(TextRange::new(cursor, token.start));
            }
            cursor = cursor.max(token.end);
        }
        if cursor < len {
            runs.push(TextRange::new(cursor, len));
        }
        runs
    }

    #[test]
    fn selection_gates_which_rules_run() {
        // `def a := 1` then two trailing spaces and a missing final newline.
        let source = "def a := 1  ";
        let tokens = [
            TextRange::new(0, 3),
            TextRange::new(4, 5),
            TextRange::new(6, 8),
            TextRange::new(9, 10),
        ];
        let runs = trivia_complement(source.len(), &tokens);
        let ctx = RuleContext::new(source, "A.lean", &runs);

        // With everything active, both text rules fire.
        let all = check(&ctx, &RuleSelection::default());
        assert_eq!(all.len(), 2);

        // Ignoring the trailing-whitespace rule leaves only the final-newline finding.
        let ignore_ws = RuleSelection::new(
            Vec::new(),
            vec!["text/trailing-whitespace".to_owned()],
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        let some = check(&ctx, &ignore_ws);
        assert_eq!(some.len(), 1);
        assert_eq!(some[0].rule.as_str(), "text/final-newline");

        // Ignoring everything yields no diagnostics.
        let ignore_all = RuleSelection::new(
            Vec::new(),
            vec!["all".to_owned()],
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
        );
        assert!(check(&ctx, &ignore_all).is_empty());
    }

    #[test]
    fn clean_source_yields_no_diagnostics() {
        let source = "def a := 1\n";
        let tokens = [
            TextRange::new(0, 3),
            TextRange::new(4, 5),
            TextRange::new(6, 8),
            TextRange::new(9, 10),
        ];
        let runs = trivia_complement(source.len(), &tokens);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        assert!(check(&ctx, &RuleSelection::default()).is_empty());
    }
}
