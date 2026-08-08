import VersoManual

import Manual.Introduction
import Manual.Layout
import Manual.Rules
import Manual.Configuration

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "The lean-fmt manual" =>
%%%
tag := "top"
shortTitle := "lean-fmt"
%%%

*Audience: anyone running lean-fmt.*

lean-fmt formats and lints Lean 4 source. It has one style, so there is no house dialect to agree
on and nothing to argue about in review: layout follows from the structure the compiler parsed and
from one number, the line width.

Every Lean example in this manual is compiled as the page is built. An example that stopped being
valid Lean would break the build rather than sit here quietly being wrong.

{include 1 Manual.Introduction}

{include 1 Manual.Layout}

{include 1 Manual.Rules}

{include 1 Manual.Configuration}
