//! Tactic-block spacing over the parser-derived tactic anchors
//! ([`RuleContext::tactics`]).
//!
//! `tactic/block-indent` normalizes the *intra-line* whitespace around a `by` block's
//! structural anchors to the conventional form:
//!
//! - exactly one space after `by` when the first tactic is on the same source line;
//! - exactly one space after a `·`/`case` step marker when the tactic follows on the
//!   same line;
//! - no trailing space between a `·`/`case` marker and a following newline.
//!
//! Every anchor byte range comes from the parse tree (the `TacticBlockRecord` built by
//! `LFMT-TACTIC-SPANS`), so the rule never scans for a token. It is deliberately
//! conservative and, crucially, **never reindents**: a tactic sequence is
//! column-significant (`Tactic.tacticSeq1Indented`, `colGe`), so the leading indentation
//! of a step determines its nesting. This rule therefore only ever edits a horizontal
//! space/tab run that lies *within a single line* and is trivia; a gap that spans a
//! newline (the leading indentation of a step) is left byte-for-byte untouched.

use std::collections::BTreeMap;

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;
use crate::spacing::{is_newline, scan_ws_right};

/// The stable id of this rule.
const RULE_ID: &str = "tactic/block-indent";

/// Whether byte range `[a, b)` of `bytes` contains a newline.
fn spans_newline(bytes: &[u8], a: usize, b: usize) -> bool {
    bytes.get(a..b).is_some_and(|s| s.iter().copied().any(is_newline))
}

/// Collect the whitespace-run normalizations for the rule, deduplicated by run so two
/// requests for the same gap collapse to a single edit. Keyed by `(start, end)`.
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

    /// Whether a whitespace run may be rewritten: an empty run is a bare token boundary
    /// (safe to insert at); a non-empty run must lie wholly within one trivia run so the
    /// edit never touches a token byte.
    fn run_is_safe(&self, start: usize, end: usize) -> bool {
        start >= end || self.ctx.is_trivia(TextRange::new(start, end))
    }

    /// Whether a line or block comment begins at byte `b`.
    fn comment_follows(&self, b: usize) -> bool {
        self.ctx
            .source
            .get(b..)
            .is_some_and(|s| s.starts_with("--") || s.starts_with("/-"))
    }

    /// Normalize the intra-line gap immediately after the anchor ending at `pos` to one
    /// space. Does nothing if the next token is on another line (the run is followed by a
    /// newline or EOF — that gap is a step's leading indentation, never reindented) or if
    /// a comment follows.
    fn one_space_after(&mut self, pos: usize) {
        let b = scan_ws_right(self.bytes, pos);
        if b >= self.bytes.len() || self.bytes.get(b).copied().is_some_and(is_newline) {
            return;
        }
        if self.comment_follows(b) {
            return;
        }
        if self.run_is_safe(pos, b) {
            self.record(pos, b, " ");
        }
    }

    /// Delete a trailing space/tab run between the anchor ending at `pos` and a following
    /// newline (or EOF). Does nothing when the run is empty, when non-whitespace follows
    /// on the same line (that is [`Self::one_space_after`]'s job), or when a comment
    /// follows.
    fn trim_before_newline(&mut self, pos: usize) {
        let b = scan_ws_right(self.bytes, pos);
        if b == pos {
            return;
        }
        if b < self.bytes.len() && !self.bytes.get(b).copied().is_some_and(is_newline) {
            return;
        }
        if self.comment_follows(b) {
            return;
        }
        if self.run_is_safe(pos, b) {
            self.record(pos, b, "");
        }
    }

    /// Record a run→target request, keeping the first target if the run is requested
    /// twice (the two callers on a marker are mutually exclusive, so this only guards
    /// against surprises).
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
                message: "tactic block spacing should be a single space".to_owned(),
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

