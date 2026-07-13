//! The versioned edit protocol and conflict-checked patch engine.
//!
//! A formatter rule reports a [`Diagnostic`] and, when it can fix the problem, an
//! [`EditSet`] of byte-anchored [`TextEdit`]s. Applying an edit set is **conflict- and
//! staleness-checked**: every edit carries the exact source text it expects to replace,
//! so an edit computed against a since-changed source is rejected rather than silently
//! rewriting the wrong bytes ([`EditSet::apply`]). Overlapping edits are rejected too.
//!
//! Byte offsets ([`TextRange`]) are the currency, shared with the coordinate model — the
//! same offsets Lean reports. The protocol is versioned by [`SCHEMA`] so the Lean and
//! Rust sides can detect drift.

use crate::source::TextRange;
use serde::{Deserialize, Serialize};

/// The edit-protocol schema version. Bumped when the wire shape of [`Diagnostic`] /
/// [`EditSet`] changes incompatibly; the Lean `LeanFmt.Protocol` side emits the same
/// string so a mismatch is detectable.
pub const SCHEMA: &str = "lean-fmt.edit.v1";

/// A stable identifier for a formatter rule (e.g. `"import-sort"`).
///
/// Serialized transparently as a bare string.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RuleId(pub String);

impl RuleId {
    /// Construct a rule id from anything string-like.
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    /// The rule id as a string slice.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// How safe a fix is to apply automatically, mirroring Ruff's applicability ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Applicability {
    /// The fix preserves meaning and may be applied without review.
    Safe,
    /// The fix may change meaning; apply only when the caller opts in.
    Unsafe,
    /// The fix is illustrative only and must not be applied automatically.
    DisplayOnly,
}

/// A single byte-anchored replacement: replace `range` with `new_text`.
///
/// An insertion is a zero-length `range`; a deletion is an empty `new_text`. `expected`
/// is the exact source text currently occupying `range` — the staleness guard checked
/// before the edit is applied.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextEdit {
    /// The byte range to replace.
    pub range: TextRange,
    /// The source text the edit was computed against for `range` (`""` for an insertion).
    #[serde(default)]
    pub expected: String,
    /// The replacement text.
    pub new_text: String,
}

impl TextEdit {
    /// A replacement of `range` (which currently holds `expected`) with `new_text`.
    #[must_use]
    pub fn replace(range: TextRange, expected: impl Into<String>, new_text: impl Into<String>) -> Self {
        Self {
            range,
            expected: expected.into(),
            new_text: new_text.into(),
        }
    }

    /// An insertion of `text` at byte `offset`.
    #[must_use]
    pub fn insert(offset: usize, text: impl Into<String>) -> Self {
        Self {
            range: TextRange::new(offset, offset),
            expected: String::new(),
            new_text: text.into(),
        }
    }
}

/// A set of edits applied together atomically. Either every edit applies or none does.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditSet {
    /// The edits, in any order (application sorts and conflict-checks them).
    pub edits: Vec<TextEdit>,
}

/// A formatter finding: a rule violation at a byte range, with an optional fix.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    /// The rule that produced the finding.
    pub rule: RuleId,
    /// Human-readable description.
    pub message: String,
    /// The byte range the finding anchors to.
    pub range: TextRange,
    /// How safe the fix (if any) is to apply.
    pub applicability: Applicability,
    /// The fix, when the rule can produce one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fix: Option<EditSet>,
}

/// The result of applying an [`EditSet`] cleanly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatchOutcome {
    /// The patched source.
    pub output: String,
    /// The number of edits applied.
    pub applied: usize,
}

/// Why an [`EditSet`] could not be applied. Every variant means *nothing* was written —
/// application is all-or-nothing, so a rejected patch never partially rewrites the source.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PatchError {
    /// An edit's range lies outside `[0, source_len]` or is reversed.
    #[error("edit {index} range is out of bounds for the source")]
    OutOfBounds {
        /// Index of the offending edit in the original [`EditSet`].
        index: usize,
    },
    /// An edit's range does not fall on UTF-8 character boundaries.
    #[error("edit {index} range is not on character boundaries")]
    NotCharBoundary {
        /// Index of the offending edit in the original [`EditSet`].
        index: usize,
    },
    /// The source no longer matches what the edit expected — it is stale.
    #[error("edit {index} is stale: expected {expected:?} at its range but found {found:?}")]
    StaleEdit {
        /// Index of the offending edit in the original [`EditSet`].
        index: usize,
        /// The text the edit expected to replace.
        expected: String,
        /// The text actually present at the edit's range.
        found: String,
    },
    /// Two edits' ranges overlap, so their combined effect is ambiguous.
    #[error("edits {first} and {second} overlap")]
    OverlappingEdits {
        /// Index of the earlier edit in the original [`EditSet`].
        first: usize,
        /// Index of the later edit in the original [`EditSet`].
        second: usize,
    },
}

