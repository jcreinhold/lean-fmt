module

/- Measurements behind `RLC-SPEC`'s choice of layout model.

Six subcommands, each answering one question the design note has to answer with a number:

    trivia <file>  which token owns a comment, on the toolchain that ships
    complexity     how each candidate's cost grows with document size and with group nesting
    fit            do the two candidates decide the same way, and where do they not
    express        is there a layout this repository needs that candidate B cannot state
    stdfmt         what Lean core's own Wadler algebra already measures and carries
    width          what a column is, once the source is not ASCII
    assemble       what rendered output costs to concatenate in Lean

The two candidates are built by hand in each notation rather than by translating one into the other.
A translator would have to invent an answer wherever the notations disagree, which is the thing
being measured. -/

import all Wadler
import all Oppen
import all TriviaProbe

open LayoutCore

namespace LayoutCore.Probe

private def elapsedMs (start stop : Nat) : String :=
  let us := (stop - start) / 1000
  s!"{us / 1000}.{(us % 1000) / 100}{(us % 100) / 10}{us % 10}"

/-- Time `act`, forcing its result before the clock stops.

`force` must extract a scalar that cannot be produced without doing the work, and it is written into
an `IO.Ref` so the store is an effect sequenced between the two timestamps. Without that, nothing
orders the pure computation with respect to `monoNanosNow`, the compiler is free to sink it past the
second one, and every row reports 0. That is not a hypothetical: it is what this function did first,
and the whole `assemble` measurement below is wall time and nothing else. -/
private def timed (act : Unit → α) (force : α → Nat) : IO (α × Nat) := do
  let sink ← IO.mkRef 0
  let start ← IO.monoNanosNow
  let value := act ()
  sink.set (force value)
  let stop ← IO.monoNanosNow
  let _ ← sink.get
  return (value, stop - start)

/-! ## Shapes

`seq` is `n` sibling groups on one line. `nest` is `n` groups inside one another, which is the
`f (f (f ...))` an adversarial Lean file actually contains. Both are built so that no group fits at
the narrow margin, because a candidate's cost only becomes interesting once it has to decide. -/

private def wSeq (n : Nat) : Wadler.Doc := Id.run do
  let mut doc : Wadler.Doc := .empty
  for _ in [0:n] do
    doc := doc ++ .group (.text "aaaa" ++ .line " " ++ .text "bbbb")
  return doc

private def oSeq (n : Nat) : Array Oppen.Tok := Id.run do
  let mut toks : Array Oppen.Tok := #[]
  for _ in [0:n] do
    toks := toks ++ #[Oppen.Tok.begin 0 .consistent, .text "aaaa", .brk 1 0, .text "bbbb", .«end»]
  return toks

private def wNest : Nat → Wadler.Doc
  | 0 => .text "x"
  | n + 1 => .group (.text "f(" ++ .nest 2 (.line "" ++ wNest n) ++ .line "" ++ .text ")")

/-- The same document as `wNest`, token for token. The closing `.text ")"` is not decorative: without
it this stream renders half the bytes `wNest` does, and any wall-time or output-size comparison
between the two is then measuring two different documents rather than two models. -/
private def oNest (n : Nat) : Array Oppen.Tok := Id.run do
  let mut toks : Array Oppen.Tok := #[]
  for _ in [0:n] do
    toks := toks ++ #[Oppen.Tok.begin 2 .consistent, .text "f(", .brk 0 0]
  toks := toks.push (.text "x")
  for _ in [0:n] do
    toks := toks ++ #[Oppen.Tok.brk 0 (-2), .text ")", .«end»]
  return toks

/-! ## complexity -/

/-- Forcing functions for `timed`. Each touches the rendered string's length, which cannot be known
without having rendered it, and the step count, which cannot be known without having counted. -/
private def forceRender (r : String × Nat) : Nat := r.1.utf8ByteSize + r.2

private def forceOppen (r : String × Nat × Nat × Bool) : Nat :=
  r.1.utf8ByteSize + r.2.1 + r.2.2.1 + (if r.2.2.2 then 1 else 0)

private def complexityRow (label : String) (n : Nat) (steps : Nat) (nanos : Nat)
    (out : String) : IO Unit :=
  IO.println s!"  {label} n={n} steps={steps} ms={elapsedMs 0 nanos} out_bytes={out.utf8ByteSize}"

