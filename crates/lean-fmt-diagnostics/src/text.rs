//! Pure-text cleanup rules: trailing whitespace and final-newline normalization.
//!
//! These are the two rules that need no syntax analysis — only byte scanning plus the
//! trivia model to stay outside tokens. Each returns [`Diagnostic`]s carrying a `Safe`
//! fix, so the caller can apply them through the patch engine and re-check for
//! idempotence.

use lean_fmt_edit::{Applicability, Diagnostic, EditSet, RuleId, TextEdit, TextRange};

use crate::engine::RuleContext;

/// Build a `Safe` diagnostic with a single-edit fix.
fn safe_fix(id: &str, message: &str, range: TextRange, edit: TextEdit) -> Diagnostic {
    Diagnostic {
        rule: RuleId::new(id),
        message: message.to_owned(),
        range,
        applicability: Applicability::Safe,
        fix: Some(EditSet { edits: vec![edit] }),
    }
}

/// `text/trailing-whitespace`: flag and delete spaces/tabs at the end of each line.
///
/// Only whitespace that lies within a trivia run is removed, so trailing spaces inside a
/// multi-line string literal (a token) are left untouched.
#[must_use]
pub(crate) fn trailing_whitespace(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let source = ctx.source;
    let mut diagnostics = Vec::new();
    let mut line_start = 0usize;
    for (offset, byte) in source.bytes().enumerate() {
        if byte != b'\n' {
            continue;
        }
        // Line content excludes the newline and a preceding `\r` (CRLF safety).
        let mut content_end = offset;
        if content_end > line_start && source.as_bytes().get(content_end.saturating_sub(1)) == Some(&b'\r') {
            content_end = content_end.saturating_sub(1);
        }
        emit_trailing(ctx, line_start, content_end, &mut diagnostics);
        line_start = offset.saturating_add(1);
    }
    // The final line has no terminating newline.
    emit_trailing(ctx, line_start, source.len(), &mut diagnostics);
    diagnostics
}

/// Emit a trailing-whitespace diagnostic for the line content `[content_start, content_end)`.
fn emit_trailing(ctx: &RuleContext<'_>, content_start: usize, content_end: usize, diagnostics: &mut Vec<Diagnostic>) {
    let Some(line) = ctx.source.get(content_start..content_end) else {
        return;
    };
    let trimmed = line.trim_end_matches([' ', '\t']);
    if trimmed.len() == line.len() {
        return;
    }
    let ws_start = content_start.strict_add(trimmed.len());
    let range = TextRange::new(ws_start, content_end);
    // Only strip whitespace that is genuinely trivia (never inside a token).
    if !ctx.is_trivia(range) {
        return;
    }
    let Some(expected) = ctx.source.get(ws_start..content_end) else {
        return;
    };
    let edit = TextEdit::replace(range, expected, "");
    diagnostics.push(safe_fix("text/trailing-whitespace", "trailing whitespace", range, edit));
}

/// Detect the dominant line ending: `\r\n` if the source uses it, else `\n`.
fn detect_eol(source: &str) -> &'static str {
    if source.contains("\r\n") { "\r\n" } else { "\n" }
}

