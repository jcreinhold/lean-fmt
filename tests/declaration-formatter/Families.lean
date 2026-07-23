module

namespace DeclarationFixture

universe u
variable {α : Type u}

syntax "wrapped{" term "}" : term
macro_rules
  | `(wrapped{ $value }) => `($value)

@[inline] private def modifiedValue (input : Nat) : Nat := input

def «name with spaces» : Nat := 1

abbrev VeryLongAliasName (α : Type u) := List (List α)

opaque opaqueValue (first second : Nat) : Nat := first + second

axiom assumedValue (α : Type u) (value : α) : α

example (left right : Nat) : Nat := wrapped{ left + right }

instance [Inhabited α] : Inhabited (α × α) where
  default := (default, default)

structure Packet (α : Type u) where
  first : α
  second : α
  count : Nat := 0
  deriving Repr

class HasValue (α : Type u) where
  value : α

inductive Choice (α : Type u) where
  | neither
  | left (value : α)
  | right (value : α)
  deriving Repr

mutual
  def isEven : Nat → Bool
    | 0 => true
    | n + 1 => isOdd n

  def isOdd : Nat → Bool
    | 0 => false
    | n + 1 => isEven n
end

def countdown : Nat → Nat
  | 0 => 0
  | n + 1 => countdown n
termination_by n => n

def withLocal (value : Nat) : Nat := localValue + value
where
  localValue : Nat := 1

end DeclarationFixture