impl EditSet {
    /// Apply every edit to `source`, conflict- and staleness-checked.
    ///
    /// The edits are validated (in-bounds, on character boundaries, and each matching the
    /// `expected` text at its range), then sorted by start offset and checked for overlap,
    /// then applied left to right. Adjacent edits (one ending where the next begins) and
    /// multiple insertions at the same offset are allowed; overlapping ranges are not.
    ///
    /// # Errors
    ///
    /// Returns a [`PatchError`] — and writes nothing — if any edit is out of bounds, off a
    /// character boundary, stale (its `expected` text no longer matches the source), or
    /// overlaps another edit.
    pub fn apply(&self, source: &str) -> Result<PatchOutcome, PatchError> {
        // 1. Validate each edit against the *current* source before touching anything.
        for (index, edit) in self.edits.iter().enumerate() {
            if !edit.range.is_well_formed(source.len()) {
                return Err(PatchError::OutOfBounds { index });
            }
            let Some(actual) = source.get(edit.range.start..edit.range.end) else {
                return Err(PatchError::NotCharBoundary { index });
            };
            if actual != edit.expected {
                return Err(PatchError::StaleEdit {
                    index,
                    expected: edit.expected.clone(),
                    found: actual.to_owned(),
                });
            }
        }

        // 2. Order by (start, end, original index) so application and overlap detection
        //    are deterministic even for touching or same-offset edits.
        let mut ordered: Vec<(usize, &TextEdit)> = self.edits.iter().enumerate().collect();
        ordered.sort_by(|a, b| {
            a.1.range
                .start
                .cmp(&b.1.range.start)
                .then(a.1.range.end.cmp(&b.1.range.end))
                .then(a.0.cmp(&b.0))
        });

        // 3. Reject overlaps: a strictly-earlier edit must end no later than the next begins.
        for pair in ordered.windows(2) {
            let [(first, prev), (second, next)] = pair else {
                continue;
            };
            if prev.range.end > next.range.start {
                return Err(PatchError::OverlappingEdits {
                    first: *first,
                    second: *second,
                });
            }
        }

        // 4. Apply left to right. The cursor never exceeds the next edit's start (sort +
        //    overlap check guarantee it), so every slice below is in-bounds.
        let mut output = String::with_capacity(source.len());
        let mut cursor = 0_usize;
        for (_, edit) in &ordered {
            if let Some(segment) = source.get(cursor..edit.range.start) {
                output.push_str(segment);
            }
            output.push_str(&edit.new_text);
            cursor = edit.range.end;
        }
        if let Some(tail) = source.get(cursor..) {
            output.push_str(tail);
        }

        Ok(PatchOutcome {
            output,
            applied: self.edits.len(),
        })
    }
}

