module

import AdapterSyntax

open AdapterSyntax

/- descriptor comment payload -/
descriptor_command narrow := [twice(1), twice(2), twice(3), twice(4), twice(5)]

explicit_command selectedName

def extensionTerm : Nat := twice(21)

def extensionTactic : True := by
  adapter_exact True.intro

def extensionCategory : Nat := item_term(selectedName)
