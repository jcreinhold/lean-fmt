//! The `layout/blank-lines` rule: collapse excess blank lines *between* top-level
//! commands, editing only trivia and never a token or a comment.
//!
//! The rule keys on the parser-derived command regions ([`RuleContext::regions`], from
//! `LFMT-SOURCE-COORDS`): the gap between two consecutive command regions is pure
//! inter-command trivia (whitespace plus line/block comments). Within each gap it
//! collapses any run of two or more blank lines (three or more newlines) down to a single
//! blank line. It never scans inside a command region, so blank lines within a multi-line
//! proof body are left untouched — the stop-rule "edit only between commands".

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;
use crate::text::detect_eol;

/// ASCII whitespace that can make up a blank-line run.
const fn is_layout_ws(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n')
}

/// `layout/blank-lines`: collapse two-or-more consecutive blank lines between commands to
/// a single blank line. Emits one `Safe` fix per over-long whitespace run.
#[must_use]
pub(crate) fn blank_lines(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let regions = ctx.regions;
    // A gap exists only between two commands; with fewer than two there is nothing to do.
    if regions.len() < 2 {
        return Vec::new();
    }
    let source = ctx.source;
    let eol = detect_eol(source);
    let replacement = format!("{eol}{eol}");
    let mut diagnostics = Vec::new();
    for window in regions.windows(2) {
        let [prev, next] = window else { continue };
        collect_gap(ctx, prev.range.end, next.range.start, &replacement, &mut diagnostics);
    }
    diagnostics
}

/// Scan the inter-command gap `[start, end)` for whitespace runs and emit a collapse edit
/// for each run holding two or more blank lines.
fn collect_gap(ctx: &RuleContext<'_>, start: usize, end: usize, replacement: &str, diagnostics: &mut Vec<Diagnostic>) {
    if start >= end {
        return;
    }
    let bytes = ctx.source.as_bytes();
    let mut cursor = start;
    while cursor < end {
        let Some(byte) = bytes.get(cursor).copied() else {
            break;
        };
        if !is_layout_ws(byte) {
            // A comment or other trivia token: never edited; skip byte by byte (UTF-8
            // continuation bytes never match whitespace, so this stays byte-safe).
            cursor = cursor.strict_add(1);
            continue;
        }
        // Consume the maximal whitespace run, counting newlines.
        let run_start = cursor;
        let mut newlines = 0usize;
        while cursor < end {
            match bytes.get(cursor).copied() {
                Some(b) if is_layout_ws(b) => {
                    if b == b'\n' {
                        newlines = newlines.strict_add(1);
                    }
                    cursor = cursor.strict_add(1);
                }
                _ => break,
            }
        }
        // Three or more newlines == two or more blank lines: collapse to one blank line.
        if newlines < 3 {
            continue;
        }
        let range = TextRange::new(run_start, cursor);
        if !ctx.is_trivia(range) {
            continue;
        }
        let Some(expected) = ctx.source.get(run_start..cursor) else {
            continue;
        };
        if expected == replacement {
            continue;
        }
        let edit = TextEdit::replace(range, expected, replacement);
        diagnostics.push(Diagnostic {
            rule: RuleId::new("layout/blank-lines"),
            message: "too many consecutive blank lines".to_owned(),
            range,
            applicability: Applicability::Safe,
            fix: Some(EditSet { edits: vec![edit] }),
        });
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

    use lean_fmt_edit::{LineColumn, LineColumnRange, SyntaxRegion, TextRange};

    use super::blank_lines;
    use crate::engine::RuleContext;

    /// A command region over `[start, end)`; the line/column is irrelevant to the rule.
    fn region(start: usize, end: usize) -> SyntaxRegion {
        SyntaxRegion {
            kind: "Lean.Parser.Command.declaration".to_owned(),
            range: TextRange::new(start, end),
            line_column: LineColumnRange {
                start: LineColumn::new(1, 0),
                end: LineColumn::new(1, 0),
            },
        }
    }

    /// The trivia runs implied by treating each command region as one token span.
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

    fn apply_all(source: &str, diagnostics: &[lean_fmt_edit::Diagnostic]) -> String {
        let mut edits = Vec::new();
        for diagnostic in diagnostics {
            if let Some(fix) = &diagnostic.fix {
                edits.extend(fix.edits.clone());
            }
        }
        lean_fmt_edit::EditSet { edits }.apply(source).unwrap().output
    }

    /// Run the rule with `regions` as command boundaries and their spans as the tokens
    /// that define the trivia model.
    fn run(source: &str, regions: &[SyntaxRegion]) -> Vec<lean_fmt_edit::Diagnostic> {
        let tokens: Vec<TextRange> = regions.iter().map(|r| r.range).collect();
        let runs = trivia_complement(source.len(), &tokens);
        let ctx = RuleContext::new(source, "A.lean", &runs).with_regions(regions);
        blank_lines(&ctx)
    }

    #[test]
    fn collapses_excess_blank_lines_and_is_idempotent() {
        let source = "def a := 1\n\n\n\ndef b := 2\n";
        let regions = [region(0, 10), region(14, 24)];
        let diagnostics = run(source, &regions);
        assert_eq!(diagnostics.len(), 1);
        let out = apply_all(source, &diagnostics);
        assert_eq!(out, "def a := 1\n\ndef b := 2\n");
        // Re-run on the collapsed output (regions shifted) — no further edits.
        let regions2 = [region(0, 10), region(12, 22)];
        assert!(run(&out, &regions2).is_empty());
    }

    #[test]
    fn single_blank_line_is_untouched() {
        let source = "def a := 1\n\ndef b := 2\n";
        let regions = [region(0, 10), region(12, 22)];
        assert!(run(source, &regions).is_empty());
    }

    #[test]
    fn a_comment_between_commands_keeps_its_line() {
        // Four newlines then a comment then the next command. The blank run before the
        // comment collapses to one blank line; the comment is never touched or merged.
        let source = "def a := 1\n\n\n\n-- note\ndef b := 2\n";
        let regions = [region(0, 10), region(22, 32)];
        let out = apply_all(source, &run(source, &regions));
        assert_eq!(out, "def a := 1\n\n-- note\ndef b := 2\n");
        // Idempotent: recompute regions over the collapsed text and re-run.
        let regions2 = [region(0, 10), region(20, 30)];
        assert!(run(&out, &regions2).is_empty());
    }

    #[test]
    fn blank_lines_inside_a_command_are_left_alone() {
        // The blank lines sit *inside* region a's span (a multi-line body), not in the
        // gap between a and b, so the rule must not touch them.
        let source = "def a :=\n\n\n\nrfl\ndef b := 2\n";
        let regions = [region(0, 15), region(16, 26)];
        assert!(run(source, &regions).is_empty());
    }

    #[test]
    fn crlf_runs_collapse_to_crlf() {
        let source = "def a := 1\r\n\r\n\r\n\r\ndef b := 2\r\n";
        let regions = [region(0, 10), region(18, 28)];
        let out = apply_all(source, &run(source, &regions));
        assert_eq!(out, "def a := 1\r\n\r\ndef b := 2\r\n");
    }
}
