import VersoManual

import Manual.Introduction
import Manual.Layout
import Manual.Rules
import Manual.Configuration

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "lean-fmt — Lean 4 Formatter and Linter" =>
%%%
tag := "top"
shortTitle := "lean-fmt"
%%%

*Audience: anyone running lean-fmt.*

lean-fmt is a code formatter and linter for Lean 4. It formats Lean source into one canonical
style and adds static-analysis rules for common source-level problems. With one style there is no
house dialect to agree on and nothing to argue about in review: layout follows from the structure
the compiler parsed and from one number, the line width.

Every Lean example in this manual is compiled as the page is built. An example that stopped being
valid Lean would break the build rather than sit here quietly being wrong.

{include 1 Manual.Introduction}

{include 1 Manual.Layout}

{include 1 Manual.Rules}

{include 1 Manual.Configuration}
