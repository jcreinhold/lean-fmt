# 12. What is still unexplained

Residue, not a defect: the degradations no filed cause explains. Nothing here reproduces on demand,
nothing expires, and the `upstream-defects` suite has no probes for it.

Classifying every `uncaught backtrack exception` degradation by the text around the degraded
command, one classifier run over both corpus runs:

| cause | before | after |
| --- | --- | --- |
| doubly-declared notation (#14611, PR #14696) | 122 | 104 |
| dynamic quotation (§2) | 35 | 26 |
| `%$` positional capture (§3) | 40 | 7 |
| *(commands carrying two causes, subtracted once)* | −29 | −14 |
| **unexplained** | **71** | **26** |
| total | 239 | 149 |

The classifier is a text heuristic over a 12-line window from each degradation's line: a token
declared by more than one `notation`/`infix*`/`prefix`/`postfix` command anywhere in the corpus, a
`` `(cat| `` for a category other than `term`/`tactic`, or a `%$`. It can only undercount the first
(the token still has to land in binder position) and can overcount any of them (the construct has to
be in the *failing* command, not merely nearby). Treat these as orders of magnitude, not tallies.

**The notation row is not comparable to the figure of 88 this record carried earlier on
2026-08-13.** That count came from a classifier whose notation test could not be reconstructed
afterwards; the two rows that could be reproduced exactly — 40 and 35 in the before column — are the
check that the rest of the classifier is the same one. Rather than mix two classifiers in one table,
both columns above are the looser test, which over-tags notation and so under-reports the residue.
The honest reading of the "unexplained" row is that it is at least 26 and was at least 71.

Files carrying the unexplained residue after the repairs:
`Mathlib/Tactic/CategoryTheory/Slice.lean` (3), `Mathlib/Tactic/{ClickSuggestions/Util,
Widget/Conv}.lean` and `MathlibTest/Tactic/GRewrite.lean` (2 each), then a tail of singletons.

`Mathlib/Tactic/Have.lean` was the useful one to start on, because the standalone scanner formatted
all 15 of its commands without complaint while `lean-fmt` degraded 3 — so whatever failed there was
on our side of the boundary. It was: §5. Establishing which side owns a failure is still the first
thing to do for any of the residue, and the scanner is still how to do it (see
[the index](README.md#how-these-are-pinned)).
