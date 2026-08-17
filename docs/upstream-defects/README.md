# Upstream defects nothing has been filed for

Eleven Lean toolchain defects, one file each, with a reproduction that needs only the toolchain —
no Mathlib, no `lean-fmt` — so each can be pasted into a `leanprover/lean4` issue as-is. §§1–9 are
pretty-printer defects (`formatCommand` throws or emits wrong bytes); §§10–11 are parser defects
(leaves with wrong or missing source positions); [§12](12-residue.md) is the measurement residue
neither group explains.

| file | defect | what it does | why it's a bug |
| --- | --- | --- | --- |
| [01](01-interpolatedstr-walks-any-node.md) | `interpolatedStr.formatter` walks whatever node it is handed | **silently deletes the argument** of `throwError`, `trace[…]`, `println!` and five more core parsers | deletes code |
| [02](02-parserofstack-off-by-one.md) | `parserOfStack.formatter` reads one slot short | every dynamic quotation `` `(conv\| …) `` etc. is unformattable | `term`/`tactic` format fine; core can't format its own `Init/Conv.lean` |
| [03](03-positional-capture.md) | a `%$` positional capture makes any quotation unformattable | backtrack in quotations, silent deletion outside them | deletes code |
| [04](04-forgotten-separators.md) | two forgotten separators in `src/Lean/Parser/Syntax.lean` | glued tokens in rendered `syntax` commands | sibling lists spell the space correctly |
| [05](05-sepbyindent-drops-splice.md) | `sepByIndent.formatter` drops the antiquotation splice its own parser adds | `` `(tactic\| ($[…];*)) `` throws | the derived formatter for the same base works |
| [06](06-ctor-docstring-newline.md) | `ctor` puts the newline after the docstring it should precede | constructor docstrings glued to `where` | layout only — the weakest here; `structure` fields beside it lay out correctly |
| [07](07-guardmsgs-missing-dedent.md) | `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has | the command under `#guard_msgs in` is indented one level | `set_option … in` has the `ppDedent` |
| [08](08-category-nest-accumulates.md) | the category formatter's `nest` accumulates once per link of an operator chain | `pretty 100` returns rows wider than 100 | violates the width bound the caller passed |
| [09](09-rooted-node-kind.md) | four toolchain parsers declare a node kind that names no constant | `formatCommand` dies on `register_label_attr` and friends | the constant and the node kind of one declaration disagree about `_root_` |
| [10](10-verso-heading-positions.md) | a Verso heading spells three leaves with no source position | any consumer tiling by positions breaks on Verso docstrings | the tree stops covering the source; the sibling `ol(` positions all four atoms |
| [11](11-hygieneinfo-stranded-trivia.md) | `hygieneInfo` strands the whitespace it steals when its node is discarded | the syntax tree stops covering the file's bytes | the tree stops covering the source |
| [12](12-residue.md) | what is still unexplained | 26+ backtrack degradations no filed cause explains | residue — no reproduction, no claim |

Two defects of the same vintage *are* filed and deliberately absent:
[#14611](https://github.com/leanprover/lean4/issues/14611) (doubly-declared notation in binder
position) and [#14692](https://github.com/leanprover/lean4/issues/14692) /
[#14715](https://github.com/leanprover/lean4/issues/14715) (the `align` measure).

## Running the reproductions

Everything here runs with `lake env lean <file>` — never bare `lean`, which reports an
incompatible header. The §§1–9 rows are collected, preambles included, in one executable file:

```sh
lake env lean tests/fixtures/upstream-defects/Probe.lean
```

Each defect file names its pin under "Pinned by". Prefer the fixture to a file's reproduction
table when the two disagree, and fix the table.

## Why this directory exists

lean-fmt compensates for most of these, each at the price of a mechanism that could be deleted if
the defect were fixed upstream. They are written down because a mechanism nobody can name the
reason for is a mechanism nobody dares remove.

The `upstream-defects` suite (`tests/Suites/UpstreamDefects.lean`) runs the probe and asserts each
defect **still reproduces** — every other suite asserts lean-fmt behaves correctly, which stays
true whether or not the defect underneath is still there. A defect that stops reproducing fails
that suite with the mechanism it lets us delete named in the message. §§10–11 expire the same way
through the `lossless` suite.

Measured 2026-08-13/14 against `leanprover/lean4:v4.34.0-rc1`, corpus figures from mathlib4 at
`4a9d59a1cc`. A measurement has a date, not authority — regenerate rather than argue.
