# 10. A Verso heading spells three leaves with no source position

Not a pretty-printer defect — a parser defect. Verso's concrete syntax is not Lean's, so its docstring
parser builds document nodes out of atoms that appear nowhere in the source: a paragraph is
`para{ … }`, a heading is `header( level ) { … }`. Those atoms still get *positions* — zero-width
where they have to be — which is what lets a consumer that walks positions cover a construct spelled
by invented tokens. `fakeAtomHere` (`src/Lean/DocString/Parser.lean:226-227`) is the combinator for
that, and every block parser uses it throughout: `para{`/`}` (`:1162-1164`), `ul{`/`}`
(`:1136-1138`), `dl{`/`}` (`:1154-1156`), and `ol(`/`)`/`{`/`}` (`:1143-1148`).

`header` (`:1167-1184`) is the exception. It positions `header(` from the `#` run it consumed and
closes with `fakeAtomHere "}"`, but spells `)` and `{` with the bare `fakeAtom` (`:1181-1182`),
whose `info` defaults to `SourceInfo.none` (`:215`), and pushes the level as a bare
`Syntax.mkNumLit` (`:1180`), which carries no position either. `ol(`, which has the same four-atom
shape and is fourteen lines above, gets all four right.

## Reproduce

Not a formatting probe — parse a command and print each leaf's position:

```lean
import Lean
open Lean Elab Parser

partial def leaves : Syntax → Array (String × Option Nat × Option Nat)
  | .node _ _ args => args.flatMap leaves
  | .atom info v =>
    #[(v.quote, info.getPos? (canonicalOnly := false) |>.map (·.byteIdx),
        info.getTailPos? (canonicalOnly := false) |>.map (·.byteIdx))]
  | .ident info r .. =>
    #[(toString r, info.getPos? (canonicalOnly := false) |>.map (·.byteIdx),
        info.getTailPos? (canonicalOnly := false) |>.map (·.byteIdx))]
  | .missing => #[]

unsafe def main : IO Unit := do
  initSearchPath (← findSysroot)
  for src in ["set_option doc.verso true in\n/-! Hi -/\n",
              "set_option doc.verso true in\n/-! # Hi -/\n"] do
    IO.println s!"----- {src.quote}"
    let ictx := Parser.mkInputContext src "<probe>"
    let (hdr, pstate, msgs) ← Parser.parseHeader ictx
    let (env, msgs) ← processHeader hdr {} msgs ictx
    let s ← IO.processCommands ictx pstate (Command.mkState env msgs {})
    for t in s.commands do
      for (v, p, q) in leaves t do
        IO.println s!"  {v}  pos={p}  tail={q}"
```

The two documents differ only in the `#`. Leaves of the module docstring alone — the paragraph,
whose every atom is positioned:

| leaf | `/-!` | `para{` | `"Hi "` | `}` | `-/` |
| --- | --- | --- | --- | --- | --- |
| pos–tail | 29–32 | 33–33 | 33–36 | 36–36 | 36–38 |

and the heading, whose middle three are not:

| leaf | `/-!` | `header(` | `0` | `)` | `{` | `"Hi "` | `}` | `-/` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pos–tail | 29–32 | 33–34 | **none** | **none** | **none** | 35–38 | 38–38 | 38–40 |

Note the second consequence, one line down from the first: byte 34 — the space between `#` and the
heading text — belongs to no leaf's trivia either, because `header(` ends at 34 and `"Hi "` begins
its leading run at 35. `ol(`'s spelling would have avoided both.

Two more bare `fakeAtom` calls are the same shape and were **not** probed: `descItem`'s `=>`
(`:1114`) and the directive opener's `"\n"` (`:1252`). Expect description lists and directives to
carry position-less leaves too.

## What it costs lean-fmt

Nothing now, and it cost the whole file before. `LosslessSource`'s tiling clause required every leaf
to carry an original position, so any file with a Verso heading was refused outright — `rejected`,
exit 1, nothing formatted. `MathlibTest/Linter/Header/Verso.lean` was the one file in mathlib4's
8,862 that `lean-fmt` could not format at all. The 2026-08-14 run reports it `would-format` with
zero degradations, and `rejected` 0 across the corpus.

`LeafInfo.absent`, `Token.positioned` and the three walks that consult it
(`LeanFmt/LosslessSource.lean`, `LeanFmt/Suppression.lean`) are what a fix upstream would let us
delete. A leaf that spells no bytes takes no part in a tiling over bytes; that is a true statement
about any parser, so the mechanism is defensible on its own terms and is not merely a workaround.
The part that *is* a workaround is `leadingStart` having to skip absent predecessors to recover
byte 34 — and that repair already existed, for §11.

## Pinned by

The `lossless` suite's `verso-heading` case asserts both halves: the projection covers the byte, and
the independent oracle still reports the leaves positionless. No `Probe.lean` row — nothing here is
formatted.
