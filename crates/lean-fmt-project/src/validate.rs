//! The safe-apply gate: apply conflict-checked edits in memory, then — unless validation
//! is disabled — re-check the edited text and refuse to hand it back unless it still passes.
//!
//! This is the in-memory guarantee the fix-write path (`LFMT-PROJECT-MODES`) depends on:
//! nothing downstream can obtain "validated new source" for a file whose edited form fails
//! the requested check. The gate itself performs no disk I/O and spawns no worker — the
//! re-check is an injected closure, so it is unit-testable with a stub and driven by the real
//! warm worker in production.
//!
//! Two check strengths map to one gate. [`ValidationLevel::Syntax`] re-parses the patched
//! text ([`parse_file`](lean_fmt_worker::FormatterWorker::parse_file), accepted iff
//! [`ParseStatus::Ok`]); [`ValidationLevel::Elab`] re-parses *and elaborates* it
//! ([`validate`](lean_fmt_worker::FormatterWorker::validate), accepted iff `valid`). Both
//! collapse to a [`ValidationOutcome`] via `From`, so the caller injects a single closure
//! (branching on level internally) and the gate stays a single mutable-worker borrow.

use lean_fmt_edit::{EditSet, PatchError};
use lean_fmt_worker::{ParseDiagnostic, ParseFileResponse, ParseStatus, ValidateResponse};

/// How strictly edited source is re-checked before it may be offered for write.
///
/// The patch conflict check ([`EditSet::apply`]) always runs regardless of level; the level
/// governs only the *re-check* gate applied to the already-patched text.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ValidationLevel {
    /// Skip the re-check gate: return the patched text as long as the edits applied cleanly.
    None,
    /// Re-parse the patched text; yield it only if it parses without error. The default.
    #[default]
    Syntax,
    /// Re-parse *and elaborate* the patched text; yield it only if elaboration also succeeds.
    /// Stricter and slower than [`Syntax`](Self::Syntax) — an opt-in level that rejects an
    /// edit which parses but breaks elaboration (an unknown identifier, a type error).
    Elab,
}

/// The verdict of re-checking patched text: whether it passed, plus any diagnostics.
///
/// Both the syntax re-parse ([`ParseFileResponse`], accepted iff [`ParseStatus::Ok`]) and the
/// elaboration check ([`ValidateResponse`], accepted iff `valid`) collapse to this via `From`,
/// so [`safe_apply`] gates uniformly on `accepted` whatever the level.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ValidationOutcome {
    /// Whether the patched text passed the re-check.
    pub accepted: bool,
    /// The diagnostics reported for the patched text (empty when accepted with no warnings).
    pub diagnostics: Vec<ParseDiagnostic>,
}

impl From<ParseFileResponse> for ValidationOutcome {
    /// A syntax re-parse is accepted only when the status is [`ParseStatus::Ok`] — a
    /// `Degraded` or `Error` re-parse is a rejection.
    fn from(response: ParseFileResponse) -> Self {
        Self {
            accepted: response.status == ParseStatus::Ok,
            diagnostics: response.diagnostics,
        }
    }
}

impl From<ValidateResponse> for ValidationOutcome {
    /// An elaboration check is accepted only when the snapshot both parsed and elaborated
    /// without error (`valid`).
    fn from(response: ValidateResponse) -> Self {
        Self {
            accepted: response.valid,
            diagnostics: response.diagnostics,
        }
    }
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

    /// The edits applied, but the patched text failed the re-check at the requested level, so
    /// it must not be written.
    #[error("edited source failed {level:?} validation with {} diagnostic(s)", .diagnostics.len())]
    Validation {
        /// The level at which the re-check was performed.
        level: ValidationLevel,
        /// The diagnostics reported for the rejected patched text.
        diagnostics: Vec<ParseDiagnostic>,
    },
}

