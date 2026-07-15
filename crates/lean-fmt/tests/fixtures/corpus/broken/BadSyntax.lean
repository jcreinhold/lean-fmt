import Init

/-! A syntactically broken declaration body: the term after `:=` is missing, so the file
parse-fails and the formatter must report it as broken rather than format it. (The header is
valid — a broken *import header* crashes the Lean frontend outright, a distinct fatal path the
formatter surfaces as a worker error, not a `Broken` result.) -/

def bad (n : Nat) : Nat :=
