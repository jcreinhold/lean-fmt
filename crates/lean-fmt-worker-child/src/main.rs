//! The `lean-fmt` Lean-linked worker child.
//!
//! Spawned by the Lean-free `lean-fmt` application, this binary links
//! `libleanshared` and runs the `lean-rs-worker-child` stdio protocol loop. The
//! loaded capability owns every interaction with Lean.
//!
//! `stdout` is the worker protocol channel, so nothing here may write to it: no tracing
//! subscriber is installed, and the child speaks only the framed protocol.

fn main() -> std::process::ExitCode {
    lean_rs_worker_child::run_worker_child_stdio()
}
