module

namespace FrontierMix

syntax "twice " term : term

macro_rules
  | `(twice $value) => `($value + $value)

universe u

axiom opaqueValue : Nat

def value (a : Nat) : Nat := twice a

structure Point where
  x : Nat
  y : Nat
deriving Repr

attribute [simp] value

example : Nat := value 1

variable (base : Nat)

def addBase (x : Nat) : Nat := x + base

include base

def addBaseAgain (x : Nat) : Nat := x + base

omit base

section Scoped

set_option pp.all true in
#check value

end Scoped

#check addBase
#eval value 2
#print value
#synth Inhabited Nat

export Nat (succ)

end FrontierMix
