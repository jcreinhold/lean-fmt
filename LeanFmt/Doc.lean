module

/- The layout algebra.

`RLC-SPEC` chose this model by building both candidates and measuring them; the reasoning, the
numbers, and the rejected alternatives are in `docs/projects/ruff-02-layout-core/notes/01-layout-design.md`
and reproducible with `experiments/layout-core/run.sh`. This module implements the contract that note
froze. The comments here say what the code cannot; they do not re-argue the choice.

Two facts from that note are load-bearing here and are not obvious:

* **The renderer is part of the contract, not an implementation detail.** Wadler's `best`/`fits` is
  linear only because Haskell is lazy: `better` compares two *unevaluated* renderings and forces only
  the prefix that fits. Lean is strict, so a transliteration builds both alternatives in full and is
  **Θ(φⁿ)** in sibling groups — measured, 161006 steps to emit 180 bytes at n=20. `render` below is a
  bounded work list, which is exactly `18n-1` steps on the same document. Lean core's `Std.Format.be`
  is a work list for the same reason.
* **`Std.Format` is not reusable here.** It is core's own Wadler algebra, but `Format` is a closed
  inductive and its `line` flattens to `" "` and nothing else. A `do` block needs a separator that is
  `"; "` flat and *nothing* broken; core and Oppen both strand the semicolon (measured). `line` below
  carries its flat text, which is the one generalization the whole choice turned on.

Units differ on purpose and the difference is not a bug: **columns are codepoints, ranges are bytes.**
Columns are compared against the margin, and codepoints are what `Std.Format` counts
(`Init/Data/Format/Basic.lean:401`), so this formatter agrees with every other Lean tool about where
column 100 is. Ranges address source text, and `LosslessSource` is byte-indexed throughout. Neither
unit is right for the other job. -/

import all LeanFmt.LosslessSource

namespace LeanFmt.Internal

/-- The document algebra.

A caller names structure — "these things are a group", "indent this", "a break may go here" — and
never a column, a mode, or the rest of the line. Everything else in this module is private to that
promise.

There is deliberately **no alternative constructor**: no Wadler `Union`, no Prettier
`conditionalGroup`, no `ruff_formatter` `best_fitting`. The only choice in the algebra is flat versus
broken, decided by one bounded fit test. The roadmap forbids unbounded alternative retention; with no
alternative to retain that is unrepresentable rather than a discipline someone must keep. Adding such
a constructor later would reopen `RLC-SPEC`, not merely extend this type. -/
inductive Doc where
  /-- Renders as nothing. -/
  | empty
  /-- Literal text on one line. Must not contain `'\n'` — `Doc.wellFormed` checks it, and `hard` or
  `verbatim` is how a newline is stated. Splitting the two is a deliberate departure from
  `Std.Format`, where a `'\n'` inside `text` is a hard break (`Basic.lean:269`): here "this string is
  one line" is checkable rather than conventional. -/
  | text (s : String)
  /-- A break opportunity carrying the text it becomes when its group is flat.
  `line " "` is Wadler's `line`, `line ""` is Leijen's `softline`, and `line "; "` is a `do` block's
  separator. Broken, it emits a newline and the current indentation — the flat text is dropped. -/
  | line (flat : String)
  /-- An unconditional newline plus the current indentation. A group containing one can never be
  flat. A line comment must be followed by one: `--` swallows the rest of its line, so a comment a
  group flattened onto one line would eat the code after it. -/
  | hard
  /-- Literal text that may span lines, emitted exactly as given.

  Its interior is **never re-indented**, which is the entire reason it exists and the one thing
  `text`+`hard` cannot express: `hard` applies the current indentation to the next line, and a block
  comment or a multi-line string literal that gets re-indented has had its *content* rewritten.
  `Std.Format` re-indents such text (`Basic.lean:269-276`); for a comment body that is a defect, not
  a feature. A multi-line `verbatim` can never be flat. Discovered by `RLC-IMPL`; see
  `results/02-engine.md`. -/
  | verbatim (s : String)
  /-- Concatenation. -/
  | cat (a b : Doc)
  /-- Indent `d` by `n` more columns. Relative and additive; consumed only by a broken `line` or a
  `hard`. There is no align-to-current-column, which is column arithmetic and outside the caller's
  vocabulary by design. -/
  | nest (n : Nat) (d : Doc)
  /-- Render `d` flat if it fits, else broken. Nested groups decide independently: an outer group
  breaking does not break an inner one. -/
  | group (d : Doc)
  /-- Record that `d` was rendered from `range` in the source. Carries no width and renders exactly
  as `d`; its only effect is a `Mark` in the source map. -/
  | mark (range : SourceRange) (d : Doc)
  deriving Inhabited

