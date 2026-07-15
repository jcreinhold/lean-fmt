//! Link this binary against the active Lean toolchain's `libleanshared`.
//!
//! This is the one build script in the workspace that emits Lean link directives;
//! it is why `lean-fmt-worker-child` is the only artifact that links `libleanshared`.
//! The `lean-fmt` application never runs it and never links Lean.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    lean_toolchain::emit_lean_link_directives_checked()?;
    Ok(())
}
