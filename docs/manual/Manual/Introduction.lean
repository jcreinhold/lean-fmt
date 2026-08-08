import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Introduction" =>
%%%
tag := "introduction"
%%%

Replace this with the first chapter. A code example is checked as the document builds, so a snippet
that stops compiling breaks the build rather than quietly becoming wrong:

```lean (name := twiceEval)
def twice (n : Nat) : Nat := n + n

#eval twice 21
```

The expected output is checked too. Naming the block above lets this one quote what it printed, so
the two cannot drift apart:

```leanOutput twiceEval
42
```
