//! Trivia classification: turning the Lean frontend's inter-token **trivia runs**
//! into typed [`Trivia`] pieces (line comments, block comments, blank-line clusters,
//! and plain whitespace).
//!
//! Only the Lean parser knows where tokens end, so Lean emits the byte ranges *between*
//! tokens (`source_model.trivia_runs`); this module owns the text scanning that turns
//! each run into comments and whitespace. The scan is **lossless**: the pieces produced
//! for a run tile it exactly — contiguous, gap-free, and covering every byte — so no
//! comment can silently disappear ([`trivia_tiles_runs`]).
//!
//! Docstrings (`/-- … -/`, `/-! … -/`) are *not* trivia — they parse to syntax nodes
//! and arrive separately as `source_model.docstrings`, so this module never sees them
//! inside a run.

use crate::source::TextRange;
use serde::{Deserialize, Serialize};

/// The kind of a [`Trivia`] piece.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriviaKind {
    /// A `--` line comment, running to (but not including) the end-of-line newline.
    LineComment,
    /// A `/- … -/` block comment, honoring nested `/- … -/` pairs.
    BlockComment,
    /// A whitespace run containing two or more newlines — a blank-line separator.
    BlankLines,
    /// A whitespace run with at most one newline (indentation, a single line break).
    Whitespace,
}

/// One classified span of trivia, anchored to a byte [`TextRange`] in the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trivia {
    /// What the span is.
    pub kind: TriviaKind,
    /// The span's byte range.
    pub range: TextRange,
    /// The start byte of the trivia run this piece belongs to. Because a run is the gap
    /// after a token (Lean's trailing-trivia convention), this identifies the run and is
    /// stable under re-classification; leading trivia before the first token has `0`.
    pub run_start: usize,
}

/// Classify every run in `runs` into typed [`Trivia`] pieces, in source order.
///
/// Each run is scanned independently and tiled losslessly. Runs that fall outside the
/// source bounds (or that are not on character boundaries) are skipped rather than
/// panicking, but for well-formed frontend output every run is covered.
#[must_use]
pub fn classify_trivia(source: &str, runs: &[TextRange]) -> Vec<Trivia> {
    let mut out = Vec::new();
    for run in runs {
        classify_run(source, *run, &mut out);
    }
    out
}

/// Scan a single run `[run.start, run.end)`, pushing its pieces onto `out`.
fn classify_run(source: &str, run: TextRange, out: &mut Vec<Trivia>) {
    // Bail out (rather than emit a partial tiling) if the run is not real text.
    if source.get(run.start..run.end).is_none() {
        return;
    }
    let mut pos = run.start;
    while pos < run.end {
        let Some(rest) = source.get(pos..run.end) else {
            break;
        };
        let (kind, stop) = if rest.starts_with("--") {
            // Line comment: up to, but not including, the next newline in the run.
            let stop = rest.find('\n').map_or(run.end, |nl| pos.saturating_add(nl));
            (TriviaKind::LineComment, stop)
        } else if rest.starts_with("/-") {
            (TriviaKind::BlockComment, block_comment_end(source, pos, run.end))
        } else {
            classify_whitespace(source, pos, run.end)
        };
        // `stop` never regresses: comment scanners consume their opener, and the
        // whitespace scanner advances at least one char, so the loop terminates.
        let stop = stop.max(pos.saturating_add(1)).min(run.end);
        out.push(Trivia {
            kind,
            range: TextRange::new(pos, stop),
            run_start: run.start,
        });
        pos = stop;
    }
}

/// Find the end offset of a `/- … -/` block comment starting at `start`, honoring
/// nested pairs. Returns `end` for an unterminated comment (the rest of the run).
fn block_comment_end(source: &str, start: usize, end: usize) -> usize {
    let mut depth: usize = 0;
    let mut pos = start;
    while pos < end {
        let Some(rest) = source.get(pos..end) else {
            return end;
        };
        if rest.starts_with("/-") {
            depth = depth.saturating_add(1);
            pos = pos.saturating_add(2);
        } else if rest.starts_with("-/") {
            depth = depth.saturating_sub(1);
            pos = pos.saturating_add(2);
            if depth == 0 {
                return pos;
            }
        } else {
            let step = rest.chars().next().map_or(1, char::len_utf8);
            pos = pos.saturating_add(step);
        }
    }
    end
}

/// Consume a maximal whitespace stretch from `start`, stopping at the next comment
/// opener or at `end`. Returns [`TriviaKind::BlankLines`] when the stretch holds two or
/// more newlines, otherwise [`TriviaKind::Whitespace`]. A leading non-whitespace,
/// non-comment byte (which well-formed frontend output never produces) is consumed as a
/// single [`TriviaKind::Whitespace`] char so the tiling stays lossless.
fn classify_whitespace(source: &str, start: usize, end: usize) -> (TriviaKind, usize) {
    let mut pos = start;
    let mut newlines: usize = 0;
    while pos < end {
        let Some(rest) = source.get(pos..end) else {
            break;
        };
        if rest.starts_with("--") || rest.starts_with("/-") {
            break;
        }
        let Some(ch) = rest.chars().next() else {
            break;
        };
        if !ch.is_whitespace() {
            break;
        }
        if ch == '\n' {
            newlines = newlines.saturating_add(1);
        }
        pos = pos.saturating_add(ch.len_utf8());
    }
    if pos == start {
        // Defensive: a stray non-whitespace byte. Consume one char to make progress.
        let step = source
            .get(start..end)
            .and_then(|r| r.chars().next())
            .map_or(1, char::len_utf8);
        return (TriviaKind::Whitespace, start.saturating_add(step));
    }
    let kind = if newlines >= 2 {
        TriviaKind::BlankLines
    } else {
        TriviaKind::Whitespace
    };
    (kind, pos)
}

