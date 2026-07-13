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
//! would report.
//!
//! On top of the coordinate model sits the **trivia model**: the Lean frontend reports
//! the byte ranges *between* tokens (`source_model.trivia_runs`), and [`classify_trivia`]
//! turns each run into typed [`Trivia`] pieces — line/block comments, blank-line
//! clusters, and whitespace — tiling every run losslessly ([`trivia_tiles_runs`]).
//!
//! The **edit protocol** is the currency rules speak: a [`Diagnostic`] carries an optional
//! [`EditSet`] of byte-anchored [`TextEdit`]s, and [`EditSet::apply`] applies them
//! conflict- and staleness-checked — a stale or overlapping edit is rejected rather than
//! silently rewriting the wrong bytes. [`unified_diff`] renders the before/after.
//!
//! [`FileMap`]: https://leanprover.github.io/theorem_proving_in_lean4/

mod edit;
mod source;
mod trivia;

pub use edit::{Applicability, Diagnostic, EditSet, PatchError, PatchOutcome, RuleId, SCHEMA, TextEdit, unified_diff};
pub use source::{
    BinderSpan, DeclHeaderRecord, ImportRecord, LineColumn, LineColumnRange, SourceMap, SyntaxRegion, TextRange,
};
pub use trivia::{Trivia, TriviaKind, classify_trivia, trivia_tiles_runs};
