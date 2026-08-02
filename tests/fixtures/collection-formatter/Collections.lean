module

namespace CollectionFixture

structure Packet where
  first : Nat
  second : Nat
  third : Nat

syntax:max "custom{" term "}" : term

macro_rules
  | `(custom{ $value }) => `($value)

def emptyList : List Nat := []

def singleton (alpha : Nat) : List Nat := [alpha]

def tupleValue (alpha beta gamma delta : Nat) : Nat × Nat × Nat × Nat :=
  (alpha, beta, gamma, delta)

def listValue (alpha beta gamma delta epsilon : Nat) : List Nat :=
  [alpha, beta, gamma, delta, epsilon]

def trailingList (alpha beta gamma : Nat) : List Nat :=
  [alpha, beta, gamma,]

def trailingArray (alpha beta gamma : Nat) : Array Nat :=
  #[alpha, beta, gamma,]

def trailingTuple (alpha beta gamma : Nat) : Nat × Nat × Nat :=
  (alpha, beta, gamma,)

def trailingAnonymous (alpha beta gamma : Nat) : Packet :=
  ⟨alpha, beta, gamma,⟩

def trailingRecord (alpha beta gamma : Nat) : Packet :=
  { first := alpha, second := beta, third := gamma, }

def singleTrailing (alpha : Nat) : Array Nat :=
  #[alpha,]

def nestedTrailing (alpha beta gamma : Nat) : Array Nat × Array Nat :=
  (#[alpha, beta,], #[gamma,],)

def commentedTrailing (alpha beta gamma : Nat) : Array Nat :=
  #[
    -- leading comment
    alpha, beta, gamma,]

def arrayValue (alpha beta gamma delta epsilon : Nat) : Array Nat :=
  #[alpha, beta, gamma, delta, epsilon]

def anonymousValue (alpha beta gamma : Nat) : Packet :=
  ⟨alpha, beta, gamma⟩

def leftAssociative (alpha beta gamma delta epsilon : Nat) : Nat :=
  alpha + beta + gamma + delta + epsilon

def rightAssociative (alpha beta gamma delta epsilon : Nat) : Nat :=
  alpha ^ beta ^ gamma ^ delta ^ epsilon

def arrowAssociation : Type :=
  Nat → Nat → Nat → Nat → Nat

def recordValue (alpha beta gamma : Nat) : Packet :=
  { first := alpha, second := beta, third := gamma }

def shorthandRecord (first second third : Nat) : Packet :=
  { first, second, third }

def typedRecord (alpha beta gamma : Nat) : Packet :=
  { first := alpha, second := beta, third := gamma : Packet }

def ellipsisRecord (alpha : Nat) : Packet :=
  { first := alpha, second := 0, third := 0, .. }

def recordUpdate (packet : Packet) (alpha beta : Nat) : Packet :=
  { packet with first := alpha, second := beta }

def layoutRecord (alpha beta gamma : Nat) : Packet :=
  { first := alpha
    second := beta
    third := gamma }

def matchValue (value alpha beta gamma : Nat) : Nat :=
  match value with
  | 0 => alpha
  | 1 => beta
  | _ => gamma

def customEntry (alpha beta gamma : Nat) : List Nat :=
  [custom{ alpha }, beta, gamma]

def customArm (value alpha beta : Nat) : Nat :=
  match value with
  | 0 => custom{ alpha }
  | _ => beta

def commented : List Nat := [1, 2]

end CollectionFixture