instance : Append Doc where
  append := .cat

namespace Doc

/-- Column width of a fragment, in codepoints. See the module comment on units.

This is the policy `Std.Format` uses, and it is a compromise recorded rather than hidden: it is right
for the notation Lean is written in (`→`, `α`, `x₁` measure 1, 1, 2) and wrong for CJK and emoji,
which display twice as wide as they measure. It is also not normalization-stable — `é` measures 1
column precomposed and 2 decomposed. UAX#11 East Asian Width would need a table core does not have
and would put this formatter's column count at odds with every other Lean tool. -/
def width (s : String) : Nat := s.length

/-- Text after the last newline, which is where the column stands once `verbatim` has been emitted. -/
private def lastLine (s : String) : String :=
  match (s.splitOn "\n").getLast? with
  | some l => l
  | none => s

private def spansLines (s : String) : Bool := s.contains '\n'

/-- Does every `text` hold exactly one line?

The renderer tracks columns by adding `width s` for each `text`, which is only the true column if `s`
has no newline in it. A document that fails this check renders text the caller wrote, but every
column decision after the offending `text` is measured against the wrong number. `verbatim` is the
supported way to emit a newline inside literal text. -/
def wellFormed : Doc → Bool
  | .text s => !spansLines s
  | .empty | .line _ | .hard | .verbatim _ => true
  | .cat a b => wellFormed a && wellFormed b
  | .nest _ d | .group d | .mark _ d => wellFormed d

/-- Number of constructors. Used by tests to talk about document size. -/
def size : Doc → Nat
  | .empty | .text _ | .line _ | .hard | .verbatim _ => 1
  | .cat a b => 1 + size a + size b
  | .nest _ d | .group d | .mark _ d => 1 + size d

end Doc

/-- One entry of the source map: the input range a fragment came from, and the output range it landed
in. `output` is a byte range into the rendered string; `source` is a byte range into the normalized
source, the same coordinate system `LosslessSource` uses.

Range formatting needs this, and so does any caller that must map a finding back to what it edited. -/
structure Mark where
  source : SourceRange
  output : SourceRange
  deriving Inhabited, BEq, Repr

private inductive Mode where
  | flat
  | brk
  deriving BEq, Inhabited

/- One unit of pending work. `closeMark` is how a `mark` learns where its rendering ended: the
renderer pushes the subdocument and a `closeMark` carrying the output offset at which it started, and
records the `Mark` when the sentinel surfaces. It carries no width, so `fits` steps over it. -/
private inductive Cmd where
  | doc (indent : Nat) (mode : Mode) (d : Doc)
  | closeMark (source : SourceRange) (outStart : Nat)

private def newlineIndent (indent : Nat) : String :=
  "\n".pushn ' ' indent

/-- Does the undecided document still fit on this line?

`remaining` is columns left. The walk stops at the first break-mode `line`, because everything after
it is on another line and cannot affect this one — that bound is what makes the renderer linear
rather than Wadler's Θ(φⁿ), and it is why no alternative rendering is ever built.

`z`, the work list *after* the group, is deliberately included by the caller. A group that fits on its
own may still not fit once what follows it before the next break is counted, so a margin is a promise
about lines, not about groups. `Std.Format.pushGroup` carries the remainder for the same reason.

