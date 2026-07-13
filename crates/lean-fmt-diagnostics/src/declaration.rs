//! Declaration-header spacing over the parser-derived header spans
//! ([`RuleContext::decls`]).
//!
//! `declaration/header-spacing` normalizes the horizontal-whitespace gap around each
//! header delimiter of a `def`/`theorem`/`structure`/… to the conventional form: exactly
//! one space around the return-type `:`, the binder `:`, `:=`, `where`, and between the
//! keyword/name/binders; and *no* space just inside a binder's `(`/`{`/`[` delimiters.
//!
//! Every anchor is a delimiter atom whose byte range comes from the parse tree (the
//! `DeclHeaderRecord` built by `LFMT-DECL-SPANS`), so the rule never scans for a token or
//! guesses which gap flanks which delimiter. It is deliberately conservative:
//!
//! - it only ever rewrites a run of ASCII spaces/tabs — never a byte inside a token, and
//!   (for a non-empty run) only when that run is trivia;
//! - it never touches a gap that spans a line break (a wrapped binder or a `where` at
//!   end of line is left exactly as written — the "never join lines" stop-rule);
//! - it never edits across a comment (`--`/`/- -/`), so a comment between header tokens
//!   is preserved verbatim.
//!
//! Because a gap is shared by the delimiter on each side, the two requests for it collapse
//! to one edit (keyed by the run), and re-running the rule on its own output is a fixed
//! point.

use std::collections::BTreeMap;

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;
use crate::spacing::{is_newline, scan_ws_left, scan_ws_right};

/// The stable id of this rule.
const RULE_ID: &str = "declaration/header-spacing";

/// Collect the whitespace-run normalizations for the rule, deduplicated by run so a gap
/// shared by two delimiters yields a single edit. Keyed by `(start, end)` of the run.
struct Requests<'a> {
    ctx: &'a RuleContext<'a>,
    bytes: &'a [u8],
    /// run range → target text (`" "` or `""`).
    runs: BTreeMap<(usize, usize), &'static str>,
}

impl<'a> Requests<'a> {
    fn new(ctx: &'a RuleContext<'a>) -> Self {
        Self {
            ctx,
            bytes: ctx.source.as_bytes(),
            runs: BTreeMap::new(),
        }
    }

    /// Whether a non-empty whitespace run may be rewritten: it must lie wholly within a
    /// trivia run (never inside a token). An empty run is a bare token boundary and is
    /// handled by the caller.
    fn run_is_safe(&self, start: usize, end: usize) -> bool {
        start >= end || self.ctx.is_trivia(TextRange::new(start, end))
    }

    /// Request exactly one space (or `""`) immediately *before* the delimiter starting at
    /// `pos`. Skips a gap at start-of-file, after a line break, or after a block comment.
    fn before(&mut self, pos: usize, target: &'static str) {
        let a = scan_ws_left(self.bytes, pos);
        // Start of file, or the run is this line's leading indentation: leave it.
        if a == 0 {
            return;
        }
        if self.bytes.get(a.saturating_sub(1)).copied().is_some_and(is_newline) {
            return;
        }
        // A block comment immediately precedes: preserve it (never edit across a comment).
        if self.ctx.source.get(..a).is_some_and(|s| s.ends_with("-/")) {
            return;
        }
        if self.run_is_safe(a, pos) {
            self.record(a, pos, target);
        }
    }

    /// Request exactly one space (or `""`) immediately *after* the delimiter ending at
    /// `pos`. Skips a gap at end-of-file, before a line break, or before a comment.
    fn after(&mut self, pos: usize, target: &'static str) {
        let b = scan_ws_right(self.bytes, pos);
        if b >= self.bytes.len() {
            return;
        }
        if self.bytes.get(b).copied().is_some_and(is_newline) {
            return;
        }
        // A line or block comment immediately follows: preserve it.
        if self
            .ctx
            .source
            .get(b..)
            .is_some_and(|s| s.starts_with("--") || s.starts_with("/-"))
        {
            return;
        }
        if self.run_is_safe(pos, b) {
            self.record(pos, b, target);
        }
    }

