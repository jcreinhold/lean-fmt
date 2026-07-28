module

public section

/-- Two notations spelling the same token range: the parser produces a `choice` node covering
one byte range with two parses, of which only one elaborates, so the module still builds.

A `Syntax` leaf walk over a `choice` is not a linear cover of the source -- it reads those tokens
out of order -- so this file keeps a `choice` inside the cached set. -/
notation:65 a " <?> " b => a + b
notation:65 a " <?> " b => List.append a b

def ambiguous : Nat := 7 <?> 2
