//! The `imports/sorted` rule: sort import statements, drop duplicate imports, and
//! normalize blank lines inside the import block — without ever detaching a comment from
//! the import it describes, or dropping a modifier.
//!
//! This is the first rule that needs Lean syntax analysis: an import statement's module
//! name and exact byte range come from the parser ([`RuleContext::imports`]), not a text
//! scan. The rule works at the granularity of whole physical lines, so a reordered
//! statement always carries its full text (modifiers and any trailing comment) with it.
//!
//! It is deliberately conservative: if the import block contains anything it cannot prove
//! safe to reorder — a non-import/comment/blank line, a comment separated from its import
//! by a blank line (ambiguous attachment), or a trailing comment at the block's end — it
//! emits no fix at all.

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;
use crate::text::detect_eol;

/// A reorderable unit: an import statement plus the full-line comments that immediately
/// precede it (its "attached" documentation), keyed by the imported module name.
struct Unit {
    /// The imported module name — the sort key.
    module: String,
    /// The byte ranges of this unit's physical lines, in order (leading comment lines
    /// then the import line), each `end` including the line's newline where present.
    lines: Vec<(usize, usize)>,
    /// Whether this is a bare `import X` line: no leading comments and no trailing
    /// comment on the import line. Only bare units are eligible for deduplication.
    bare: bool,
}

/// How a physical line inside the import block is classified.
enum LineKind {
    /// An import statement line; the payload indexes [`RuleContext::imports`].
    Import(usize),
    /// A full-line `--` comment.
    Comment,
    /// A blank (whitespace-only) line.
    Blank,
    /// Anything else — makes the block ineligible for reordering.
    Other,
}

/// The byte offset of the start of the line containing `pos`.
fn line_start(source: &str, pos: usize) -> usize {
    match source.get(..pos).and_then(|s| s.rfind('\n')) {
        Some(nl) => nl.strict_add(1),
        None => 0,
    }
}

/// The byte offset just past the newline ending the line containing `pos` (or the end of
/// source when the line is unterminated).
fn line_end(source: &str, pos: usize) -> usize {
    match source.get(pos..).and_then(|s| s.find('\n')) {
        Some(off) => pos.strict_add(off).strict_add(1),
        None => source.len(),
    }
}

/// Split `[start, end)` into physical lines, each `end` including its trailing newline.
fn split_lines(source: &str, start: usize, end: usize) -> Vec<(usize, usize)> {
    let mut lines = Vec::new();
    let mut cursor = start;
    while cursor < end {
        let rest = source.get(cursor..end).unwrap_or("");
        let stop = match rest.find('\n') {
            Some(off) => cursor.strict_add(off).strict_add(1),
            None => end,
        };
        lines.push((cursor, stop));
        cursor = stop;
    }
    lines
}

/// Classify one line of the block.
fn classify(ctx: &RuleContext<'_>, line: (usize, usize)) -> LineKind {
    let (start, end) = line;
    if let Some(idx) = ctx
        .imports
        .iter()
        .position(|imp| imp.range.start >= start && imp.range.start < end)
    {
        return LineKind::Import(idx);
    }
    let text = ctx.source.get(start..end).unwrap_or("").trim();
    if text.is_empty() {
        LineKind::Blank
    } else if text.starts_with("--") {
        LineKind::Comment
    } else {
        LineKind::Other
    }
}

/// Render a unit's normalized text: its lines verbatim, each guaranteed to end in `eol`
/// (only the block's final line can lack a newline, and gains one so units concatenate
/// cleanly).
fn unit_text(source: &str, unit: &Unit, eol: &str) -> String {
    let mut out = String::new();
    for &(start, end) in &unit.lines {
        let slice = source.get(start..end).unwrap_or("");
        out.push_str(slice);
        if !slice.ends_with('\n') {
            out.push_str(eol);
        }
    }
    out
}