/// `text/final-newline`: ensure the file ends with exactly one line ending.
///
/// Inserts a newline when the last line is unterminated, and trims extra blank lines at
/// end of file down to a single terminator. Empty files are left alone.
#[must_use]
pub(crate) fn final_newline(ctx: &RuleContext<'_>) -> Vec<Diagnostic> {
    let source = ctx.source;
    let bytes = source.as_bytes();
    let len = bytes.len();
    if len == 0 {
        return Vec::new();
    }
    if bytes.last() != Some(&b'\n') {
        // Missing final newline: insert one (matching the file's line-ending style).
        // Appending a terminator only adds trivia, so it needs no trivia check.
        let range = TextRange::new(len, len);
        let edit = TextEdit::insert(len, detect_eol(source));
        return vec![safe_fix("text/final-newline", "missing final newline", range, edit)];
    }
    // Ends with `\n`. The trailing run of newline chars begins where the last non-newline
    // content ends; keep only the final line ending and delete the rest.
    let run_start = source.trim_end_matches(['\n', '\r']).len();
    let last_lf = len.saturating_sub(1);
    let keep_start = match len.checked_sub(2) {
        Some(prev) if bytes.get(prev) == Some(&b'\r') => prev,
        _ => last_lf,
    };
    if run_start >= keep_start {
        return Vec::new();
    }
    let range = TextRange::new(run_start, keep_start);
    if !ctx.is_trivia(range) {
        return Vec::new();
    }
    let Some(expected) = source.get(run_start..keep_start) else {
        return Vec::new();
    };
    let edit = TextEdit::replace(range, expected, "");
    vec![safe_fix(
        "text/final-newline",
        "extra blank lines at end of file",
        range,
        edit,
    )]
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

    use lean_fmt_edit::TextRange;

    use super::{final_newline, trailing_whitespace};
    use crate::engine::RuleContext;

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

    /// Apply every diagnostic's fix to `source` and return the rewritten text.
    fn apply_all(source: &str, diagnostics: &[lean_fmt_edit::Diagnostic]) -> String {
        let mut edits = Vec::new();
        for diagnostic in diagnostics {
            if let Some(fix) = &diagnostic.fix {
                edits.extend(fix.edits.clone());
            }
        }
        let set = lean_fmt_edit::EditSet { edits };
        set.apply(source).unwrap().output
    }

    #[test]
    fn strips_trailing_whitespace_and_is_idempotent() {
        let source = "def a := 1  \ndef b := 2\t\n";
        // Tokens on each line; the trailing spaces/tabs are trivia.
        let tokens = [
            TextRange::new(0, 3),
            TextRange::new(4, 5),
            TextRange::new(6, 8),
            TextRange::new(9, 10),
            TextRange::new(13, 16),
            TextRange::new(17, 18),
            TextRange::new(19, 21),
            TextRange::new(22, 23),
        ];
        let runs = trivia_complement(source.len(), &tokens);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        let diagnostics = trailing_whitespace(&ctx);
        assert_eq!(diagnostics.len(), 2);
        let cleaned = apply_all(source, &diagnostics);
        assert_eq!(cleaned, "def a := 1\ndef b := 2\n");
        // Idempotent: re-running on the cleaned source finds nothing.
        let runs2 = trivia_complement(cleaned.len(), &[TextRange::new(0, cleaned.len())]);
        let ctx2 = RuleContext::new(&cleaned, "A.lean", &runs2);
        assert!(trailing_whitespace(&ctx2).is_empty());
    }

    #[test]
    fn does_not_strip_inside_a_string_token() {
        // A multi-line string literal whose first line has trailing spaces; those spaces
        // are inside the token, so they must be preserved.
        let source = "  \"line   \n  more\"\n";
        // The whole string literal `"line   \n  more"` is one token at bytes [2, 18).
        let tokens = [TextRange::new(2, 18)];
        let runs = trivia_complement(source.len(), &tokens);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        // No trailing-whitespace diagnostic: the only line-end spaces are inside the token.
        assert!(trailing_whitespace(&ctx).is_empty());
    }

    #[test]
    fn inserts_missing_final_newline() {
        let source = "def a := 1";
        let runs = trivia_complement(source.len(), &[TextRange::new(0, source.len())]);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        let diagnostics = final_newline(&ctx);
        assert_eq!(diagnostics.len(), 1);
        assert_eq!(apply_all(source, &diagnostics), "def a := 1\n");
    }

    #[test]
    fn trims_extra_trailing_blank_lines() {
        let source = "def a := 1\n\n\n";
        let runs = trivia_complement(source.len(), &[TextRange::new(0, 10)]);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        let diagnostics = final_newline(&ctx);
        assert_eq!(diagnostics.len(), 1);
        let cleaned = apply_all(source, &diagnostics);
        assert_eq!(cleaned, "def a := 1\n");
        // Idempotent.
        let runs2 = trivia_complement(cleaned.len(), &[TextRange::new(0, 10)]);
        let ctx2 = RuleContext::new(&cleaned, "A.lean", &runs2);
        assert!(final_newline(&ctx2).is_empty());
    }

    #[test]
    fn already_single_newline_is_a_no_op() {
        let source = "def a := 1\n";
        let runs = trivia_complement(source.len(), &[TextRange::new(0, 10)]);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        assert!(final_newline(&ctx).is_empty());
    }

    #[test]
    fn empty_file_has_no_final_newline_diagnostic() {
        let ctx = RuleContext::new("", "A.lean", &[]);
        assert!(final_newline(&ctx).is_empty());
    }

    #[test]
    fn crlf_trailing_blank_line_trims_to_one_crlf() {
        let source = "def a := 1\r\n\r\n";
        let runs = trivia_complement(source.len(), &[TextRange::new(0, 10)]);
        let ctx = RuleContext::new(source, "A.lean", &runs);
        let diagnostics = final_newline(&ctx);
        assert_eq!(diagnostics.len(), 1);
        assert_eq!(apply_all(source, &diagnostics), "def a := 1\r\n");
    }
}