/// Render a line-based unified diff of `original` → `modified`, headed with `path`.
///
/// Returns an empty string when the two texts are identical. Line endings are preserved
/// byte-for-byte (the diff is over whole lines including their terminators), so CRLF
/// content is not normalized.
#[must_use]
pub fn unified_diff(original: &str, modified: &str, path: &str) -> String {
    if original == modified {
        return String::new();
    }
    let diff = similar::TextDiff::from_lines(original, modified);
    diff.unified_diff()
        .context_radius(3)
        .header(&format!("a/{path}"), &format!("b/{path}"))
        .to_string()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::{Applicability, Diagnostic, EditSet, PatchError, RuleId, SCHEMA, TextEdit, unified_diff};
    use crate::source::TextRange;

    fn apply(source: &str, edits: Vec<TextEdit>) -> Result<String, PatchError> {
        EditSet { edits }.apply(source).map(|o| o.output)
    }

    #[test]
    fn replace_insert_delete_apply_in_order() {
        let src = "let x = 1";
        // Replace `x` (byte 4) with `y`, insert `pub ` at 0, delete ` = 1` (bytes 5..9).
        let edits = vec![
            TextEdit::replace(TextRange::new(4, 5), "x", "y"),
            TextEdit::insert(0, "pub "),
            TextEdit::replace(TextRange::new(5, 9), " = 1", ""),
        ];
        assert_eq!(apply(src, edits).unwrap(), "pub let y");
    }

    #[test]
    fn stale_edit_is_rejected_without_writing() {
        let src = "let x = 1";
        // The edit expects `z` at byte 4, but the source has `x` — stale.
        let edits = vec![TextEdit::replace(TextRange::new(4, 5), "z", "y")];
        assert_eq!(
            apply(src, edits),
            Err(PatchError::StaleEdit {
                index: 0,
                expected: "z".to_owned(),
                found: "x".to_owned()
            }),
            "a stale edit must not silently rewrite the wrong source"
        );
    }

    #[test]
    fn overlapping_edits_are_rejected() {
        let src = "abcdef";
        let edits = vec![
            TextEdit::replace(TextRange::new(1, 4), "bcd", "X"),
            TextEdit::replace(TextRange::new(3, 5), "de", "Y"),
        ];
        assert_eq!(
            apply(src, edits),
            Err(PatchError::OverlappingEdits { first: 0, second: 1 })
        );
    }

    #[test]
    fn adjacent_and_same_offset_inserts_are_allowed() {
        let src = "ac";
        // Two inserts at offset 1 apply in given order; an adjacent replace touches them.
        let edits = vec![
            TextEdit::insert(1, "b"),
            TextEdit::insert(1, "B"),
            TextEdit::replace(TextRange::new(1, 2), "c", "C"),
        ];
        assert_eq!(apply(src, edits).unwrap(), "abBC");
    }

    #[test]
    fn zero_length_insert_at_eof_and_replace_at_eof() {
        let src = "end";
        let edits = vec![
            TextEdit::insert(3, "!"),
            TextEdit::replace(TextRange::new(0, 3), "end", "END"),
        ];
        assert_eq!(apply(src, edits).unwrap(), "END!");
    }

    #[test]
    fn out_of_bounds_and_boundary_errors() {
        let src = "hi";
        assert_eq!(
            apply(src, vec![TextEdit::replace(TextRange::new(0, 5), "", "x")]),
            Err(PatchError::OutOfBounds { index: 0 })
        );
        // Splitting the 2-byte `é` mid-character is not a character boundary.
        let multi = "é"; // U+00E9, 2 bytes
        assert_eq!(
            apply(multi, vec![TextEdit::replace(TextRange::new(0, 1), "", "x")]),
            Err(PatchError::NotCharBoundary { index: 0 })
        );
    }

    #[test]
    fn crlf_is_preserved_byte_for_byte() {
        let src = "a\r\nb\r\nc\r\n";
        // Replace the middle line's `b` (byte 3) with `B`; CRLFs are untouched.
        let edits = vec![TextEdit::replace(TextRange::new(3, 4), "b", "B")];
        assert_eq!(apply(src, edits).unwrap(), "a\r\nB\r\nc\r\n");
    }

    #[test]
    fn empty_edit_set_is_identity() {
        let out = EditSet::default().apply("unchanged").unwrap();
        assert_eq!(out.output, "unchanged");
        assert_eq!(out.applied, 0);
    }

    #[test]
    fn diagnostic_and_editset_round_trip_json() {
        let diag = Diagnostic {
            rule: RuleId::new("import-sort"),
            message: "imports are not sorted".to_owned(),
            range: TextRange::new(0, 11),
            applicability: Applicability::Safe,
            fix: Some(EditSet {
                edits: vec![TextEdit::replace(TextRange::new(0, 11), "import B\n", "import A\n")],
            }),
        };
        let json = serde_json::to_string(&diag).unwrap();
        let back: Diagnostic = serde_json::from_str(&json).unwrap();
        assert_eq!(diag, back);
        // A rule id serializes as a bare string; applicability as snake_case.
        assert!(json.contains("\"import-sort\""));
        assert!(json.contains("\"safe\""));
    }

    #[test]
    fn schema_version_is_stable() {
        assert_eq!(SCHEMA, "lean-fmt.edit.v1");
    }

    #[test]
    fn unified_diff_headers_and_hunks() {
        let before = "one\ntwo\nthree\n";
        let after = "one\n2\nthree\n";
        let diff = unified_diff(before, after, "Demo.lean");
        assert!(diff.contains("--- a/Demo.lean"));
        assert!(diff.contains("+++ b/Demo.lean"));
        assert!(diff.contains("-two"));
        assert!(diff.contains("+2"));
        assert_eq!(
            unified_diff("same\n", "same\n", "X.lean"),
            "",
            "no diff for identical text"
        );
    }
}
