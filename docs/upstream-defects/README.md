# Upstream defects nothing has been filed for

Addressed to whoever files or fixes them, not to a consumer of `lean-fmt`. Each numbered file is one toolchain defect
with a toolchain-only reproduction — no Mathlib, no `lean-fmt` — written so it can be pasted into a `leanprover/lean4`
issue as-is.

Measured 2026-08-13 and 2026-08-14 against `lean-toolchain` `leanprover/lean4:v4.34.0-rc1`, with corpus figures from
mathlib4 at `4a9d59a1cc`. Upstream line numbers are from a checkout based on `16fafca7f`; re-read before quoting them,
they move. A measurement here has a date, not authority — regenerate rather than argue.

The corpus figures come from two whole-project runs on 2026-08-13, both cold-cache
(`format --check --no-cache --root .`), before and after §3's and §5's repairs: `verbatim_commands` 421 → 334 and
`uncaught backtrack exception` 239 → 149, with `rejected` 1, `broken` 0 and `infrastructure_failures` 0 in both. Where a
file says "of the 421", it is quoting the first run.

A third run of the same command on 2026-08-14, over the same corpus commit, on the released 0.7.1 binary, carries §10's
repair: `files` 8862, `changed` 8533, `rejected` **0**, `verbatim_commands` 334, `findings` 3707, with `broken`,
`unbuilt`, `validation_bypassed` and `infrastructure_failures` all 0. Per-file statuses are `clean` (329) and
`would-format` (8533) and nothing else. It is what turns §10's "nothing now" from one file checked into a corpus with no
refusal left in it, and the refusal was removed rather than relocated: `verbatim_commands` held at 334, and the two
counts that would have absorbed a moved defect stayed at zero.

That run's 334 degradations divide by the gate that refused them: 181 the layout, 71 formatting the result a second
time, 49 the compiler's messages, 14 the comments, 13 the code's structure, 6 the tokens. This is a different cut from
§12's table, which counts only the `uncaught backtrack exception` subset and totals 149; how the two decompositions line
up was not established, and guessing a correspondence from the totals would be inventing one.

## The defects

§§1–5 are refusals: the formatter throws, and what they cost is counted above. §§6–11 are defects `lean-fmt` already
compensates for, each at the price of a mechanism that could be deleted if the defect were fixed upstream — they are
here because a mechanism nobody can name the reason for is a mechanism nobody dares remove. §12 is the residue neither
group explains.

| file | defect | what it does |
| --- | --- | --- |
| [01](01-interpolatedstr-walks-any-node.md) | `interpolatedStr.formatter` walks whatever node it is handed | **silently deletes the argument** of `throwError`, `trace[…]`, `println!` and five more core parsers |
| [02](02-parserofstack-off-by-one.md) | `parserOfStack.formatter` reads one slot short | every dynamic quotation `` `(conv\| …) `` etc. is unformattable |
| [03](03-positional-capture.md) | a `%$` positional capture makes any quotation unformattable | backtrack in quotations, silent deletion outside them |
| [04](04-forgotten-separators.md) | two forgotten separators in `src/Lean/Parser/Syntax.lean` | glued tokens in rendered `syntax` commands |
| [05](05-sepbyindent-drops-splice.md) | `sepByIndent.formatter` drops the antiquotation splice its own parser adds | `` `(tactic\| ($[…];*)) `` throws |
| [06](06-ctor-docstring-newline.md) | `ctor` puts the newline after the docstring it should precede | constructor docstrings glued to `where` |
| [07](07-guardmsgs-missing-dedent.md) | `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has | the command under `#guard_msgs in` is indented one level |
| [08](08-category-nest-accumulates.md) | the category formatter's `nest` accumulates once per link of an operator chain | `pretty 100` returns rows wider than 100 |
| [09](09-rooted-node-kind.md) | four toolchain parsers declare a node kind that names no constant | `formatCommand` dies on `register_label_attr` and friends |
| [10](10-verso-heading-positions.md) | a Verso heading spells three leaves with no source position | any consumer tiling by positions breaks on Verso docstrings |
| [11](11-hygieneinfo-stranded-trivia.md) | `hygieneInfo` strands the whitespace it steals when its node is discarded | the syntax tree stops covering the file's bytes |
| [12](12-residue.md) | what is still unexplained | 26+ backtrack degradations no filed cause explains |

§§10 and 11 are the two that are not pretty-printer defects. Both are in the parser, both are about leaves whose source
positions are wrong or absent rather than about anything being formatted, and both carry their own reproduction rather
than using the harness below.

Two open items *are* filed and are deliberately absent from this directory:
[#14611](https://github.com/leanprover/lean4/issues/14611) with its PR
[#14696](https://github.com/leanprover/lean4/pull/14696) (doubly-declared notation in binder position), and
[#14692](https://github.com/leanprover/lean4/issues/14692) / [#14715](https://github.com/leanprover/lean4/issues/14715)
with PR [#14693](https://github.com/leanprover/lean4/pull/14693) (the `align` measure, which is what
`LAY-ALIGN-COMPENSATION` in `LeanFmt/Formatter/NativeLayout.lean` compensates for). Every defect here was re-run against
#14696's branch build and is unchanged by it.

## How these are pinned

Every §1–§9 row is written down, preambles included, in `tests/fixtures/upstream-defects/Probe.lean`:

```sh
lake env lean tests/fixtures/upstream-defects/Probe.lean
```

(Run anything here with `lake env lean <file>`, never bare `lean` — bare `lean` reports an incompatible header.)

The `upstream-defects` suite (`tests/Suites/UpstreamDefects.lean`) runs the probe and asserts that each defect **still
reproduces**, because nothing else here does: every other suite asserts lean-fmt behaves correctly, which stays true
whether or not the defect underneath is still there. A defect that stops reproducing fails that suite with the mechanism
it lets us delete named in the message. §§10–11 are covered the same way by the `lossless` suite's `stranded-trivia` and
`verso-heading` cases, which assert both halves already; §12 is residue and has nothing to expire.

Each defect file links its pin. Prefer the fixture to the files' reproduction tables when the two disagree, and fix the
table — two of them had rotted by the time the fixture was written, and both corrections are noted in place.

To sweep a real file instead of a string, parse it command by command with `Parser.parseHeader` and
`Parser.parseCommand` and call `formatCommand` on each; that scanner is how the families here were found. Note that its
failures are neither a subset nor a superset of `lean-fmt`'s degradations: `lean-fmt` builds its own document rather
than calling `formatCommand`, so it survives some commands the scanner refuses (dynamic quotations, which it protects as
exact islands) and refuses some the scanner survives.