private def runComplexity : IO UInt32 := do
  let margin := 20
  IO.println "--- complexity: sequential groups, none fitting (margin=20) ---"
  IO.println "textbook: Wadler's best/fits transliterated into a strict language"
  for n in [1, 5, 10, 14, 16, 18, 20] do
    let ((out, steps), nanos) ← timed (fun _ => Wadler.renderTextbook margin (wSeq n)) forceRender
    complexityRow "textbook" n steps nanos out
  IO.println "bounded: same algebra, work-list renderer, fit test stops at the margin"
  for n in [1, 10, 100, 1000, 10000, 100000] do
    let ((out, steps), nanos) ← timed (fun _ => Wadler.renderBounded margin (wSeq n)) forceRender
    complexityRow "bounded" n steps nanos out
  IO.println "oppen: token stream, scan/print"
  for n in [1, 10, 100, 1000, 10000, 100000] do
    let ((out, steps, peak, unbalanced), nanos) ← timed (fun _ => Oppen.render margin (oSeq n)) forceOppen
    IO.println s!"  oppen n={n} steps={steps} ms={elapsedMs 0 nanos} \
out_bytes={out.utf8ByteSize} peak_buffer={peak} unbalanced={unbalanced}"

  IO.println "\n--- complexity: nested groups, none fitting (margin=20) ---"
  for n in [1, 5, 10, 14, 16, 18, 20] do
    let ((out, steps), nanos) ← timed (fun _ => Wadler.renderTextbook margin (wNest n)) forceRender
    complexityRow "textbook" n steps nanos out
  for n in [1, 10, 100, 1000, 10000] do
    let ((out, steps), nanos) ← timed (fun _ => Wadler.renderBounded margin (wNest n)) forceRender
    complexityRow "bounded" n steps nanos out
  for n in [1, 10, 100, 1000, 10000] do
    let ((out, steps, peak, unbalanced), nanos) ← timed (fun _ => Oppen.render margin (oNest n)) forceOppen
    IO.println s!"  oppen n={n} steps={steps} ms={elapsedMs 0 nanos} \
out_bytes={out.utf8ByteSize} peak_buffer={peak} unbalanced={unbalanced}"
  return 0

/-! ## fit

Both candidates decide whether a group is flat by comparing a width against the space left on the
line. They do not measure the same width. Wadler's `fits` walks past the end of the group, through
whatever follows it, until the next break — so a group is broken when the *line* it would produce is
too long. Oppen's `Begin` carries the size of the group alone.

That difference is invisible until something follows a group on its line, which in a Lean file is
almost always. -/

/-- Longest rendered line, in codepoints. The number a margin is a promise about. -/
private def maxLine (s : String) : Nat :=
  (s.splitOn "\n").foldl (fun m l => max m l.length) 0

/-- `group(f(arg))` followed by a tail. The group is 6 columns wide whatever the tail does, so a
model that measures only the group decides the same way at every margin above 6; a model that
measures the line changes its mind when the tail no longer fits. -/
private def wTail : Wadler.Doc :=
  .group (.text "f(" ++ .nest 2 (.line "" ++ .text "arg") ++ .line "" ++ .text ")")
    ++ .text " => tail"

private def oTail : Array Oppen.Tok := #[
  .begin 2 .consistent, .text "f(", .brk 0 0, .text "arg", .brk 0 (-2), .text ")", .«end»,
  .text " => tail"]

private def runFit : IO UInt32 := do
  IO.println "--- fit: what width is compared against the margin ---"
  IO.println "doc: group(f(arg)) ++ text \" => tail\"; flat form is 14 columns, group alone is 6"
  let mut differed := 0
  for margin in [30, 20, 15, 14, 13, 12, 10, 8, 6, 5] do
    let (wOut, _) := Wadler.renderBounded margin wTail
    let (oOut, _, _, _) := Oppen.render margin oTail
    let agree := wOut == oOut
    unless agree do differed := differed + 1
    IO.println s!"  margin={margin} agree={agree} \
wadler={repr wOut} oppen={repr oOut}"
    IO.println s!"    wadler_max_line={maxLine wOut} oppen_max_line={maxLine oOut} \
wadler_over={decide (maxLine wOut > margin)} oppen_over={decide (maxLine oOut > margin)}"
  IO.println s!"  margins_where_models_disagree={differed}"
  return 0

/-! ## express

The `do` block is the case. Flat it is `do a; b`; broken it is `do`, then each statement on its own
line with no separator. The separator is *text that depends on the mode*, and `by`/`<;>` tactic
blocks and `Prop`-level `∧` chains all have the same shape.

Candidate B's `Break` emits blanks. It has no way to say "a semicolon here, but only when flat", so
the semicolon has to be attached to a `Text` token, where it survives into the broken form. -/

/-- The same document in `Std.Format`, which is Lean core's own Wadler/Leijen algebra and therefore
the first thing to reach for instead of writing one. `Format.line` flattens to `" "` and to nothing
else, so the semicolon has to be attached to a `Text` exactly as in candidate B. -/
private def sDo : Std.Format :=
  "do" ++ Std.Format.nest 2 (Std.Format.group (Std.Format.line ++ "act1;" ++ Std.Format.line ++ "act2"))

