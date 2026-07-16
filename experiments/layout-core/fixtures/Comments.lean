module

/- Every position a comment can occupy, so the probe reports which token owns each one.

This is a tracked fixture rather than a generated one: it is ordinary accepted Lean and it must stay
readable, because the trivia split it measures is the whole comment contract. -/

-- leading comment, own line, before a declaration
def leadingOwnLine : Nat := 0

def trailingSameLine : Nat := 0 -- trailing comment, same line as the token

-- first of two stacked leading comments
-- second of two stacked leading comments
def stackedLeading : Nat := 0

def blankLineBefore : Nat := 0

-- comment after a blank-line run, before the declaration
def afterBlankRun : Nat := 0

def interior : Nat :=
  -- comment inside a declaration body
  0

def blockInline : Nat := /- inline block -/ 0

def trailingThenLeading : Nat := 0 -- trailing on this line
-- leading for the next one
def nextDecl : Nat := 0
