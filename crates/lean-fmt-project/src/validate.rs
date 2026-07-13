//! The safe-apply gate: apply conflict-checked edits in memory, then — unless validation
//! is disabled — re-parse the edited text and refuse to hand it back unless it still parses.
//!
//! This is the in-memory guarantee the fix-write path (`LFMT-PROJECT-MODES`) depends on:
//! nothing downstream can obtain "validated new source" for a file whose edited form fails
//! to parse. The gate itself performs no disk I/O and spawns no worker — the re-parse is an
//! injected closure, so it is unit-testable with a stub and driven by the real warm worker's
//! [`parse_file`](lean_fmt_worker::FormatterWorker::parse_file) in production.

use lean_fmt_edit::{EditSet, PatchError};
use lean_fmt_worker::{ParseDiagnostic, ParseFileResponse, ParseStatus};

/// How strictly edited source is re-checked before it may be offered for write.
///
/// The patch conflict check ([`EditSet::apply`]) always runs regardless of level; the level
/// governs only the *re-parse* gate applied to the already-patched text.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ValidationLevel {
    /// Skip the re-parse gate: return the patched text as long as the edits applied cleanly.
    None,
    /// Re-parse the patched text; yield it only if it parses without error. The default.
    #[default]
    Syntax,
    // `Elab` (parse *and* elaborate) is added by `LFMT-ELAB-VALIDATE` (prompt 24).
}

/// Why [`safe_apply`] refused to yield edited source. Either variant means the original
/// source is untouched and nothing may be written.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SafeApplyError {
    /// The edits could not be applied to the current source — stale, overlapping, or out of
    /// bounds. Raised at *every* validation level, so disabling validation never disables the
    /// conflict check.
    #[error("patch could not be applied: {0}")]
    Patch(#[from] PatchError),

    /// The edits applied, but the patched text failed to re-parse at the requested level, so
    /// it must not be written.
    #[error("edited source failed {level:?} validation with {} diagnostic(s)", .diagnostics.len())]
    Validation {
        /// The level at which validation was performed.
        level: ValidationLevel,
        /// The parse status of the patched text (never [`ParseStatus::Ok`] here).
        status: ParseStatus,
        /// The diagnostics reported for the patched text.
        diagnostics: Vec<ParseDiagnostic>,
    },
}

