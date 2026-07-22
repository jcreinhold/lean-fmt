import Lake

open Lake DSL

package frontendNativeAudit

lean_lib AuditSyntaxLib where
  roots := #[`AuditSyntax]

lean_exe frontendNativeAudit where
  root := `Probe
  supportInterpreter := true
