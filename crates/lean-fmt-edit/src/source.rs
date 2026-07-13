//! Source coordinate and span model: byte ranges, line/column display coordinates,
//! syntax regions, and the byte↔line/column [`SourceMap`].
//!
//! Byte offsets are the internal source of truth. Line/column is derived for display
//! only, and columns are counted in Unicode **codepoints** from the start of the line,
//! matching Lean's `FileMap` (a `SourceMap` built here reports the same coordinates the
//! Lean frontend does for the same offset).

use serde::{Deserialize, Serialize};

/// A half-open byte range `[start, end)` into UTF-8 source.
///
/// Offsets are byte indices — `String.Pos` on the Lean side — and are the internal
/// source of truth for every edit. Line/column is only ever derived from these.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextRange {
    /// Inclusive start byte offset.
    pub start: usize,
    /// Exclusive end byte offset.
    pub end: usize,
}

impl TextRange {
    /// Construct a byte range from `start` (inclusive) to `end` (exclusive).
    #[must_use]
    pub const fn new(start: usize, end: usize) -> Self {
        Self { start, end }
    }

    /// The number of bytes the range spans (saturating; `0` if `end < start`).
    #[must_use]
    pub const fn len(self) -> usize {
        self.end.saturating_sub(self.start)
    }

    /// Whether the range spans no bytes (`start >= end`).
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.start >= self.end
    }

    /// Whether `offset` lies within `[start, end)`.
    #[must_use]
    pub const fn contains(self, offset: usize) -> bool {
        self.start <= offset && offset < self.end
    }

    /// Whether the range is ordered and lies within `[0, source_len]` — the invariant
    /// every emitted span must satisfy (`start <= end <= source_len`).
    #[must_use]
    pub const fn is_well_formed(self, source_len: usize) -> bool {
        self.start <= self.end && self.end <= source_len
    }
}

/// A source position: 1-based `line`, 0-based `column`.
///
/// `column` counts Unicode codepoints from the start of the line (not bytes), exactly
/// as `Lean.Position` does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineColumn {
    /// 1-based line number.
    pub line: u32,
    /// 0-based codepoint column within the line.
    pub column: u32,
}

impl LineColumn {
    /// Construct a position from a 1-based `line` and 0-based codepoint `column`.
    #[must_use]
    pub const fn new(line: u32, column: u32) -> Self {
        Self { line, column }
    }
}

/// The display coordinates of a [`TextRange`]: start and end [`LineColumn`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineColumnRange {
    /// Position of the range's start byte.
    pub start: LineColumn,
    /// Position of the range's end byte.
    pub end: LineColumn,
}

/// A parsed syntax node's byte span plus its display coordinates and node kind.
///
/// This is the decoded form of one `syntax_summary.command_regions` entry returned by
/// the Lean `lean_fmt_parse_file` command.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyntaxRegion {
    /// The syntax node kind (e.g. `Lean.Parser.Command.declaration`).
    pub kind: String,
    /// The node's byte range.
    pub range: TextRange,
    /// The node's display coordinates, as computed by Lean's `FileMap`.
    pub line_column: LineColumnRange,
}

/// One `import` statement: its module name and the byte range of the whole statement.
///
/// This is the decoded form of one `module_header.import_spans` entry returned by the
/// Lean `lean_fmt_parse_file` command. The `range` spans the `import` keyword through
/// the module ident (including any modifiers), but excludes the leading comment/blank
/// trivia before the statement — that attachment is recovered from the source text by
/// the import-sort rule, not from this record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportRecord {
    /// The imported module name (e.g. `Mathlib.Data.Nat.Basic`).
    pub module: String,
    /// The byte range of the whole `import` statement.
    pub range: TextRange,
}

/// A byte↔line/column map over UTF-8 source.
///
/// Reproduces Lean's `FileMap` codepoint-based column counting so a `TextRange`
/// resolved here lands on the same character the compiler would report. Borrows the
/// source and precomputes line starts in one linear scan.
#[derive(Debug, Clone)]
pub struct SourceMap<'a> {
    source: &'a str,
    /// Byte offset of the first character of each line; `line_starts[0] == 0`.
    line_starts: Vec<usize>,
}

