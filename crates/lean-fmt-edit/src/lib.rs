//! Conservative text-edit and patch engine for lean-fmt.
//!
//! Every edit is source-ranged (1-based), conflict-checked against the on-disk text,
//! and reversible through a diff. Only edits with explicit rule support are ever applied.
//! The versioned edit protocol and patch application land in the edit-protocol prompt.
