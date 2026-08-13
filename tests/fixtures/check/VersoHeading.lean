module

/- A file whose Verso heading spells leaves the parser gives no position at all.

Under `doc.verso`, a module docstring parses to a document tree built from atoms that appear nowhere
in the source. Most of them carry a real position anyway, zero-width where they have to be, which is
what lets the projection tile a construct spelled by invented tokens: `Doc.Syntax.para` opens with
`para{` at the paragraph's own start. `Doc.Syntax.header` carries positions for `header(` -- the
`#` -- and its closing `}`, and none for the level literal, the `)` or the `{`, there being no
source token for a heading's level.

Requiring every leaf to be positioned refused the whole file. That made
`MathlibTest/Linter/Header/Verso.lean` the one file in mathlib4 lean-fmt could not format at all.

Keep the `#` heading, the double space in the body, and the blank line. The heading is the defect;
the other two are what proves the docstring reconstructs from its own bytes rather than from the
document tree, which does not hold them.

This prose is a block comment rather than a module docstring on purpose: Lean refuses a Verso module
doc in a file that already carries a Markdown one. -/

set_option doc.verso true in
/-!
# A heading

Body  text.
-/

def versoValue : Nat := 1