/// Apply `edits` to `source` and, unless `level` is [`ValidationLevel::None`], re-check the
/// result — returning the edited source only if it passes.
///
/// The patch step is always conflict-checked ([`EditSet::apply`]): a stale, overlapping, or
/// out-of-bounds edit yields [`SafeApplyError::Patch`] and nothing is written, *regardless of
/// `level`*. When `level` validates, the patched text is passed to `check`; the result is
/// accepted only when [`ValidationOutcome::accepted`] is `true`, so a caller can never obtain
/// validated new source for a file whose edited form fails the requested gate.
///
/// `check` is injected (called exactly once) so the gate is unit-testable with a stub. The
/// real caller branches on `level` *inside* the closure — calling the warm worker's
/// [`parse_file`](lean_fmt_worker::FormatterWorker::parse_file) for
/// [`Syntax`](ValidationLevel::Syntax) or [`validate`](lean_fmt_worker::FormatterWorker::validate)
/// for [`Elab`](ValidationLevel::Elab), each `.into()` a [`ValidationOutcome`] — so a single
/// mutable borrow of the worker suffices. A transport
/// [`WorkerError`](lean_fmt_worker::WorkerError) is the caller's to map.
///
/// # Errors
///
/// Returns [`SafeApplyError::Patch`] if the edits do not apply cleanly, or
/// [`SafeApplyError::Validation`] if a validating level's re-check of the patched text is not
/// accepted.
pub fn safe_apply<F>(source: &str, edits: &EditSet, level: ValidationLevel, check: F) -> Result<String, SafeApplyError>
where
    F: FnOnce(&str) -> ValidationOutcome,
{
    // 1. Conflict-checked patch — always, even when validation is disabled.
    let applied = edits.apply(source)?.output;

    // 2. Re-check gate, unless the caller opted out.
    if level == ValidationLevel::None {
        return Ok(applied);
    }
    let outcome = check(&applied);
    if outcome.accepted {
        Ok(applied)
    } else {
        Err(SafeApplyError::Validation {
            level,
            diagnostics: outcome.diagnostics,
        })
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use lean_fmt_edit::{EditSet, TextEdit, TextRange};
    use lean_fmt_worker::{
        ModuleHeader, ParseDiagnostic, ParseFileResponse, ParseStatus, SourceModel, SyntaxSummary, ValidateResponse,
    };

    use super::{SafeApplyError, ValidationLevel, ValidationOutcome, safe_apply};

    fn diagnostics(n: usize) -> Vec<ParseDiagnostic> {
        (0..n)
            .map(|i| ParseDiagnostic {
                severity: "error".to_owned(),
                message: format!("diag {i}"),
                file: "<snapshot>".to_owned(),
                line: 1,
                column: 0,
                end_line: None,
                end_column: None,
            })
            .collect()
    }

    /// A syntax-level (`parse_file`) response with a given status and diagnostic count.
    fn parse_outcome(status: ParseStatus, n: usize) -> ValidationOutcome {
        ParseFileResponse {
            status,
            diagnostics: diagnostics(n),
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
            fell_back: false,
        }
        .into()
    }

    /// An elaboration-level (`validate`) outcome.
    fn elab_outcome(valid: bool, n: usize) -> ValidationOutcome {
        ValidateResponse {
            valid,
            diagnostics: diagnostics(n),
            diagnostics_truncated: false,
        }
        .into()
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
            parse_outcome(ParseStatus::Ok, 0)
        })
        .unwrap();
        assert_eq!(out, "def a := 2\n");
    }

    #[test]
    fn edit_whose_reparse_errors_is_rejected_and_original_untouched() {
        let source = "def a := 1\n";
        let set = edits((9, 10), "1", "@"); // a corrupting replacement
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            parse_outcome(ParseStatus::Error, 2)
        })
        .unwrap_err();
        match err {
            SafeApplyError::Validation { level, diagnostics } => {
                assert_eq!(level, ValidationLevel::Syntax);
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
            parse_outcome(ParseStatus::Degraded, 1)
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Validation { .. }));
    }

    #[test]
    fn elab_level_rejects_an_edit_that_parses_but_fails_to_elaborate() {
        let source = "def a : Nat := 1\n";
        // `b` parses fine but is an unknown identifier — a Syntax-accepted, Elab-rejected edit.
        let set = edits((15, 16), "1", "b");

        // Syntax: the patched text parses `Ok`, so it is accepted.
        let syntax = safe_apply(source, &set, ValidationLevel::Syntax, |patched| {
            assert_eq!(patched, "def a : Nat := b\n");
            parse_outcome(ParseStatus::Ok, 0)
        })
        .unwrap();
        assert_eq!(syntax, "def a : Nat := b\n");

        // Elab: the same patched text fails elaboration, so it is rejected.
        let err = safe_apply(source, &set, ValidationLevel::Elab, |_| elab_outcome(false, 1)).unwrap_err();
        match err {
            SafeApplyError::Validation { level, diagnostics } => {
                assert_eq!(level, ValidationLevel::Elab);
                assert_eq!(diagnostics.len(), 1);
            }
            SafeApplyError::Patch(err) => panic!("expected Validation, got Patch({err:?})"),
        }
        assert_eq!(source, "def a : Nat := 1\n");
    }

    #[test]
    fn elab_level_accepts_an_edit_that_elaborates() {
        let source = "def a : Nat := 1\n";
        let set = edits((15, 16), "1", "2");
        let out = safe_apply(source, &set, ValidationLevel::Elab, |_| elab_outcome(true, 0)).unwrap();
        assert_eq!(out, "def a : Nat := 2\n");
    }

    #[test]
    fn stale_edit_is_a_patch_error_at_syntax_level_and_check_is_never_called() {
        let source = "def a := 1\n";
        // `expected` no longer matches the source at the range → staleness.
        let set = edits((9, 10), "9", "2");
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            panic!("check must not run when the patch itself fails");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }

    #[test]
    fn none_level_bypasses_recheck_but_not_the_conflict_check() {
        let source = "def a := 1\n";

        // A well-formed edit at None returns the applied output without re-checking.
        let ok = edits((9, 10), "1", "2");
        let out = safe_apply(source, &ok, ValidationLevel::None, |_| {
            panic!("None level must not re-check");
        })
        .unwrap();
        assert_eq!(out, "def a := 2\n");

        // A stale edit is still rejected at None — disabling validation never disables the
        // conflict check.
        let stale = edits((9, 10), "9", "2");
        let err = safe_apply(source, &stale, ValidationLevel::None, |_| {
            panic!("None level must not re-check");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }

    #[test]
    fn overlapping_edits_are_rejected_before_any_check() {
        let source = "def a := 1\n";
        let set = EditSet {
            edits: vec![
                TextEdit::replace(TextRange::new(0, 3), "def", "abbrev"),
                TextEdit::replace(TextRange::new(2, 5), "f a", "X"),
            ],
        };
        let err = safe_apply(source, &set, ValidationLevel::Syntax, |_| {
            panic!("check must not run when edits overlap");
        })
        .unwrap_err();
        assert!(matches!(err, SafeApplyError::Patch(_)));
    }
}
