//! Property tests for the worker-free core of `lean-fmt-edit`: the byte↔line/column source map
//! and the conflict-checked patch engine. These are the CI-profile properties — they need no Lean
//! worker and run on stable via `proptest`, which shrinks any counterexample to a minimal failing
//! case (persisted under `proptest-regressions/` and re-run on every future invocation).
//!
//! The properties, matching the roadmap's conservative-edit contract:
//!
//! - **Source map round-trips.** For every character-boundary byte offset, converting to a
//!   line/column and back is the identity.
//! - **Non-overlapping edits apply consistently.** A set of disjoint, non-stale edits applies to
//!   exactly the source a hand-written splice produces, and reports the right applied count.
//! - **Overlapping edits are rejected atomically.** Two edits over the same non-empty range are
//!   refused with `OverlappingEdits` and nothing is written.
//! - **Apply then diff is consistent.** The unified diff of source→output is empty exactly when
//!   the output equals the source.
//!
//! A longer fuzz pass is a plain `PROPTEST_CASES=<n>` run of this file; see `docs/testing.md`.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::arithmetic_side_effects
)]

use lean_fmt_edit::{EditSet, LineColumn, PatchError, SourceMap, TextEdit, TextRange, unified_diff};
use proptest::prelude::*;

/// A strategy for arbitrary UTF-8 source text, biased toward newlines and multi-byte characters so
/// the line map and character-boundary logic are actually exercised (not just ASCII).
fn source_text() -> impl Strategy<Value = String> {
    proptest::string::string_regex("(?s)[a-z\\n\u{00e9}\u{4e16}\u{1f600} ]{0,64}").unwrap()
}

/// The sorted, de-duplicated character-boundary byte offsets of `s`, including `0` and `s.len()`.
fn char_boundaries(s: &str) -> Vec<usize> {
    let mut boundaries: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    boundaries.push(s.len());
    boundaries
}

proptest! {
    /// Every character-boundary offset survives a round trip through `line_column` /`byte_offset`.
    #[test]
    fn source_map_offset_roundtrips(s in source_text()) {
        let map = SourceMap::new(&s);
        for offset in char_boundaries(&s) {
            let pos: LineColumn = map.line_column(offset);
            prop_assert_eq!(
                map.byte_offset(pos),
                Some(offset),
                "offset {} -> {:?} did not round-trip in {:?}",
                offset,
                pos,
                s
            );
        }
    }

    /// A set of disjoint, correctly-`expected` edits applies to exactly the hand-spliced result.
    #[test]
    fn non_overlapping_edits_apply_consistently(
        s in source_text(),
        // A replacement flag and new text per gap between consecutive boundaries.
        plan in proptest::collection::vec((any::<bool>(), "[a-z]{0,4}"), 0..12),
    ) {
        let boundaries = char_boundaries(&s);
        // Build disjoint edits over consecutive boundary pairs [b[i], b[i+1]); each such range is
        // on character boundaries and cannot overlap its neighbours.
        let mut edits = Vec::new();
        let mut expected_output = String::new();
        let mut cursor = 0usize;
        for (idx, window) in boundaries.windows(2).enumerate() {
            let (start, end) = (window[0], window[1]);
            // Copy anything skipped between the previous edit and this segment (nothing, since we
            // walk consecutive segments) then decide replace-or-keep.
            prop_assert_eq!(cursor, start);
            let original = &s[start..end];
            match plan.get(idx) {
                Some((true, new_text)) => {
                    edits.push(TextEdit::replace(TextRange::new(start, end), original, new_text.clone()));
                    expected_output.push_str(new_text);
                }
                Some((false, _)) | None => {
                    expected_output.push_str(original);
                }
            }
            cursor = end;
        }
        // Tail after the last boundary pair is empty (last boundary == s.len()).
        prop_assert_eq!(cursor, s.len());

        let outcome = EditSet { edits: edits.clone() }.apply(&s).expect("disjoint non-stale edits apply");
        prop_assert_eq!(&outcome.output, &expected_output);
        prop_assert_eq!(outcome.applied, edits.len());
    }

    /// Two edits over the same non-empty range are rejected as overlapping, writing nothing.
    #[test]
    fn overlapping_edits_are_rejected(s in source_text().prop_filter("non-empty", |s| !s.is_empty())) {
        let boundaries = char_boundaries(&s);
        // Pick the first non-empty character span [b[0], b[1]).
        let (start, end) = (boundaries[0], boundaries[1]);
        let original = &s[start..end];
        let edits = vec![
            TextEdit::replace(TextRange::new(start, end), original, "X"),
            TextEdit::replace(TextRange::new(start, end), original, "Y"),
        ];
        let result = EditSet { edits }.apply(&s);
        match result {
            Err(PatchError::OverlappingEdits { .. }) => {}
            other => prop_assert!(false, "expected OverlappingEdits, got {:?}", other),
        }
    }

    /// The unified diff of an applied patch is empty exactly when the output is unchanged.
    #[test]
    fn apply_then_diff_is_consistent(
        s in source_text(),
        replace in any::<bool>(),
        new_text in "[a-z]{0,6}",
    ) {
        let boundaries = char_boundaries(&s);
        let edits = if replace && boundaries.len() >= 2 {
            let (start, end) = (boundaries[0], boundaries[1]);
            vec![TextEdit::replace(TextRange::new(start, end), &s[start..end], new_text)]
        } else {
            Vec::new()
        };
        let outcome = EditSet { edits }.apply(&s).expect("valid edits apply");
        let diff = unified_diff(&s, &outcome.output, "fixture.lean");
        prop_assert_eq!(diff.is_empty(), s == outcome.output);
    }

    /// An empty edit set is the identity: output equals source and nothing is reported applied.
    #[test]
    fn empty_edit_set_is_identity(s in source_text()) {
        let outcome = EditSet { edits: Vec::new() }.apply(&s).expect("empty edit set applies");
        prop_assert_eq!(&outcome.output, &s);
        prop_assert_eq!(outcome.applied, 0);
    }
}