    /// Record a run→target request, keeping the first target if a run is requested twice
    /// (a shared gap's two sides always agree, so this only guards against surprises).
    fn record(&mut self, start: usize, end: usize, target: &'static str) {
        self.runs.entry((start, end)).or_insert(target);
    }

    /// Turn the collected requests into one diagnostic per run whose current text differs
    /// from its target.
    fn into_diagnostics(self) -> Vec<Diagnostic> {
        let mut diagnostics = Vec::new();
        for ((start, end), target) in self.runs {
            let Some(current) = self.ctx.source.get(start..end) else {
                continue;
            };
            if current == target {
                continue;
            }
            let range = TextRange::new(start, end);
            diagnostics.push(Diagnostic {
                rule: RuleId::new(RULE_ID),
                message: "declaration header spacing should be a single space".to_owned(),
                range,
                applicability: Applicability::Safe,
                fix: Some(EditSet {
                    edits: vec![TextEdit::replace(range, current, target)],
                }),
            });
        }
        diagnostics
    }
}

/// `declaration/header-spacing`: normalize the whitespace around a declaration header's
/// delimiters to the conventional single-space (or tight-binder) form.
///
/// Consumes the parsed [`RuleContext::decls`]; emits `Safe` fixes only over
/// horizontal-whitespace runs adjacent to a parsed delimiter, never joining lines or
/// editing across a comment.
#[must_use]
pub(crate) fn header_spacing(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let mut reqs = Requests::new(ctx);
    for decl in ctx.decls {
        // One space after the kind keyword (before the name or first signature token).
        if let Some(k) = decl.keyword {
            reqs.after(k.end, " ");
        }
        for binder in &decl.binders {
            if let Some(open) = binder.open {
                // A space before the binder group, but none just inside the delimiter.
                reqs.before(open.start, " ");
                reqs.after(open.end, "");
            }
            if let Some(colon) = binder.colon {
                reqs.before(colon.start, " ");
                reqs.after(colon.end, " ");
            }
            if let Some(close) = binder.close {
                reqs.before(close.start, "");
            }
        }
        if let Some(sig) = decl.sig_colon {
            reqs.before(sig.start, " ");
            reqs.after(sig.end, " ");
        }
        if let Some(assign) = decl.assign {
            reqs.before(assign.start, " ");
            reqs.after(assign.end, " ");
        }
        if let Some(where_kw) = decl.where_kw {
            reqs.before(where_kw.start, " ");
        }
    }
    reqs.into_diagnostics()
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::panic,
        clippy::arithmetic_side_effects,
        clippy::literal_string_with_formatting_args
    )]

    use lean_fmt_edit::{BinderSpan, DeclHeaderRecord, EditSet, TextRange};

    use super::header_spacing;
    use crate::engine::RuleContext;

    /// Maximal runs of ASCII whitespace in `source` — a faithful trivia model for
    /// comment-free sources (inter-token whitespace is exactly the trivia).
    fn whitespace_trivia(source: &str) -> Vec<TextRange> {
        let bytes = source.as_bytes();
        let mut runs = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i].is_ascii_whitespace() {
                let start = i;
                while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                    i += 1;
                }
                runs.push(TextRange::new(start, i));
            } else {
                i += 1;
            }
        }
        runs
    }

    fn tr(start: usize, end: usize) -> TextRange {
        TextRange::new(start, end)
    }

    /// Apply every fix the rule emits and return the rewritten source. Fails if the fixes
    /// do not apply cleanly together (they must never overlap).
    fn apply(source: &str, decls: &[DeclHeaderRecord]) -> String {
        let runs = whitespace_trivia(source);
        let ctx = RuleContext::new(source, "A.lean", &runs).with_decls(decls);
        let diags = header_spacing(&ctx);
        let mut edits = Vec::new();
        for d in &diags {
            if let Some(EditSet { edits: e }) = &d.fix {
                edits.extend(e.iter().cloned());
            }
        }
        lean_fmt_edit::EditSet { edits }.apply(source).unwrap().output
    }

    /// The header record for `def f (x : Nat) : Nat := x + 1` (byte offsets from the
    /// live parse in prompt 18).
    fn def_record() -> DeclHeaderRecord {
        DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 30),
            keyword: Some(tr(0, 3)),
            name: Some(tr(4, 5)),
            binders: vec![BinderSpan {
                range: tr(6, 15),
                open: Some(tr(6, 7)),
                close: Some(tr(14, 15)),
                colon: Some(tr(9, 10)),
            }],
            sig_colon: Some(tr(16, 17)),
            assign: Some(tr(22, 24)),
            where_kw: None,
        }
    }

    #[test]
    fn well_spaced_header_is_untouched_and_idempotent() {
        let source = "def f (x : Nat) : Nat := x + 1\n";
        let ctx_runs = whitespace_trivia(source);
        let decls = [def_record()];
        let ctx = RuleContext::new(source, "A.lean", &ctx_runs).with_decls(&decls);
        assert!(header_spacing(&ctx).is_empty(), "already conventional: no findings");
        assert_eq!(apply(source, &decls), source, "idempotent no-op");
    }

    #[test]
    fn crammed_header_gets_single_spaces() {
        // No spaces anywhere the delimiters allow one.
        let source = "def  h(x:Nat):Nat:=x\n";
        // Offsets: def[0,3) name h[5,6) '(' [6,7) ':'[8,9) ')'[12,13)
        //          sig ':'[13,14) ':='[17,19)
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 20),
            keyword: Some(tr(0, 3)),
            name: Some(tr(5, 6)),
            binders: vec![BinderSpan {
                range: tr(6, 13),
                open: Some(tr(6, 7)),
                close: Some(tr(12, 13)),
                colon: Some(tr(8, 9)),
            }],
            sig_colon: Some(tr(13, 14)),
            assign: Some(tr(17, 19)),
            where_kw: None,
        }];
        assert_eq!(apply(source, &decls), "def h (x : Nat) : Nat := x\n");
        // Idempotent: re-running on the output makes no further change.
        let out = apply(source, &decls);
        // The output offsets differ, but a well-spaced header (see the first test) is a
        // fixed point; assert the crammed→spaced result equals the canonical form.
        assert_eq!(out, "def h (x : Nat) : Nat := x\n");
    }

    #[test]
    fn extra_spaces_collapse_to_one() {
        let source = "def   f  :  Nat  :=  x\n";
        // def[0,3) f[6,7) sig ':'[9,10) ':='[17,19)
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 22),
            keyword: Some(tr(0, 3)),
            name: Some(tr(6, 7)),
            binders: vec![],
            sig_colon: Some(tr(9, 10)),
            assign: Some(tr(17, 19)),
            where_kw: None,
        }];
        assert_eq!(apply(source, &decls), "def f : Nat := x\n");
    }

    #[test]
    fn tabs_are_normalized_to_a_space() {
        let source = "def\tf\t:=\tx\n";
        // def[0,3) f[4,5) ':='[6,8)
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 9),
            keyword: Some(tr(0, 3)),
            name: Some(tr(4, 5)),
            binders: vec![],
            sig_colon: None,
            assign: Some(tr(6, 8)),
            where_kw: None,
        }];
        assert_eq!(apply(source, &decls), "def f := x\n");
    }

    #[test]
    fn a_wrapped_line_is_never_joined() {
        // The `:=` sits at the end of its line; the value is on the next line. The gap
        // after `:=` spans a newline, so it must be left alone.
        let source = "def f : Nat :=\n  x\n";
        // def[0,3) f[4,5) sig ':'[6,7) ':='[12,14)
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 18),
            keyword: Some(tr(0, 3)),
            name: Some(tr(4, 5)),
            binders: vec![],
            sig_colon: Some(tr(6, 7)),
            assign: Some(tr(12, 14)),
            where_kw: None,
        }];
        assert_eq!(apply(source, &decls), source, "newline gap left intact");
    }

    #[test]
    fn a_comment_between_header_tokens_is_preserved() {
        // A block comment sits between the name and the `:=`. The rule must not rewrite
        // the whitespace touching the comment (which would risk merging or dropping it).
        let source = "def f /- keep -/ := x\n";
        // def[0,3) f[4,5) ':='[17,19)
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.definition".to_owned(),
            range: tr(0, 21),
            keyword: Some(tr(0, 3)),
            name: Some(tr(4, 5)),
            binders: vec![],
            sig_colon: None,
            assign: Some(tr(17, 19)),
            where_kw: None,
        }];
        // The space before `:=` follows `-/`, so it is not touched; the space after `:=`
        // is normal and already one space. Result is unchanged.
        assert_eq!(apply(source, &decls), source);
    }

    #[test]
    fn structure_where_and_example_shapes() {
        // A `structure` has a `where` but no `:=`/return-colon; already-clean input is a
        // no-op. An anonymous `example` has no name; its `:` and `:=` still normalize.
        let struct_src = "structure S where\n  x : Nat\n";
        let struct_decl = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.structure".to_owned(),
            range: tr(0, 27),
            keyword: Some(tr(0, 9)),
            name: Some(tr(10, 11)),
            binders: vec![],
            sig_colon: None,
            assign: None,
            where_kw: Some(tr(12, 17)),
        }];
        assert_eq!(apply(struct_src, &struct_decl), struct_src, "clean structure untouched");

        let ex_src = "example:True:=trivial\n";
        // example[0,7) sig ':'[7,8) ':='[12,14)
        let ex_decl = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.example".to_owned(),
            range: tr(0, 21),
            keyword: Some(tr(0, 7)),
            name: None,
            binders: vec![],
            sig_colon: Some(tr(7, 8)),
            assign: Some(tr(12, 14)),
            where_kw: None,
        }];
        assert_eq!(apply(ex_src, &ex_decl), "example : True := trivial\n");
    }

    #[test]
    fn implicit_and_instance_binders_space_correctly() {
        // `{α : Type}` normalizes its inner colon; `[Add α]` has no colon and stays tight.
        let source = "theorem t{α:Type}[Add α]:a=a:=rfl\n";
        // Byte layout (α is 2 bytes): theorem[0,7) t[8,9)
        //   '{'[9,10) α[10,12) ':'[12,13) Type[13,17) '}'[17,18)
        //   '['[18,19) Add[19,22) ' '? none: "Add α" α[23,25) ']'[25,26)
        //   sig ':'[26,27) ... ':='[30,32)
        let bytes = source.as_bytes();
        assert_eq!(&bytes[9..10], b"{");
        assert_eq!(&bytes[12..13], b":");
        assert_eq!(&bytes[18..19], b"[");
        let decls = [DeclHeaderRecord {
            kind: "Lean.Parser.Command.theorem".to_owned(),
            range: tr(0, 33),
            keyword: Some(tr(0, 7)),
            name: Some(tr(8, 9)),
            binders: vec![
                BinderSpan {
                    range: tr(9, 18),
                    open: Some(tr(9, 10)),
                    close: Some(tr(17, 18)),
                    colon: Some(tr(12, 13)),
                },
                BinderSpan {
                    range: tr(18, 26),
                    open: Some(tr(18, 19)),
                    close: Some(tr(25, 26)),
                    colon: None,
                },
            ],
            sig_colon: Some(tr(26, 27)),
            assign: Some(tr(30, 32)),
            where_kw: None,
        }];
        assert_eq!(apply(source, &decls), "theorem t {α : Type} [Add α] : a=a := rfl\n");
    }

    #[test]
    fn no_decls_no_findings() {
        let source = "def f := x\n";
        let runs = whitespace_trivia(source);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        assert!(header_spacing(&ctx).is_empty(), "empty decls ⇒ nothing to do");
    }
}
