import Lake
open Lake DSL

-- The `LeanFmt` Lean capability package. At the scaffold stage this is a
-- dependency-free library exporting placeholder metadata only; the real
-- `lean-rs-worker` capability exports (parse/format commands, shared facet)
-- are wired in the runtime-packaging and frontend prompts, at which point the
-- upstream `lean-rs` interop shims are required and the shared facet is enabled.
package «lean-fmt» where
  version := v!"0.1.0"

@[default_target]
lean_lib LeanFmt where
  roots := #[`LeanFmt]
  globs := #[.andSubmodules `LeanFmt]
