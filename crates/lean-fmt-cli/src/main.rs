//! `lean-fmt` command-line entry point.
//!
//! This binary is the Lean-free parent: it owns argument parsing and reporting,
//! and never links `libleanshared`. Formatter behavior is added in later prompts;
//! for now the CLI only reports its version, confirming the cross-crate smoke build.

use clap::Parser;

/// A Ruff-style formatter and linter for Lean 4 Lake projects.
#[derive(Debug, Parser)]
#[command(name = "lean-fmt", version, about, long_about = None)]
struct Cli {}

fn main() {
    let _cli = Cli::parse();
    println!("lean-fmt {}", env!("CARGO_PKG_VERSION"));
}
