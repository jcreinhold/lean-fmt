module

syntax "emit_local_command" : command

macro_rules
  | `(emit_local_command) => `(#check Nat)

emit_local_command
