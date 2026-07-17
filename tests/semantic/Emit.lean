module

import Lean

/-! Independent oracle for the fresh-frontend differential. `run.sh` captures the declared spacing of
core `+`/`*` and the corpus `⊕corpus` notation through the production `__analyze-exact` path; this
file emits what Lean's *own* pretty printer (`PrettyPrinter.ppTerm`, which drives `pushToken`) prints
for the same notations. The harness then asserts the captured atoms predict this emission byte for
byte — two independent code paths, one answer. The corpus notation is declared identically to
`Notation.lean`'s so the two envs agree. -/

notation:65 a " ⊕corpus " b => HAdd.hAdd a b

open Lean Elab Command PrettyPrinter in
run_cmd do
  -- `1 + 2 * 3` exercises both core atoms at their real precedences (`+` around a `*` subterm).
  IO.println (← liftCoreM (ppTerm (← `(1 + 2 * 3)))).pretty
  IO.println (← liftCoreM (ppTerm (← `(1 ⊕corpus 2)))).pretty