impl<'a> SourceMap<'a> {
    /// Build a coordinate map over `source`.
    #[must_use]
    pub fn new(source: &'a str) -> Self {
        let mut line_starts = vec![0_usize];
        for (idx, byte) in source.bytes().enumerate() {
            if byte == b'\n' {
                line_starts.push(idx.saturating_add(1));
            }
        }
        Self { source, line_starts }
    }

    /// The source length in bytes.
    #[must_use]
    pub const fn source_len(&self) -> usize {
        self.source.len()
    }

    /// The number of lines (a trailing newline does not add an empty final line count
    /// beyond the `line_starts` scan; this is `line_starts.len()`).
    #[must_use]
    pub fn line_count(&self) -> usize {
        self.line_starts.len()
    }

    /// Convert a byte `offset` to its [`LineColumn`].
    ///
    /// The column counts codepoints from the line start. An `offset` past the end of
    /// the source clamps to the source length on the final line.
    #[must_use]
    pub fn line_column(&self, offset: usize) -> LineColumn {
        // Largest line index whose start byte is `<= offset`. `line_starts[0] == 0`
        // and `offset >= 0`, so the partition point is always `>= 1`.
        let line_idx = self
            .line_starts
            .partition_point(|&start| start <= offset)
            .saturating_sub(1);
        let line_start = self.line_starts.get(line_idx).copied().unwrap_or(0);
        let clamped = offset.min(self.source.len());
        let column = self
            .source
            .get(line_start..clamped)
            .map_or(0, |segment| segment.chars().count());
        LineColumn {
            line: u32::try_from(line_idx.saturating_add(1)).unwrap_or(u32::MAX),
            column: u32::try_from(column).unwrap_or(u32::MAX),
        }
    }

    /// Convert a [`LineColumn`] back to a byte offset.
    ///
    /// Returns `None` when the line is out of range or the column exceeds the number of
    /// codepoints on that line. A column equal to the line's codepoint length maps to
    /// the line's terminating position (the newline byte, or the source end).
    #[must_use]
    pub fn byte_offset(&self, pos: LineColumn) -> Option<usize> {
        let line_idx = usize::try_from(pos.line).ok()?.checked_sub(1)?;
        let line_start = self.line_starts.get(line_idx).copied()?;
        let line_end = self
            .line_starts
            .get(line_idx.saturating_add(1))
            .copied()
            .unwrap_or(self.source.len());
        let segment = self.source.get(line_start..line_end)?;
        let mut byte = line_start;
        let mut col: u32 = 0;
        for ch in segment.chars() {
            if col == pos.column {
                return Some(byte);
            }
            byte = byte.saturating_add(ch.len_utf8());
            col = col.saturating_add(1);
        }
        if col == pos.column { Some(byte) } else { None }
    }

    /// Convert a byte [`TextRange`] to its [`LineColumnRange`].
    #[must_use]
    pub fn line_column_range(&self, range: TextRange) -> LineColumnRange {
        LineColumnRange {
            start: self.line_column(range.start),
            end: self.line_column(range.end),
        }
    }

    /// The byte slice covered by `range`, or `None` if it is out of bounds or not on
    /// character boundaries.
    #[must_use]
    pub fn slice(&self, range: TextRange) -> Option<&'a str> {
        self.source.get(range.start..range.end)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing, clippy::arithmetic_side_effects)]
mod tests {
    use super::{LineColumn, LineColumnRange, SourceMap, SyntaxRegion, TextRange};

    #[test]
    fn text_range_helpers() {
        let r = TextRange::new(3, 8);
        assert_eq!(r.len(), 5);
        assert!(!r.is_empty());
        assert!(r.contains(3));
        assert!(r.contains(7));
        assert!(!r.contains(8));
        assert!(TextRange::new(5, 5).is_empty());
        assert_eq!(TextRange::new(9, 4).len(), 0, "reversed range saturates to 0");
        assert!(r.is_well_formed(8));
        assert!(!r.is_well_formed(7), "end past source length is ill-formed");
        assert!(!TextRange::new(9, 4).is_well_formed(20), "start > end is ill-formed");
    }

