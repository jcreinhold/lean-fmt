module

/- Candidate A for `RLC-SPEC`: a Wadler/Leijen-style document algebra.

The algebra is a tree. Callers name structure (`group`, `nest`, `line`) and never a column. Two
renderers are provided *for the same algebra*, because the point of this experiment is that the
choice of algebra and the choice of rendering algorithm are separate decisions and only one of them
is forced by Lean:

* `renderTextbook` is Wadler's `best`/`fits` transliterated into Lean. It is the algorithm as
  published, and it is the algorithm every description of "just use a pretty-printer algebra"
  implicitly means.
* `renderBounded` is a work-list renderer whose fit test stops after the line width is exhausted.

Wadler's complexity argument is a statement about Haskell, not about the algebra: `better` returns
one of two *unevaluated* renderings and `fits` forces only the prefix of the winner that fits on the
current line. Lean is strict. `renderTextbook` therefore evaluates both alternatives, including the
whole rest of the document behind each, before it can compare them. This file exists to measure the
size of that difference rather than to assert it.

Nothing here imports `LeanFmt`. A prototype that shared the product's code could not contradict it. -/

import Lean

namespace LayoutCore.Wadler

/-- The candidate constructor set.

`line` carries the text it becomes when its group is flat, which is the one generalization this
experiment cares about: Wadler's `line` (flat `" "`), Leijen's `softline` (flat `""`), and a
mode-dependent separator such as `do`'s `"; "` are then the same constructor at three arguments
rather than three constructors. Candidate B cannot express the third at all; see `Oppen.lean`. -/
inductive Doc where
  | empty
  | text (s : String)
  | line (flat : String)
  | hard
  | cat (a b : Doc)
  | nest (n : Nat) (d : Doc)
  | group (d : Doc)
  deriving Inhabited

instance : Append Doc where
  append := .cat

/-- Column width of a rendered fragment. Codepoints, not bytes and not terminal cells; the policy
and its measured disagreement with display width are recorded in the design note. -/
def width (s : String) : Nat := s.length

/-! ## Renderer 1: Wadler's algorithm, transliterated

Kept structurally identical to the published `best`/`better`/`fits` so that what is being measured is
strictness and nothing else. -/

/-- The rendered form: text and newlines-with-indent. Wadler's `SimpleDoc`. -/
inductive SDoc where
  | nil
  | sText (s : String) (rest : SDoc)
  | sLine (indent : Nat) (rest : SDoc)
  deriving Inhabited

/-- `hard` survives flattening: a group containing one can never be flat. Wadler has no `hard`, but
every formatter that prints comments needs one, so it is in both candidates. -/
partial def flatten : Doc → Doc
  | .empty => .empty
  | .text s => .text s
  | .line flat => .text flat
  | .hard => .hard
  | .cat a b => .cat (flatten a) (flatten b)
  | .nest n d => .nest n (flatten d)
  | .group d => flatten d

/-- Does the rendered document's first line fit in `w` columns? Walks `SDoc`, which in Haskell is
produced lazily by the very `best` call being tested; in Lean it is already fully built. -/
partial def fitsS (w : Int) : SDoc → Bool
  | .nil => w >= 0
  | .sText s rest => if w < 0 then false else fitsS (w - width s) rest
  | .sLine .. => w >= 0

/-- Wadler's `best`, with a step counter threaded through so the cost is a reproducible number
rather than a wall time.

The `let` is the transliteration's whole story: in Haskell `better`'s first argument is a thunk, so
the flat rendering of the rest of the document is built only as far as `fits` looks. Here it is built
in full — including every group in `z`, recursively — and then possibly discarded. -/
partial def best (w : Nat) : Nat → List (Nat × Doc) → Nat → SDoc × Nat
  | _, [], n => (.nil, n)
  | k, (_, .empty) :: z, n => best w k z (n + 1)
  | k, (i, .cat a b) :: z, n => best w k ((i, a) :: (i, b) :: z) (n + 1)
  | k, (i, .nest j d) :: z, n => best w k ((i + j, d) :: z) (n + 1)
  | k, (_, .text s) :: z, n =>
    let (rest, n) := best w (k + width s) z (n + 1)
    (.sText s rest, n)
  | _, (i, .line _) :: z, n =>
    let (rest, n) := best w i z (n + 1)
    (.sLine i rest, n)
  | _, (i, .hard) :: z, n =>
    let (rest, n) := best w i z (n + 1)
    (.sLine i rest, n)
  | k, (i, .group d) :: z, n =>
    let (flatRendering, n) := best w k ((i, flatten d) :: z) (n + 1)
    if fitsS (Int.ofNat w - Int.ofNat k) flatRendering then
      (flatRendering, n)
    else
      best w k ((i, d) :: z) n

