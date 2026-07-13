//! Conservative text-edit and patch engine for lean-fmt.
//!
//! This crate's foundation is the **source coordinate and span model**: byte-accurate
//! ranges into UTF-8 source, their 1-based line / 0-based codepoint-column display
//! form, and the syntax regions the Lean frontend reports. Byte offsets are the
//! internal source of truth for every edit; line/column is derived only for display.
//!
//! Column counting matches Lean's own [`FileMap`]: a column is a count of Unicode
//! **codepoints** from the start of the line, not bytes. [`SourceMap`] reproduces that
//! exactly so a `TextRange` computed here lands on the same character Lean's compiler
//! would report. The versioned edit protocol and patch application land in the
//! edit-protocol prompt; this module is the substrate they build on.
//!
//! [`FileMap`]: https://leanprover.github.io/theorem_proving_in_lean4/

mod source;

pub use source::{LineColumn, LineColumnRange, SourceMap, SyntaxRegion, TextRange};
