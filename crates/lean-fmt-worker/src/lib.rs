//! Worker-boundary runtime for lean-fmt.
//!
//! Mirrors `LeanDupCapabilityRuntime` (prompt-02 audit): resolves and loads the installed
//! `LeanFmt` capability per audited workspace toolchain, registering the formatter's parse
//! and edit command exports over the `lean-rs-worker-parent` pool. The capability builder,
//! export constants, and command calls are wired in the runtime-packaging and frontend prompts.
//! This crate is the only place `libleanshared` is reached — through the worker child, never
//! linked into the parent CLI.