/// `tactic/block-indent`: normalize the intra-line spacing around `by` blocks and their
/// step markers, without ever reindenting or crossing a line break.
///
/// Consumes the parsed [`RuleContext::tactics`]; emits `Safe` fixes only over
/// horizontal-whitespace runs adjacent to a parsed tactic anchor, never touching a
/// step's leading indentation (a newline-spanning gap) or editing across a comment.
#[must_use]
pub(crate) fn block_spacing(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let bytes = ctx.source.as_bytes();
    let mut reqs = Requests::new(ctx);
    for block in ctx.tactics {
        // (1) One space after `by`, but only when the first step shares the `by`'s line.
        // A `by` that ends its line begins an indented sequence whose indentation is
        // load-bearing (`colGe`) and must be preserved exactly.
        if let Some(first) = block.first_step
            && !spans_newline(bytes, block.by_kw.end, first.start)
        {
            reqs.one_space_after(block.by_kw.end);
        }
        // (2) For each `·`/`case` marker: one space before same-line content, or trim a
        // trailing space run before a newline. The two are mutually exclusive per marker.
        for bullet in &block.bullets {
            reqs.one_space_after(bullet.range.end);
            reqs.trim_before_newline(bullet.range.end);
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

    use lean_fmt_edit::{EditSet, TacticBlockRecord, TacticBulletMarker, TextRange};

    use super::block_spacing;
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

    fn cdot(start: usize, end: usize) -> TacticBulletMarker {
        TacticBulletMarker {
            kind: "cdot".to_owned(),
            range: tr(start, end),
        }
    }

    /// Apply every fix the rule emits and return the rewritten source. Fails if the fixes
    /// do not apply cleanly together (they must never overlap).
    fn apply(source: &str, tactics: &[TacticBlockRecord]) -> String {
        let runs = whitespace_trivia(source);
        let ctx = RuleContext::new(source, "A.lean", &runs).with_tactics(tactics);
        let diags = block_spacing(&ctx);
        let mut edits = Vec::new();
        for d in &diags {
            if let Some(EditSet { edits: e }) = &d.fix {
                edits.extend(e.iter().cloned());
            }
        }
        EditSet { edits }.apply(source).unwrap().output
    }

    /// A record with just a `by` keyword and same-line first step (no bullets).
    fn same_line(by: TextRange, first: TextRange) -> TacticBlockRecord {
        TacticBlockRecord {
            by_kw: by,
            seq: Some(first),
            base_column: None,
            first_step: Some(first),
            bullets: Vec::new(),
        }
    }

    #[test]
    fn same_line_by_collapses_to_one_space() {
        // `theorem t : True := by  skip` — two spaces after `by`.
        let source = "theorem t : True := by  skip\n";
        // by[20,22)  skip[24,28)
        let bytes = source.as_bytes();
        assert_eq!(&bytes[20..22], b"by");
        assert_eq!(&bytes[24..28], b"skip");
        let tactics = [same_line(tr(20, 22), tr(24, 28))];
        assert_eq!(apply(source, &tactics), "theorem t : True := by skip\n");
        // Idempotent: the single-spaced form is a fixed point.
        let out = apply(source, &tactics);
        assert_eq!(out, "theorem t : True := by skip\n");
    }

    #[test]
    fn well_spaced_same_line_by_is_untouched() {
        let source = "theorem t : True := by skip\n";
        let runs = whitespace_trivia(source);
        // by[20,22) skip[23,27)
        let tactics = [same_line(tr(20, 22), tr(23, 27))];
        let ctx = RuleContext::new(source, "A.lean", &runs).with_tactics(&tactics);
        assert!(block_spacing(&ctx).is_empty(), "already one space: no findings");
    }

    #[test]
    fn indented_by_leaves_leading_indentation_untouched() {
        // `by` ends its line; the two-step body is indented. The gap after `by` spans a
        // newline (skipped), and the leading indentation of each step is never edited.
        let source = "theorem t : True := by\n  trivial\n  trivial\n";
        // by[20,22); first step `trivial` at [25,32)
        let bytes = source.as_bytes();
        assert_eq!(&bytes[20..22], b"by");
        assert_eq!(&bytes[25..32], b"trivial");
        let tactics = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(25, 42)),
            base_column: Some(2),
            first_step: Some(tr(25, 32)),
            bullets: Vec::new(),
        }];
        assert_eq!(apply(source, &tactics), source, "indentation preserved byte-for-byte");
    }

    #[test]
    fn bullet_marker_gets_single_space() {
        // A `·` bullet crammed against its tactic.
        let source = "theorem t : True := by\n  ·  trivial\n";
        // by[20,22); `·` (2 bytes) at [25,27); "  " then trivial[29,36)
        let bytes = source.as_bytes();
        assert_eq!(&bytes[25..27], "·".as_bytes());
        assert_eq!(&bytes[29..36], b"trivial");
        let tactics = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(25, 35)),
            base_column: Some(2),
            first_step: Some(tr(25, 35)),
            bullets: vec![cdot(25, 27)],
        }];
        assert_eq!(apply(source, &tactics), "theorem t : True := by\n  · trivial\n");
    }

    #[test]
    fn bullet_trailing_space_before_newline_is_trimmed() {
        // A `·` whose tactic is on the *next* line, with a stray trailing space after the
        // marker. The space is trimmed; the leading indentation of the next line is left.
        let source = "theorem t : True := by\n  · \n    trivial\n";
        // `·` at [25,27); a single trailing space at [27,28); newline at 28.
        let bytes = source.as_bytes();
        assert_eq!(&bytes[25..27], "·".as_bytes());
        assert_eq!(&bytes[27..28], b" ");
        assert_eq!(&bytes[28..29], b"\n");
        let tactics = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(25, 39)),
            base_column: Some(2),
            first_step: Some(tr(25, 39)),
            bullets: vec![cdot(25, 27)],
        }];
        let canonical = "theorem t : True := by\n  ·\n    trivial\n";
        assert_eq!(apply(source, &tactics), canonical);
        // Idempotent: on the canonical form the `·` is immediately followed by a newline,
        // so both marker handlers no-op and the rule finds nothing. `·` still at [25,27).
        assert_eq!(&canonical.as_bytes()[25..27], "·".as_bytes());
        assert_eq!(&canonical.as_bytes()[27..28], b"\n");
        let canon_tactics = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(25, 38)),
            base_column: Some(2),
            first_step: Some(tr(25, 38)),
            bullets: vec![cdot(25, 27)],
        }];
        let runs = whitespace_trivia(canonical);
        let ctx = RuleContext::new(canonical, "A.lean", &runs).with_tactics(&canon_tactics);
        assert!(block_spacing(&ctx).is_empty(), "canonical form is a fixed point");
    }

    #[test]
    fn comment_after_by_is_preserved() {
        // A comment immediately follows `by` on the same line; the rule must not rewrite
        // the whitespace touching it.
        let source = "theorem t : True := by -- go\n  trivial\n";
        // by[20,22); the gap [22,23) is followed by `--`.
        let tactics = [TacticBlockRecord {
            by_kw: tr(20, 22),
            seq: Some(tr(31, 38)),
            base_column: Some(2),
            first_step: Some(tr(31, 38)),
            bullets: Vec::new(),
        }];
        // first_step is on the next line (after the comment), so `by`'s gap spans a
        // newline and is skipped regardless — and the comment is never touched.
        assert_eq!(apply(source, &tactics), source);
    }

    #[test]
    fn no_tactics_no_findings() {
        // An unparsed / non-tactic file yields an empty tactic-block set: nothing to do.
        let source = "def f := 1\n";
        let runs = whitespace_trivia(source);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        assert!(block_spacing(&ctx).is_empty(), "empty tactics ⇒ nothing to do");
    }
}
