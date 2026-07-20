module

public section

/-- Two notations spelling the same token range. The parser produces a `choice` node covering one byte
range with two parses; only one of them elaborates, so the module still builds.

A `Syntax` leaf walk over a `choice` is not a linear cover of the source -- it reads those tokens out
of order -- so this file is in the fixture to keep a `choice` inside the cached set. -/
notation:65 a " <?> " b => a + b
notation:65 a " <?> " b => List.append a b

def ambiguous : Nat := 7 <?> 2