    #[test]
    fn ascii_line_column_round_trip() {
        let src = "abc\ndef\n\nghij\n";
        let map = SourceMap::new(src);
        // Every byte boundary round-trips through line/column.
        for offset in 0..=src.len() {
            let lc = map.line_column(offset);
            assert_eq!(
                map.byte_offset(lc),
                Some(offset),
                "round-trip failed at byte {offset} (lc = {lc:?})"
            );
        }
        assert_eq!(map.line_column(0), LineColumn::new(1, 0));
        assert_eq!(map.line_column(4), LineColumn::new(2, 0), "start of line 2");
        assert_eq!(map.line_column(6), LineColumn::new(2, 2));
        assert_eq!(map.line_column(8), LineColumn::new(3, 0), "empty line 3");
    }

    #[test]
    fn multibyte_columns_count_codepoints_not_bytes() {
        // `φ` is 2 bytes, `🚀` is 4 bytes; columns must count them as one each.
        let src = "def fφo := 1\nx🚀y\n";
        let map = SourceMap::new(src);
        // `def fφo := 1` is 13 bytes but 12 codepoints; the trailing newline sits at
        // byte 13 and column 12.
        let newline1 = src.find('\n').unwrap();
        assert_eq!(newline1, 13);
        assert_eq!(map.line_column(newline1), LineColumn::new(1, 12));
        // Line 2: `x🚀y`. `y` is after `x` (1 byte) + `🚀` (4 bytes) = byte 14+5 = 19.
        let line2_start = newline1 + 1;
        let y_byte = line2_start + "x🚀".len();
        assert_eq!(map.line_column(y_byte), LineColumn::new(2, 2), "y is column 2");
        // Round-trip every char boundary.
        for (offset, _) in src.char_indices().chain(std::iter::once((src.len(), ' '))) {
            let lc = map.line_column(offset);
            assert_eq!(map.byte_offset(lc), Some(offset), "round-trip at byte {offset}");
        }
    }

    #[test]
    fn boundary_and_out_of_range() {
        let src = "ab\ncd";
        let map = SourceMap::new(src);
        assert_eq!(map.line_count(), 2);
        // Offset past the end clamps to the last line.
        assert_eq!(map.line_column(src.len()), LineColumn::new(2, 2));
        assert_eq!(map.line_column(1000), LineColumn::new(2, 2), "clamps past end");
        // Column past the line length is not resolvable.
        assert_eq!(map.byte_offset(LineColumn::new(1, 99)), None);
        assert_eq!(map.byte_offset(LineColumn::new(9, 0)), None, "no such line");
        assert_eq!(map.byte_offset(LineColumn::new(0, 0)), None, "lines are 1-based");
    }

    #[test]
    fn line_column_range_and_slice() {
        let src = "import Init\n\ndef foo := 1\n";
        let map = SourceMap::new(src);
        let decl = TextRange::new(13, 25); // `def foo := 1` (12 bytes)
        assert_eq!(
            map.line_column_range(decl),
            LineColumnRange {
                start: LineColumn::new(3, 0),
                end: LineColumn::new(3, 12),
            }
        );
        assert_eq!(map.slice(decl), Some("def foo := 1"));
        assert_eq!(map.slice(TextRange::new(13, 1000)), None, "out of bounds slice");
    }

    #[test]
    fn syntax_region_decodes_from_lean_envelope() {
        // Exactly the shape emitted by `syntax_summary.command_regions`.
        let json = r#"{
            "kind": "Lean.Parser.Command.declaration",
            "range": { "start": 13, "end": 32 },
            "line_column": {
                "start": { "line": 3, "column": 0 },
                "end": { "line": 3, "column": 18 }
            }
        }"#;
        let region: SyntaxRegion = serde_json::from_str(json).unwrap();
        assert_eq!(region.kind, "Lean.Parser.Command.declaration");
        assert_eq!(region.range, TextRange::new(13, 32));
        assert_eq!(region.line_column.start, LineColumn::new(3, 0));
        assert_eq!(region.line_column.end, LineColumn::new(3, 18));
        assert_eq!(region.range.len(), 19, "byte span is 19 bytes wide");
    }
}