private def runExpress : IO UInt32 := do
  let wDoc : Wadler.Doc :=
    .text "do" ++ .nest 2 (.group (.line " " ++ .text "act1" ++ .line "; " ++ .text "act2"))
  -- The best candidate B can do: the separator becomes part of the preceding token.
  let oToks : Array Oppen.Tok := #[
    .text "do", .begin 2 .consistent, .brk 1 0, .text "act1;", .brk 1 0, .text "act2", .«end»]
  IO.println "--- express: a mode-dependent separator (`do a; b` vs a broken do block) ---"
  IO.println "wanted: flat `do act1; act2`; broken `do` then one statement per line, no separator"
  for margin in [40, 12] do
    let (wOut, _) := Wadler.renderBounded margin wDoc
    let (oOut, _, _, _) := Oppen.render margin oToks
    IO.println s!"  margin={margin}"
    IO.println s!"    wadler_bounded={repr wOut}"
    IO.println s!"    oppen={repr oOut}"
    IO.println s!"    std_format={repr (sDo.pretty margin)}"
  return 0

/-! ## stdfmt

`Std.Format` is Lean core's own Wadler/Leijen algebra (`Init/Data/Format/Basic.lean`), and its
renderer `be` is already a bounded work list that measures a group together with the remainder of
the line (`pushGroup`, line 244). Core reached the same two conclusions this experiment reaches, for
the same reason: Lean is strict.

So the question is not whether the algebra is right. It is whether `Format`'s *constructor set* can
carry what a formatter needs, given that the type is a closed inductive in core and cannot be
extended from here. Two things are measured: what a column is, and what `tag` can carry. -/

private def runStdFmt : IO UInt32 := do
  IO.println "--- stdfmt: what Lean core's own algebra measures and carries ---"
  -- `spaceUptoLine`/`pushOutput` both count `String.Internal.length`, i.e. codepoints. A CJK string
  -- of 6 codepoints occupies 12 terminal cells; if core counted cells, this would break.
  let cjk : Std.Format := Std.Format.group ("世界世界世界" ++ Std.Format.line ++ "x")
  IO.println s!"  cjk_at_width_8={repr (cjk.pretty 8)}"
  IO.println s!"  cjk_at_width_7={repr (cjk.pretty 7)}"
  IO.println "  (flat at 8 means core counts 6 codepoints, not 12 terminal cells)"
  IO.println s!"  default_width={Std.Format.defWidth}"
  return 0

/-! ## width -/

private def widthRow (label s : String) : IO Unit :=
  IO.println s!"  {label} bytes={s.utf8ByteSize} codepoints={s.length} text={repr s}"

private def runWidth : IO UInt32 := do
  IO.println "--- width: what one column costs, by candidate policy ---"
  widthRow "ascii    " "abcd"
  widthRow "arrow    " "→"
  widthRow "greek    " "α"
  widthRow "subscript" "x₁"
  widthRow "cjk      " "世界"
  -- Built from codepoints, not written as a literal: an editor saving this file would normalize a
  -- decomposed literal to the precomposed form and the row would silently test nothing.
  widthRow "combining" (String.ofList ['e', Char.ofNat 0x301])
  widthRow "precomposed" (String.ofList [Char.ofNat 0xe9])
  widthRow "emoji    " "🎉"
  return 0

/-! ## assemble

Every renderer here accumulates fragments into an `Array String` and joins once. The alternative a
renderer reaches for first is `out := out ++ s` in a loop. Whether that is linear or quadratic in
Lean is not a matter of taste: it depends on whether the runtime can see the accumulator is unshared
and mutate it in place. -/

private def appendLoop (n : Nat) : String := Id.run do
  let mut out := ""
  for _ in [0:n] do
    out := out ++ "0123456789"
  return out

private def joinLoop (n : Nat) : String := Id.run do
  let mut out : Array String := #[]
  for _ in [0:n] do
    out := out.push "0123456789"
  return String.join out.toList

private def runAssemble : IO UInt32 := do
  IO.println "--- assemble: cost of building rendered output (fragments of 10 bytes) ---"
  for n in [1000, 10000, 100000, 200000] do
    let (a, aNanos) ← timed (fun _ => appendLoop n) String.utf8ByteSize
    let (b, bNanos) ← timed (fun _ => joinLoop n) String.utf8ByteSize
    IO.println s!"  n={n} append_ms={elapsedMs 0 aNanos} join_ms={elapsedMs 0 bNanos} \
bytes={a.utf8ByteSize} same={a == b}"
  return 0

end LayoutCore.Probe

public unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | ["trivia", path] => LayoutCore.TriviaProbe.run path
  | ["complexity"] => LayoutCore.Probe.runComplexity
  | ["fit"] => LayoutCore.Probe.runFit
  | ["express"] => LayoutCore.Probe.runExpress
  | ["stdfmt"] => LayoutCore.Probe.runStdFmt
  | ["width"] => LayoutCore.Probe.runWidth
  | ["assemble"] => LayoutCore.Probe.runAssemble
  | _ =>
    IO.eprintln "usage: layout-probe \
(trivia <file> | complexity | fit | express | stdfmt | width | assemble)"
    return 2
