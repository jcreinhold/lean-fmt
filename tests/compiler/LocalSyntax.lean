module

/-! A module doc. This is a token, not trivia: `Lean/Parser/Basic.lean:584` records that
doc-comment and module-doc openers are real tokens, so the projection must carry this text as a
leaf rather than as a comment run. -/

-- A line comment, which is trivia, and runs to but not including its newline.
/- A block comment /- nested inside another -/ that closes only at the outer terminator. -/

syntax "emit_local_command" : command

macro_rules
  | `(emit_local_command) => `(#check Nat)

emit_local_command

/-- A doc comment attached to a declaration: also a token. -/
def «an identifier with spaces» : String := "λ → ∀ 🎉"

def αβγ : Nat := 42 -- a trailing line comment after real code

structure Ambiguous where
  first : Nat
  second : Nat

/- `{ first, second }` parses both as a structure instance and as a set-like literal, so the parser
emits a `choice` node holding both trees over one byte range. The projection must take exactly one
alternative: walking every one would spell these bytes once per alternative. -/
def choiceNode (first second : Nat) : Ambiguous := { first, second }