**Known hole, owned by `RLC-FINAL`.** This is bounded in columns of *text*, not in nodes between
columns: `empty`, `nest`, `group`, `mark`, and `closeMark` consume no width, so a document that nests
them deeply between text could walk arbitrarily far — O(n·w), and O(n²) in the limit. Every shape
measured in `RLC-SPEC` is linear, and any printer emitting text at bounded node-distance stays linear.
It is not demonstrated for an adversarial zero-width document. -/
private partial def fits (remaining : Int) : List Cmd → Bool
  | [] => remaining >= 0
  | cmd :: z =>
    if remaining < 0 then false
    else match cmd with
      | .closeMark .. => fits remaining z
      | .doc i m d => match d with
        | .empty => fits remaining z
        | .text s => fits (remaining - Doc.width s) z
        | .verbatim s =>
          -- Multi-line text cannot sit on this line at all, exactly like `hard`.
          if Doc.spansLines s then (match m with | .flat => false | .brk => remaining >= 0)
          else fits (remaining - Doc.width s) z
        | .cat a b => fits remaining (.doc i m a :: .doc i m b :: z)
        | .nest j d => fits remaining (.doc (i + j) m d :: z)
        | .mark _ d => fits remaining (.doc i m d :: z)
        | .group d => fits remaining (.doc i .flat d :: z)
        | .line flat => match m with
          | .flat => fits (remaining - Doc.width flat) z
          | .brk => remaining >= 0
        | .hard => match m with
          -- The comment case: a `hard` forces its enclosing group open rather than swallowing code.
          | .flat => false
          | .brk => remaining >= 0

/- The renderer proper.

`out` is threaded rather than accumulated into an `Array` and joined. That is the measured choice, not
the intuitive one: Lean's runtime mutates a string in place when its reference is unique, so `out ++ s`
here is linear and beats `Array` + `String.join` by ~3x (200000 fragments: 1.148 ms against 3.373 ms).
The roadmap's "repeated string concatenation" stop rule is about accumulators that are *shared*, which
this one is not — it is dead the moment it is passed on. `tests/layout/run.sh` measures the growth so
the claim cannot rot silently. -/
private partial def go (w : Nat) : List Cmd → Nat → Nat → String → Array Mark → String × Array Mark
  | [], _, _, out, marks => (out, marks)
  | .closeMark source outStart :: z, col, outBytes, out, marks =>
    go w z col outBytes out (marks.push { source, output := ⟨outStart, outBytes⟩ })
  | .doc i m d :: z, col, outBytes, out, marks => match d with
    | .empty => go w z col outBytes out marks
    | .text s => go w z (col + Doc.width s) (outBytes + s.utf8ByteSize) (out ++ s) marks
    | .verbatim s =>
      let col := if Doc.spansLines s then Doc.width (Doc.lastLine s) else col + Doc.width s
      go w z col (outBytes + s.utf8ByteSize) (out ++ s) marks
    | .cat a b => go w (.doc i m a :: .doc i m b :: z) col outBytes out marks
    | .nest j d => go w (.doc (i + j) m d :: z) col outBytes out marks
    | .mark r d => go w (.doc i m d :: .closeMark r outBytes :: z) col outBytes out marks
    | .hard =>
      let s := newlineIndent i
      go w z i (outBytes + s.utf8ByteSize) (out ++ s) marks
    | .line flat => match m with
      | .flat => go w z (col + Doc.width flat) (outBytes + flat.utf8ByteSize) (out ++ flat) marks
      | .brk =>
        let s := newlineIndent i
        go w z i (outBytes + s.utf8ByteSize) (out ++ s) marks
    | .group d =>
      let mode := if fits (Int.ofNat w - Int.ofNat col) (.doc i .flat d :: z) then Mode.flat else Mode.brk
      go w (.doc i mode d :: z) col outBytes out marks

/-- Render `d` at margin `w`, returning the text and the source map.

**Total.** There is no `Except`, because layout cannot fail: no backtracking, no alternatives, no
unsatisfiable constraint. That is a property of the constructor set, not a claim about this function.

**A margin is not a guarantee.** The renderer never breaks a `text` and never invents a break
opportunity, so a document whose atoms exceed `w` produces lines wider than `w` — measured: `) => tail`
is atomic, and at margins 8, 6, and 5 it still renders 9 columns. Indentation is likewise unclamped:
`nest` depth d at unit u indents d·u whatever `w` is. Both are inherent to the model rather than
defects in it, and clamping is a language decision `RLC-FINAL` owns.

Marks are recorded when their subdocument completes, so an inner `mark` precedes the outer `mark` that
contains it; the array is in completion order, not source order. -/
def render (w : Nat) (d : Doc) : String × Array Mark :=
  go w [.doc 0 .brk d] 0 0 "" #[]

/-- The rendered text, for callers that do not need the source map. -/
def renderText (w : Nat) (d : Doc) : String :=
  (render w d).1

end LeanFmt.Internal
