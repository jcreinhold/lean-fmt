//! Shared horizontal-whitespace-run scanning for the spacing rules.
//!
//! Both `declaration/header-spacing` and `tactic/block-indent` normalize the ASCII
//! space/tab run adjacent to a parse-tree anchor. These helpers find the extent of such
//! a run and classify its line context, so a rule never scans for a token and never
//! crosses a line break by accident.

/// The first byte of the maximal run of ASCII spaces/tabs ending at `pos` (scanning
/// left). A run that reaches a newline or a non-whitespace byte stops there.
pub(crate) fn scan_ws_left(bytes: &[u8], pos: usize) -> usize {
    let mut a = pos;
    while a > 0 {
        match bytes.get(a.saturating_sub(1)) {
            Some(b' ' | b'\t') => a = a.saturating_sub(1),
            _ => break,
        }
    }
    a
}

/// The byte just past the maximal run of ASCII spaces/tabs starting at `pos` (scanning
/// right).
pub(crate) fn scan_ws_right(bytes: &[u8], pos: usize) -> usize {
    let mut b = pos;
    while let Some(&c) = bytes.get(b) {
        if c == b' ' || c == b'\t' {
            b = b.saturating_add(1);
        } else {
            break;
        }
    }
    b
}

/// Whether `byte` begins a new line (so a gap touching it must be left alone).
pub(crate) const fn is_newline(byte: u8) -> bool {
    byte == b'\n' || byte == b'\r'
}
