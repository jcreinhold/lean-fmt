module

import Lean

/-! File-local parser extensions, quotations, and antiquotations. A projection built from a token
table that does not include this file's own `syntax` declarations cannot reconstruct these bytes. -/

open Lean

syntax "my_local_cmd" (ppSpace ident)? : command

macro_rules
  | `(command| my_local_cmd) => `(#check Nat)
  | `(command| my_local_cmd $n:ident) => `(#check $n)

my_local_cmd

my_local_cmd Nat

notation:65 lhs:65 " ⋄ " rhs:66 => lhs + rhs

def usesNotation : Nat := 1 ⋄ 2

/-- A quotation with an antiquotation splice. -/
def quoted (n : Term) : MacroM Term := `(fun x => $n + x)

/-- A quotation containing a comment and unusual spacing. -/
def quotedTrivia : MacroM Term := `(
  -- comment inside a quotation
  1   +   2
)

declare_syntax_cat mycat
syntax "alpha" : mycat
syntax "beta" mycat : mycat
syntax "run_mycat " mycat : command

macro_rules
  | `(command| run_mycat alpha) => `(#check 0)
  | `(command| run_mycat beta $_c) => `(#check 1)

run_mycat alpha
run_mycat beta alpha
