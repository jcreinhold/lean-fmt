module

import Lean.Data.Json
import Lean.Data.Name

/-- doc payload -/
def value : Nat := 1 -- trailing payload

def blockValue : Nat := /- block payload -/ value

#exit
def tailValue : Nat := 2
