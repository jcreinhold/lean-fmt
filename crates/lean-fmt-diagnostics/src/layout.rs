//! Block-layout rules over the parser-derived command regions ([`RuleContext::regions`]).
//!
//! - `layout/blank-lines` collapses excess blank lines *between* top-level commands,
//!   editing only trivia and never a token or a comment. The gap between two consecutive
//!   command regions is pure inter-command trivia (whitespace plus line/block comments);
//!   within each gap a run of two or more blank lines (three or more newlines) collapses
//!   to a single blank line. It never scans inside a command region, so blank lines within
//!   a multi-line proof body are left untouched — the stop-rule "edit only between
//!   commands".
//! - `layout/end-name` pairs each `end` with the `namespace`/`section` it closes using the
//!   parser's command kinds (a stack, never a text scan for `end`), and appends the block's
//!   name to a *bare* `end` that closes a *named* block. It only ever appends — never
//!   rewrites or removes an existing end name, and never touches an anonymous section's
//!   bare `end`.

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;
use crate::text::detect_eol;

/// Command kind of a `namespace` opener.
const NAMESPACE_KIND: &str = "Lean.Parser.Command.namespace";
/// Command kind of a `section` opener.
const SECTION_KIND: &str = "Lean.Parser.Command.section";
/// Command kind of an `end` closer.
const END_KIND: &str = "Lean.Parser.Command.end";

/// Read the name following `keyword` in a command region's own source slice
/// (`"namespace Foo"` with `"namespace"` → `"Foo"`; `"section"` → `""`).
fn name_after_keyword(source: &str, range: TextRange, keyword: &str) -> String {
    let slice = source.get(range.start..range.end).unwrap_or("");
    slice.strip_prefix(keyword).unwrap_or("").trim().to_owned()
}

/// `layout/end-name`: append the block name to a bare `end` closing a named block.
///
/// Walks the command regions maintaining a stack of open blocks (name, empty for an
/// anonymous section). On each `end`, pops the top block; if that block is named and the
/// `end` is bare, emits a `Safe` insertion appending `" {name}"`. Unmatched `end`s (stack
/// underflow), anonymous-block ends, and already-named ends are left untouched.
#[must_use]
pub(crate) fn end_name(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let source = ctx.source;
    let mut stack: Vec<String> = Vec::new();
    let mut diagnostics = Vec::new();
    for region in ctx.regions {
        match region.kind.as_str() {
            NAMESPACE_KIND => stack.push(name_after_keyword(source, region.range, "namespace")),
            SECTION_KIND => stack.push(name_after_keyword(source, region.range, "section")),
            END_KIND => {
                let Some(block_name) = stack.pop() else {
                    // Unmatched `end` (stack underflow): not ours to touch.
                    continue;
                };
                if block_name.is_empty() {
                    // Anonymous block: its `end` must stay bare.
                    continue;
                }
                if !name_after_keyword(source, region.range, "end").is_empty() {
                    // Already named: never rewrite an existing (possibly mismatched) name.
                    continue;
                }
                let pos = region.range.end;
                let insertion = format!(" {block_name}");
                let edit = TextEdit::insert(pos, &insertion);
                diagnostics.push(Diagnostic {
                    rule: RuleId::new("layout/end-name"),
                    message: format!("bare `end` should name its block: `end {block_name}`"),
                    range: TextRange::new(pos, pos),
                    applicability: Applicability::Safe,
                    fix: Some(EditSet { edits: vec![edit] }),
                });
            }
            _ => {}
        }
    }
    diagnostics
}

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

    use super::{blank_lines, end_name};
    use crate::engine::RuleContext;

    /// A command region over `[start, end)`; the line/column is irrelevant to the rule.
    fn region(start: usize, end: usize) -> SyntaxRegion {
        region_kind("Lean.Parser.Command.declaration", start, end)
    }

    /// A command region with an explicit node kind over `[start, end)`.
    fn region_kind(kind: &str, start: usize, end: usize) -> SyntaxRegion {
        SyntaxRegion {
            kind: kind.to_owned(),
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

    fn ns(start: usize, end: usize) -> SyntaxRegion {
        region_kind("Lean.Parser.Command.namespace", start, end)
    }
    fn sec(start: usize, end: usize) -> SyntaxRegion {
        region_kind("Lean.Parser.Command.section", start, end)
    }
    fn end_region(start: usize, end: usize) -> SyntaxRegion {
        region_kind("Lean.Parser.Command.end", start, end)
    }

    fn run_end(source: &str, regions: &[SyntaxRegion]) -> Vec<lean_fmt_edit::Diagnostic> {
        let ctx = RuleContext::new(source, "A.lean", &[]).with_regions(regions);
        end_name(&ctx)
    }

    #[test]
    fn names_a_bare_end_and_is_idempotent() {
        let source = "namespace Foo\ndef a := 1\nend\n";
        let regions = [ns(0, 13), region(14, 24), end_region(25, 28)];
        let diagnostics = run_end(source, &regions);
        assert_eq!(diagnostics.len(), 1);
        let out = apply_all(source, &diagnostics);
        assert_eq!(out, "namespace Foo\ndef a := 1\nend Foo\n");
        // Re-run: the `end` now reads `end Foo` (region widened), so nothing to do.
        let regions2 = [ns(0, 13), region(14, 24), end_region(25, 32)];
        assert!(run_end(&out, &regions2).is_empty());
    }

    #[test]
    fn nested_blocks_pair_to_the_right_names() {
        let source = "namespace Foo\nsection Bar\ndef a := 1\nend\nend\n";
        let regions = [
            ns(0, 13),
            sec(14, 25),
            region(26, 36),
            end_region(37, 40),
            end_region(41, 44),
        ];
        let out = apply_all(source, &run_end(source, &regions));
        assert_eq!(out, "namespace Foo\nsection Bar\ndef a := 1\nend Bar\nend Foo\n");
    }

    #[test]
    fn anonymous_section_end_stays_bare() {
        let source = "section\ndef a := 1\nend\n";
        let regions = [sec(0, 7), region(8, 18), end_region(19, 22)];
        assert!(run_end(source, &regions).is_empty());
    }

    #[test]
    fn already_named_end_is_untouched() {
        let source = "namespace Foo\nend Foo\n";
        let regions = [ns(0, 13), end_region(14, 21)];
        assert!(run_end(source, &regions).is_empty());
    }

    #[test]
    fn a_mismatched_end_name_is_left_alone() {
        // `end Bar` closing `namespace Foo` is an elaboration error, but rewriting a name
        // the user typed is not the formatter's job — leave it for the user to see.
        let source = "namespace Foo\nend Bar\n";
        let regions = [ns(0, 13), end_region(14, 21)];
        assert!(run_end(source, &regions).is_empty());
    }

    #[test]
    fn an_unmatched_end_is_left_alone() {
        let source = "def a := 1\nend\n";
        let regions = [region(0, 10), end_region(11, 14)];
        assert!(run_end(source, &regions).is_empty());
    }
}
