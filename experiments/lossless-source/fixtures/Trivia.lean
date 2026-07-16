module

/-! Doc comment module header. -/

-- A line comment before a command.

/- A block comment
   spanning lines. -/

/-- A doc comment attached to a declaration. -/
def withDocComment : Nat := 0

def afterBlankLines : Nat :=
  -- comment inside a term

  1

/- nested /- block -/ comment -/
def afterNested : Nat := 2

-- trailing comment with no command after it
