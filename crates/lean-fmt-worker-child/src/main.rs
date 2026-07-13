//! The `lean-fmt` Lean-linked worker child.
//!
//! Spawned by the parent-side `lean_fmt_worker::FormatterWorker` (never linked into
//! the parent CLI), this binary links `libleanshared` and runs the `lean-rs-worker-child`
//! stdio protocol loop. The loaded `LeanFmt` capability registers its `@[export]` commands
//! (`lean_fmt_metadata`, `lean_fmt_doctor`); the parent drives them as JSON commands.
//!
//! `stdout` is the worker protocol channel, so nothing here may write to it: no tracing
//! subscriber is installed, and the child speaks only the framed protocol.

fn main() -> std::process::ExitCode {
    lean_rs_worker_child::run_worker_child_stdio()
}