/// Check the lossless-partition invariant — the "no comment disappears" guarantee.
///
/// Within every run in `runs`, the [`Trivia`] pieces tagged with that run's start must be
/// contiguous, gap-free, and cover the run exactly: the classification of a run is a
/// tiling of it, never a lossy sampling.
#[must_use]
pub fn trivia_tiles_runs(runs: &[TextRange], trivia: &[Trivia]) -> bool {
    for run in runs {
        let mut cursor = run.start;
        for piece in trivia.iter().filter(|t| t.run_start == run.start) {
            if piece.range.start != cursor {
                return false;
            }
            if piece.range.end < piece.range.start || piece.range.end > run.end {
                return false;
            }
            cursor = piece.range.end;
        }
        if cursor != run.end {
            return false;
        }
    }
    true
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::{Trivia, TriviaKind, classify_trivia, trivia_tiles_runs};
    use crate::source::TextRange;

    /// Assert the pieces tile every run and return them for further inspection.
    fn classify_checked(source: &str, runs: &[TextRange]) -> Vec<Trivia> {
        let trivia = classify_trivia(source, runs);
        assert!(
            trivia_tiles_runs(runs, &trivia),
            "classification must tile every run losslessly"
        );
        trivia
    }

    fn kinds(trivia: &[Trivia]) -> Vec<TriviaKind> {
        trivia.iter().map(|t| t.kind).collect()
    }

    #[test]
    fn line_comment_stops_before_newline() {
        let src = "x-- hello\n";
        // Run is everything after the `x` token: `-- hello\n`.
        let runs = [TextRange::new(1, src.len())];
        let trivia = classify_checked(src, &runs);
        assert_eq!(kinds(&trivia), [TriviaKind::LineComment, TriviaKind::Whitespace]);
        assert_eq!(src.get(trivia[0].range.start..trivia[0].range.end), Some("-- hello"));
        assert_eq!(src.get(trivia[1].range.start..trivia[1].range.end), Some("\n"));
    }

    #[test]
    fn blank_lines_vs_single_whitespace() {
        let src = "a\n\nb\nc";
        // Two runs: `\n\n` (blank line) and `\n` (single break).
        let runs = [TextRange::new(1, 3), TextRange::new(4, 5)];
        let trivia = classify_checked(src, &runs);
        assert_eq!(kinds(&trivia), [TriviaKind::BlankLines, TriviaKind::Whitespace]);
    }

    #[test]
    fn nested_block_comment() {
        let src = "/- outer /- inner -/ still outer -/x";
        let runs = [TextRange::new(0, 35)]; // up to the `x` token
        let trivia = classify_checked(src, &runs);
        assert_eq!(kinds(&trivia), [TriviaKind::BlockComment]);
        assert_eq!(
            src.get(trivia[0].range.start..trivia[0].range.end),
            Some("/- outer /- inner -/ still outer -/"),
            "nested -/ must not close the outer comment early"
        );
    }

    #[test]
    fn unterminated_block_comment_runs_to_end() {
        let src = "/- never closed";
        let runs = [TextRange::new(0, src.len())];
        let trivia = classify_checked(src, &runs);
        assert_eq!(kinds(&trivia), [TriviaKind::BlockComment]);
        assert_eq!(trivia[0].range.end, src.len());
    }

    #[test]
    fn mixed_run_line_blank_block_whitespace() {
        // The load-bearing case from the live envelope: one run holding a line comment,
        // blank lines, a block comment, and a trailing newline (byte 68..105 there).
        let src = " -- trailing\n\n/- block\n   comment -/\n";
        let runs = [TextRange::new(0, src.len())];
        let trivia = classify_checked(src, &runs);
        assert_eq!(
            kinds(&trivia),
            [
                TriviaKind::Whitespace,   // leading space
                TriviaKind::LineComment,  // -- trailing
                TriviaKind::BlankLines,   // \n\n
                TriviaKind::BlockComment, // /- block\n   comment -/
                TriviaKind::Whitespace,   // trailing \n
            ]
        );
        assert_eq!(src.get(trivia[1].range.start..trivia[1].range.end), Some("-- trailing"));
        assert_eq!(
            src.get(trivia[3].range.start..trivia[3].range.end),
            Some("/- block\n   comment -/")
        );
    }

    #[test]
    fn unicode_inside_comment_stays_lossless() {
        // Multibyte content in a comment must not break byte accounting.
        let src = "-- φ ≤ 🚀 done\ny";
        let nl = src.find('\n').unwrap();
        let runs = [TextRange::new(0, nl + 1)];
        let trivia = classify_checked(src, &runs);
        assert_eq!(kinds(&trivia), [TriviaKind::LineComment, TriviaKind::Whitespace]);
        assert_eq!(
            src.get(trivia[0].range.start..trivia[0].range.end),
            Some("-- φ ≤ 🚀 done")
        );
    }

    #[test]
    fn run_start_identifies_the_owning_run() {
        let src = "a-- c1\nb-- c2\n";
        let runs = [TextRange::new(1, 7), TextRange::new(8, src.len())];
        let trivia = classify_checked(src, &runs);
        for piece in &trivia {
            assert!(piece.run_start == 1 || piece.run_start == 8);
            assert!(piece.range.start >= piece.run_start);
        }
    }

    #[test]
    fn tiling_check_rejects_a_dropped_run() {
        // A run with no classified pieces must fail the tiling invariant.
        let runs = [TextRange::new(0, 3)];
        assert!(!trivia_tiles_runs(&runs, &[]), "an uncovered run is not tiled");
    }
}
