module

import AdapterSyntax

open AdapterSyntax

descriptor_command descriptorValue := twice(21)

set_option pp.universes true

explicit_command explicitValue

example : item_term(value) = value := by
  adapter_exact rfl

set_option pp.universes false
