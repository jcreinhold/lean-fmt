import Lake
open Lake DSL

package fixture

@[default_target]
lean_lib Fixture where
  globs := #[Glob.submodules `Fixture]
