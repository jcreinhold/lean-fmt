//! `lean-fmt` binary entry point. All logic lives in the `lean_fmt_cli` library so it
//! is unit-testable; this binary only forwards the process exit code.

fn main() -> std::process::ExitCode {
    lean_fmt_cli::run()
}
