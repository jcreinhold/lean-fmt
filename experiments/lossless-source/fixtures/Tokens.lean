module

/-! Token payloads whose source text may differ from the parsed atom value. -/

def unicodeArrow : Nat → Nat := fun n => n
def asciiArrow : Nat -> Nat := fun n => n

def «escaped identifier» : Nat := 0
def usesEscaped : Nat := «escaped identifier»

def stringEscape : String := "tab\there\nnewline é \"quoted\""
def rawString : String := r"no \escape here"
def charLit : Char := 'é'

def hexLiteral : Nat := 0xFF
def binLiteral : Nat := 0b1010
def octLiteral : Nat := 0o17
def decLiteral : Nat := 255
def scientific : Float := 1.5e3

def unicodeIdent (α : Type) (xs : List α) : List α := xs
def «with.dot» : Nat := 0

theorem lambdaForms : True := by
  have _f : Nat → Nat := fun x => x
  have _g : Nat → Nat := λ x => x
  trivial