/// Apply `edits` to `source` and, unless `level` is [`ValidationLevel::None`], re-parse the
/// result — returning the edited source only if it still parses without error.
///
/// The patch step is always conflict-checked ([`EditSet::apply`]): a stale, overlapping, or
/// out-of-bounds edit yields [`SafeApplyError::Patch`] and nothing is written, *regardless of
/// `level`*. When `level` validates, the patched text is passed to `parse`; the result is
/// accepted only when its [`ParseStatus`] is [`ParseStatus::Ok`], so a caller can never obtain
/// validated new source for a file whose edited form degrades or errors.
///
/// `parse` is injected (called exactly once) so the gate is unit-testable with a stub; the
/// real caller passes a closure over the warm worker's
/// [`parse_file`](lean_fmt_worker::FormatterWorker::parse_file), mapping any transport
/// [`WorkerError`](lean_fmt_worker::WorkerError) itself.
///
/// # Errors
///
/// Returns [`SafeApplyError::Patch`] if the edits do not apply cleanly, or
/// [`SafeApplyError::Validation`] if a validating level's re-parse of the patched text is not
/// [`ParseStatus::Ok`].
pub fn safe_apply<F>(source: &str, edits: &EditSet, level: ValidationLevel, parse: F) -> Result<String, SafeApplyError>
where
    F: FnOnce(&str) -> ParseFileResponse,
{
    // 1. Conflict-checked patch — always, even when validation is disabled.
    let applied = edits.apply(source)?.output;

    // 2. Re-parse gate, unless the caller opted out.
    if level == ValidationLevel::None {
        return Ok(applied);
    }
    let response = parse(&applied);
    if response.status == ParseStatus::Ok {
        Ok(applied)
    } else {
        Err(SafeApplyError::Validation {
            level,
            status: response.status,
            diagnostics: response.diagnostics,
        })
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use lean_fmt_edit::{EditSet, TextEdit, TextRange};
    use lean_fmt_worker::{ModuleHeader, ParseDiagnostic, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary};

    use super::{SafeApplyError, ValidationLevel, safe_apply};

    /// Build a parse response with a given status and diagnostic count.
    fn response(status: ParseStatus, diagnostics: usize) -> ParseFileResponse {
        ParseFileResponse {
            status,
            diagnostics: (0..diagnostics)
                .map(|i| ParseDiagnostic {
                    severity: "error".to_owned(),
                    message: format!("diag {i}"),
                    file: "<snapshot>".to_owned(),
                    line: 1,
                    column: 0,
                    end_line: None,
                    end_column: None,
                })
                .collect(),
            diagnostics_truncated: false,
            module_header: ModuleHeader {
                imports: Vec::new(),
                is_module: false,
                import_spans: Vec::new(),
            },
            syntax_summary: SyntaxSummary {
                command_count: 0,
                command_kinds: Vec::new(),
                command_regions: Vec::new(),
                declaration_headers: Vec::new(),
                tactic_blocks: Vec::new(),
            },
            source_model: SourceModel::default(),
        }
    }

    /// One edit replacing `range`'s current `expected` text with `new_text`.
    fn edits(range: (usize, usize), expected: &str, new_text: &str) -> EditSet {
        EditSet {
            edits: vec![TextEdit::replace(TextRange::new(range.0, range.1), expected, new_text)],
        }
    }

    #[test]
    fn valid_edit_reparses_ok_and_is_returned() {
        let source = "def a := 1\n";
        let set = edits((9, 10), "1", "2");
        let out = safe_apply(source, &set, ValidationLevel::Syntax, |patched| {
            assert_eq!(patched, "def a := 2\n");
            response(ParseStatus::Ok, 0)
        })
        .unwrap();
        assert_eq!(out, "def a := 2\n");
    }

    #[test]
    fn edit_whose_reparse_errors_is_rejected_and_original_untouched() {
        let source = "def a := 1\n";
        let set = edits((9, 10), "1", "@"); // a corrupting replacement
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            response(ParseStatus::Error, 2)
        })
        .unwrap_err();
        match err {
            SafeApplyError::Validation {
                level,
                status,
                diagnostics,
            } => {
                assert_eq!(level, ValidationLevel::Syntax);
                assert_eq!(status, ParseStatus::Error);
                assert_eq!(diagnostics.len(), 2);
            }
            SafeApplyError::Patch(err) => panic!("expected Validation, got Patch({err:?})"),
        }
        // The gate returns nothing writable; `source` is still the original.
        assert_eq!(source, "def a := 1\n");
    }

    #[test]
    fn edit_whose_reparse_degrades_is_also_rejected() {
        let source = "def a := 1\n";
        let set = edits((9, 10), "1", "2");
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            response(ParseStatus::Degraded, 1)
        })
        .unwrap_err();
        assert!(matches!(
            err,
            SafeApplyError::Validation {
                status: ParseStatus::Degraded,
                ..
            }
        ));
    }

    #[test]
    fn stale_edit_is_a_patch_error_at_syntax_level_and_parse_is_never_called() {
        let source = "def a := 1\n";
        // `expected` no longer matches the source at the range → staleness.
        let set = edits((9, 10), "9", "2");
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            panic!("parse must not run when the patch itself fails");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }

    #[test]
    fn none_level_bypasses_reparse_but_not_the_conflict_check() {
        let source = "def a := 1\n";

        // A well-formed edit at None returns the applied output without re-parsing.
        let ok = edits((9, 10), "1", "2");
        let out = safe_apply(source, &ok, ValidationLevel::None, |_| {
            panic!("None level must not re-parse");
        })
        .unwrap();
        assert_eq!(out, "def a := 2\n");

        // A stale edit is still rejected at None — disabling validation never disables the
        // conflict check.
        let stale = edits((9, 10), "9", "2");
        let err = safe_apply(source, &stale, ValidationLevel::None, |_| {
            panic!("None level must not re-parse");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }

    #[test]
    fn overlapping_edits_are_rejected_before_any_parse() {
        let source = "def a := 1\n";
        let set = EditSet {
            edits: vec![
                TextEdit::replace(TextRange::new(0, 3), "def", "abbrev"),
                TextEdit::replace(TextRange::new(2, 5), "f a", "X"),
            ],
        };
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            panic!("parse must not run when edits overlap");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }
}
