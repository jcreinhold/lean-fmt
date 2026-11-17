module

/- A Verso heading with a blank line and doubled spaces in its body.

Before Lean 4.36, the heading's unpositioned leaves caused the parser to strand the
space after `#`. The lossless oracle now requires the parser's positions to tile this
fixture, including that space.

This prose is a block comment rather than a module docstring on purpose: Lean refuses a Verso module
doc in a file that already carries a Markdown one. -/

set_option doc.verso true in
/-!
# A heading

Body  text.
-/

def versoValue : Nat := 1