partial def layoutS (acc : Array String) : SDoc → Array String
  | .nil => acc
  | .sText s rest => layoutS (acc.push s) rest
  | .sLine indent rest => layoutS (acc.push ("\n" ++ "".pushn ' ' indent)) rest

/-- Returns the rendering and the number of `best` steps it cost. -/
def renderTextbook (w : Nat) (d : Doc) : String × Nat :=
  let (sdoc, steps) := best w 0 [(0, d)] 0
  (String.join (layoutS #[] sdoc).toList, steps)

/-! ## Renderer 2: bounded work list

Same algebra, same output contract, different algorithm. No alternative rendering is ever built: the
fit test walks the *undecided* document and stops as soon as the line is full or a break-mode line
ends it. This is the shape Prettier, Biome, and `ruff_formatter` all use, and it is the shape a
strict language forces. -/

inductive Mode where
  | flat
  | brk
  deriving BEq, Inhabited

private abbrev Cmd := Nat × Mode × Doc

/-- Fit test with bounded lookahead, counting its own steps.

`remaining` is columns left on the current line; the walk stops at the first break-mode line, since
everything after it is on another line and cannot affect this one. `hard` in flat mode is the
comment case: it reports "does not fit" and so forces the enclosing group open.

The step count is carried here rather than only in the work list because the fit test is where a
bounded renderer could hide a quadratic: a `fits` that is not actually bounded shows up in this
number and nowhere else. -/
partial def fits (remaining : Int) : List Cmd → Nat → Bool × Nat
  | [], n => (remaining >= 0, n)
  | (i, m, d) :: z, n =>
    if remaining < 0 then (false, n)
    else match d with
      | .empty => fits remaining z (n + 1)
      | .text s => fits (remaining - width s) z (n + 1)
      | .cat a b => fits remaining ((i, m, a) :: (i, m, b) :: z) (n + 1)
      | .nest j d => fits remaining ((i + j, m, d) :: z) (n + 1)
      | .group d => fits remaining ((i, .flat, d) :: z) (n + 1)
      | .line flat => match m with
        | .flat => fits (remaining - width flat) z (n + 1)
        | .brk => (remaining >= 0, n + 1)
      | .hard => match m with
        | .flat => (false, n + 1)
        | .brk => (remaining >= 0, n + 1)

/-- Returns the rendering and the total number of steps it cost, work list and fit tests together. -/
partial def renderBounded (w : Nat) (d : Doc) : String × Nat :=
  let (acc, steps) := go [(0, .brk, d)] 0 #[] 0
  (String.join acc.toList, steps)
where
  go : List Cmd → Nat → Array String → Nat → Array String × Nat
    | [], _, acc, n => (acc, n)
    | (i, m, d) :: z, col, acc, n => match d with
      | .empty => go z col acc (n + 1)
      | .text s => go z (col + width s) (acc.push s) (n + 1)
      | .cat a b => go ((i, m, a) :: (i, m, b) :: z) col acc (n + 1)
      | .nest j d => go ((i + j, m, d) :: z) col acc (n + 1)
      | .hard => go z i (acc.push ("\n" ++ "".pushn ' ' i)) (n + 1)
      | .line flat => match m with
        | .flat => go z (col + width flat) (acc.push flat) (n + 1)
        | .brk => go z i (acc.push ("\n" ++ "".pushn ' ' i)) (n + 1)
      | .group d =>
        -- The rest of the line matters: a group that fits on its own may still not fit once what
        -- follows it before the next break is counted. `z` is carried into the test for that reason.
        let (ok, n) := fits (Int.ofNat w - Int.ofNat col) ((i, .flat, d) :: z) (n + 1)
        go ((i, if ok then .flat else .brk, d) :: z) col acc n

/-! ## Instrumentation -/

partial def size : Doc → Nat
  | .empty | .text _ | .line _ | .hard => 1
  | .cat a b => 1 + size a + size b
  | .nest _ d => 1 + size d
  | .group d => 1 + size d

end LayoutCore.Wadler
