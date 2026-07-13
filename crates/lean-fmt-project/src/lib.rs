//! Lake project model and orchestration for lean-fmt.
//!
//! Discovers Lake project roots, enumerates Lean source files, and drives the
//! check / fix / diff modes. One project owns one serialized worker controller,
//! mirroring the `lean-host-mcp` host policy (prompt-02 audit). Discovery and the
//! project modes are implemented in the project-discovery and project-modes prompts.
