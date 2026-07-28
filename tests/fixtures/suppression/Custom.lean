module

import LeanFmt.Basic
import LeanFmt.Basic

syntax "greet" ident : command
macro_rules | `(greet $x) => `(def $x : Nat := 0)
-- lean-fmt: ignore-file
greet hello
