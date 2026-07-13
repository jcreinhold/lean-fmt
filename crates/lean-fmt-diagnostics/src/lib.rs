//! Diagnostic and rule-report model for lean-fmt.
//!
//! Owns the severity ladder, rule codes, and source-ranged findings the CLI renders.
//! Coordinates are 1-based, matching the Lean worker's `LeanWorkerSourceRange` contract
//! (see the prompt-02 API audit). Concrete types are added in the diagnostics-registry prompt.
