//! Lean-free application entry point.
//!
//! The replacement execution core is introduced behind this binary. This package
//! never links Lean; all Lean interaction crosses the worker-child process boundary.

fn main() {
    println!("lean-fmt {}", env!("CARGO_PKG_VERSION"));
}