/// Whether an import line (trimmed of trailing whitespace/newline) carries a trailing
/// `--` comment after the statement.
fn has_trailing_comment(line: &str) -> bool {
    // A `--` anywhere past the `import` keyword on the line is a trailing comment. Import
    // statements never legitimately contain `--`, so this is a sound over-approximation:
    // if present, the unit is treated as non-bare and never deduplicated.
    line.contains("--")
}

/// `imports/sorted`: reorder the import block, drop duplicate bare imports, and remove
/// blank lines between imports. Emits at most one `Safe` fix rewriting the whole block.
#[must_use]
pub(crate) fn sorted(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let imports = ctx.imports;
    // Sorting, deduplication, and inter-import blank removal all need at least two
    // imports; a single import (or none) has nothing to normalize.
    if imports.len() < 2 {
        return Vec::new();
    }
    let source = ctx.source;

    // The block spans from the first import's line through the last import's line.
    let Some(first) = imports.first() else {
        return Vec::new();
    };
    let Some(last) = imports.last() else {
        return Vec::new();
    };
    let block_start = line_start(source, first.range.start);
    let block_end = line_end(source, last.range.end);
    let Some(old_block) = source.get(block_start..block_end) else {
        return Vec::new();
    };

    // Group lines into reorderable units, bailing out on anything ambiguous.
    let mut units: Vec<Unit> = Vec::new();
    let mut pending: Vec<(usize, usize)> = Vec::new();
    for line in split_lines(source, block_start, block_end) {
        match classify(ctx, line) {
            LineKind::Other => return Vec::new(),
            LineKind::Comment => pending.push(line),
            LineKind::Blank => {
                // A comment then a blank line then an import: the comment's attachment is
                // ambiguous, so we refuse to reorder the block at all.
                if !pending.is_empty() {
                    return Vec::new();
                }
            }
            LineKind::Import(idx) => {
                let Some(record) = imports.get(idx) else {
                    return Vec::new();
                };
                let had_comments = !pending.is_empty();
                let line_text = source.get(line.0..line.1).unwrap_or("");
                let bare = !had_comments && !has_trailing_comment(line_text);
                let mut lines = std::mem::take(&mut pending);
                lines.push(line);
                units.push(Unit {
                    module: record.module.clone(),
                    lines,
                    bare,
                });
            }
        }
    }
    // A comment with no import after it (trailing docs at the block's end) is ambiguous.
    if !pending.is_empty() {
        return Vec::new();
    }

    // Stable sort by module name keeps equal-module units in source order.
    units.sort_by(|a, b| a.module.cmp(&b.module));

    // Drop adjacent duplicate bare imports (identical module, both bare).
    let mut kept: Vec<Unit> = Vec::new();
    for unit in units {
        let is_duplicate = unit.bare && kept.last().is_some_and(|prev| prev.bare && prev.module == unit.module);
        if is_duplicate {
            continue;
        }
        kept.push(unit);
    }

    let eol = detect_eol(source);
    let mut new_block = String::new();
    for unit in &kept {
        new_block.push_str(&unit_text(source, unit, eol));
    }

    if new_block == old_block {
        return Vec::new();
    }
    let range = TextRange::new(block_start, block_end);
    let edit = TextEdit::replace(range, old_block, &new_block);
    vec![Diagnostic {
        rule: RuleId::new("imports/sorted"),
        message: "imports are not sorted".to_owned(),
        range,
        applicability: Applicability::Safe,
        fix: Some(EditSet { edits: vec![edit] }),
    }]
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

    use lean_fmt_edit::{ImportRecord, TextRange};

    use super::sorted;
    use crate::engine::RuleContext;

    /// Build import records from the source by locating each `import <module>` line.
    /// Mirrors what the Lean parser reports: one record per statement, in source order.
    fn imports_of(source: &str) -> Vec<ImportRecord> {
        let mut records = Vec::new();
        let mut offset = 0usize;
        for line in source.split_inclusive('\n') {
            let trimmed = line.trim_end();
            if let Some(rest) = trimmed.strip_prefix("import ") {
                // The statement range runs from `import` through the module ident; ignore
                // any trailing `-- comment` for the range's end.
                let module = rest.split_whitespace().last().unwrap_or("").to_owned();
                let stmt = trimmed.split("--").next().unwrap_or(trimmed).trim_end();
                records.push(ImportRecord {
                    module,
                    range: TextRange::new(offset, offset + stmt.len()),
                });
            }
            offset += line.len();
        }
        records
    }

    /// Apply every diagnostic's fix to `source` and return the rewritten text.
    fn apply_all(source: &str, diagnostics: &[lean_fmt_edit::Diagnostic]) -> String {
        let mut edits = Vec::new();
        for diagnostic in diagnostics {
            if let Some(fix) = &diagnostic.fix {
                edits.extend(fix.edits.clone());
            }
        }
        lean_fmt_edit::EditSet { edits }.apply(source).unwrap().output
    }

    fn run(source: &str) -> Vec<lean_fmt_edit::Diagnostic> {
        let imports = imports_of(source);
        let ctx = RuleContext::new(source, "A.lean", &[]).with_imports(&imports);
        sorted(&ctx)
    }

    #[test]
    fn sorts_and_is_idempotent() {
        let source = "import B.Y\nimport A.X\n\ndef f := 1\n";
        let diagnostics = run(source);
        assert_eq!(diagnostics.len(), 1);
        let out = apply_all(source, &diagnostics);
        // The blank line before the body sits past the last import, outside the block, so
        // it is preserved; only the import statements are reordered.
        assert_eq!(out, "import A.X\nimport B.Y\n\ndef f := 1\n");
        // Re-running on the sorted output finds nothing.
        assert!(run(&out).is_empty());
    }

    #[test]
    fn drops_duplicate_import() {
        let source = "import A.X\nimport A.X\nimport B.Y\n";
        let out = apply_all(source, &run(source));
        assert_eq!(out, "import A.X\nimport B.Y\n");
        assert!(run(&out).is_empty());
    }

    #[test]
    fn keeps_a_comment_attached_to_its_import() {
        // The comment documents A.X and must travel with it when B.Y sorts above.
        let source = "import B.Y\n-- about A\nimport A.X\n";
        let out = apply_all(source, &run(source));
        assert_eq!(out, "-- about A\nimport A.X\nimport B.Y\n");
        assert!(run(&out).is_empty());
    }

    #[test]
    fn already_sorted_is_a_no_op() {
        let source = "import A.X\nimport B.Y\ndef f := 1\n";
        assert!(run(source).is_empty());
    }

    #[test]
    fn refuses_when_a_comment_is_detached_by_a_blank_line() {
        // The comment is separated from A.X by a blank line: attachment is ambiguous, so
        // the whole block is left untouched.
        let source = "import B.Y\n-- floating\n\nimport A.X\n";
        assert!(run(source).is_empty());
    }

    #[test]
    fn refuses_when_a_non_import_line_is_in_the_block() {
        // `open Foo` between the imports is not reorderable; emit no fix.
        let source = "import B.Y\nopen Foo\nimport A.X\n";
        assert!(run(source).is_empty());
    }

    #[test]
    fn does_not_deduplicate_when_a_comment_is_attached() {
        // Two `import A.X`, but the second carries a comment — not a bare duplicate, so
        // both are kept (only their order may change).
        let source = "import A.X\n-- keep me\nimport A.X\n";
        let out = apply_all(source, &run(source));
        assert_eq!(out, "import A.X\n-- keep me\nimport A.X\n");
    }

    #[test]
    fn preserves_a_modifier_when_reordering() {
        let source = "import B.Y\nimport all A.X\n";
        let out = apply_all(source, &run(source));
        assert_eq!(out, "import all A.X\nimport B.Y\n");
        assert!(run(&out).is_empty());
    }
}
