import Lake

open Lake DSL

package frontendFormatter

lean_lib PrototypeSyntaxLib where
  roots := #[`PrototypeSyntax]

lean_exe frontendFormatter where
  root := `FormatterPrototype
  supportInterpreter := true
