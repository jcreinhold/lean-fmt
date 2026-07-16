module

/- Candidate B for `RLC-SPEC`: a token-stream constraint model.

This is Oppen's 1980 prettyprinter ("Prettyprinting", TOPLAS 2(4)), the algorithm behind rustfmt's
`pp.rs` and the classic Lisp/Modula pretty-printers. It is the strongest alternative to a document
algebra and it is strictly better than one on the two axes it was designed for: it consumes a
*stream*, never materializes a tree, runs in one pass, and bounds its buffer by the line width rather
than by the document.

The stream is four token kinds:

    Text s              literal output
    Break blank offset  a candidate line break; `blank` spaces if the enclosing group is flat
    Begin offset kind   open a group, `consistent` (all breaks together) or `inconsistent` (each
                        break decides for itself)
    End                 close a group

Two properties of that alphabet are what this experiment is here to measure rather than assert:

* `Break` inserts *blanks*, never text. Whatever a group's flat form needs beyond spaces cannot be
  said. `LayoutProbe` exercises exactly one such case.
* `Begin`/`End` balance is the caller's obligation and is checked, if at all, at run time.

`peakBuffer` and `visits` are instrumentation, not part of the algorithm. They exist so the O(n) time
and O(w) memory claims are measured on the same inputs as candidate A rather than cited.

Nothing here imports `LeanFmt`, and nothing here imports `Wadler`: the two candidates must be able to
disagree. -/

import Std.Data.HashMap

namespace LayoutCore.Oppen

inductive Breaks where
  | consistent
  | inconsistent
  deriving BEq, Inhabited

inductive Tok where
  | text (s : String)
  | brk (blank : Nat) (offset : Int)
  | begin (offset : Int) (breaks : Breaks)
  | «end»
  deriving Inhabited

/-- Oppen's "infinity": any size at least this large is treated as not fitting on any line. -/
def sizeInfinity : Int := 0xffff

private structure BufEntry where
  tok : Tok
  size : Int
  deriving Inhabited

/-- An index-keyed deque. Oppen needs O(1) at both ends of the scan stack and O(1) mutation of
buffered entries by index; an `Array` would make `pop_front` linear and quietly turn the O(n) claim
under test into O(n·w). Keys are logical positions and never reused. -/
private structure Deque (α : Type) where
  items : Std.HashMap Nat α := {}
  head : Nat := 0
  tail : Nat := 0
  deriving Inhabited

private def Deque.isEmpty (d : Deque α) : Bool := d.head == d.tail
private def Deque.size (d : Deque α) : Nat := d.tail - d.head
private def Deque.pushBack [Inhabited α] (d : Deque α) (a : α) : Nat × Deque α :=
  (d.tail, { d with items := d.items.insert d.tail a, tail := d.tail + 1 })
private def Deque.back? (d : Deque α) : Option α :=
  if d.isEmpty then none else d.items[d.tail - 1]?
private def Deque.front? (d : Deque α) : Option α :=
  if d.isEmpty then none else d.items[d.head]?
private def Deque.popBack (d : Deque α) : Deque α :=
  if d.isEmpty then d else { d with items := d.items.erase (d.tail - 1), tail := d.tail - 1 }
private def Deque.popFront (d : Deque α) : Deque α :=
  if d.isEmpty then d else { d with items := d.items.erase d.head, head := d.head + 1 }
private def Deque.get? (d : Deque α) (index : Nat) : Option α := d.items[index]?
private def Deque.set (d : Deque α) (index : Nat) (a : α) : Deque α :=
  if d.items.contains index then { d with items := d.items.insert index a } else d

private structure Frame where
  broken : Bool
  indent : Nat
  breaks : Breaks
  deriving Inhabited

private structure St where
  out : Array String := #[]
  margin : Int
  space : Int
  buf : Deque BufEntry := {}
  /-- Scan-stack entries are logical indices into `buf`. -/
  scan : Deque Nat := {}
  leftTotal : Int := 0
  rightTotal : Int := 0
  printStack : Array Frame := #[]
  indent : Nat := 0
  pendingIndent : Nat := 0
  peakBuffer : Nat := 0
  visits : Nat := 0
  /-- Set when `End` arrives with no open group, i.e. the caller handed us an unbalanced stream.
  A tree cannot be unbalanced; this field is candidate B's extra error surface, made observable. -/
  unbalanced : Bool := false
  deriving Inhabited

private abbrev M := StateM St

private def width (s : String) : Nat := s.length

private def note : M Unit := modify fun s =>
  { s with visits := s.visits + 1, peakBuffer := max s.peakBuffer s.buf.size }

/-! ## Print half

Consumes decided tokens. `size` has already been resolved by the scan half to the width of the
material the token spans, or to `sizeInfinity` if the scan gave up waiting. -/

private def printString (str : String) : M Unit := modify fun s =>
  { s with
    out := (if s.pendingIndent == 0 then s.out else s.out.push ("".pushn ' ' s.pendingIndent)).push str
    pendingIndent := 0
    space := s.space - Int.ofNat (width str) }

private def printBegin (offset : Int) (breaks : Breaks) (size : Int) : M Unit := modify fun s =>
  if size > s.space then
    { s with
      printStack := s.printStack.push { broken := true, indent := s.indent, breaks }
      indent := (Int.ofNat s.indent + offset).toNat }
  else
    { s with printStack := s.printStack.push { broken := false, indent := s.indent, breaks } }

private def printEnd : M Unit := modify fun s =>
  match s.printStack.back? with
  | none => { s with unbalanced := true }
  | some frame =>
    { s with
      printStack := s.printStack.pop
      indent := if frame.broken then frame.indent else s.indent }

private def printBreak (blank : Nat) (offset : Int) (size : Int) : M Unit := modify fun s =>
  let fits := match s.printStack.back? with
    | none => true
    | some frame =>
      if !frame.broken then true
      else match frame.breaks with
        | .consistent => false
        | .inconsistent => size <= s.space
  if fits then
    { s with pendingIndent := s.pendingIndent + blank, space := s.space - Int.ofNat blank }
  else
    let indent := Int.ofNat s.indent + offset
    { s with
      out := s.out.push "\n"
      pendingIndent := indent.toNat
      space := s.margin - indent }

/-! ## Scan half -/

private partial def advanceLeft : M Unit := do
  let s ← get
  match s.buf.front? with
  | none => return
  | some entry =>
    if entry.size < 0 then return
    note
    modify fun s => { s with buf := s.buf.popFront }
    match entry.tok with
    | .text str => do
      modify fun s => { s with leftTotal := s.leftTotal + entry.size }
      printString str
    | .brk blank offset => do
      modify fun s => { s with leftTotal := s.leftTotal + Int.ofNat blank }
      printBreak blank offset entry.size
    | .begin offset breaks => printBegin offset breaks entry.size
    | .«end» => printEnd
    advanceLeft

/-- Give up on the oldest undecided group: its size can no longer matter, because the material
already scanned past it exceeds the line. This is the step that bounds the buffer. -/
private partial def checkStream : M Unit := do
  let s ← get
  if s.rightTotal - s.leftTotal <= s.space then return
  if s.buf.isEmpty then return
  match s.scan.front? with
  | some index =>
    if index == s.buf.head then
      modify fun s =>
        let buf := match s.buf.front? with
          | some entry => s.buf.set s.buf.head { entry with size := sizeInfinity }
          | none => s.buf
        { s with scan := s.scan.popFront, buf }
  | none => pure ()
  advanceLeft
  let s' ← get
  if s'.buf.isEmpty then return
  checkStream

/-- Resolve the sizes of everything the scan stack is still waiting on, up to `depth` unmatched
group openings. -/
private partial def checkStack (depth : Nat) : M Unit := do
  let s ← get
  match s.scan.back? with
  | none => return
  | some index =>
    match s.buf.get? index with
    | none => modify fun s => { s with scan := s.scan.popBack }
    | some entry =>
      match entry.tok with
      | .begin .. =>
        if depth == 0 then return
        modify fun s =>
          { s with
            scan := s.scan.popBack
            buf := s.buf.set index { entry with size := entry.size + s.rightTotal } }
        checkStack (depth - 1)
      | .«end» =>
        modify fun s =>
          { s with scan := s.scan.popBack, buf := s.buf.set index { entry with size := 1 } }
        checkStack (depth + 1)
      | _ =>
        modify fun s =>
          { s with
            scan := s.scan.popBack
            buf := s.buf.set index { entry with size := entry.size + s.rightTotal } }
        if depth == 0 then return
        checkStack depth

private def scanBegin (offset : Int) (breaks : Breaks) : M Unit := do
  note
  if (← get).scan.isEmpty then
    modify fun s => { s with leftTotal := 1, rightTotal := 1, buf := {} }
  modify fun s =>
    let (index, buf) := s.buf.pushBack { tok := .begin offset breaks, size := -s.rightTotal }
    { s with buf, scan := (s.scan.pushBack index).2 }

private def scanEnd : M Unit := do
  note
  if (← get).scan.isEmpty then
    printEnd
  else
    modify fun s =>
      let (index, buf) := s.buf.pushBack { tok := .«end», size := -1 }
      { s with buf, scan := (s.scan.pushBack index).2 }

private def scanBreak (blank : Nat) (offset : Int) : M Unit := do
  note
  if (← get).scan.isEmpty then
    modify fun s => { s with leftTotal := 1, rightTotal := 1, buf := {} }
  else
    checkStack 0
  modify fun s =>
    let (index, buf) := s.buf.pushBack { tok := .brk blank offset, size := -s.rightTotal }
    { s with buf, scan := (s.scan.pushBack index).2, rightTotal := s.rightTotal + Int.ofNat blank }

private def scanString (str : String) : M Unit := do
  note
  if (← get).scan.isEmpty then
    printString str
  else
    modify fun s =>
      let len := Int.ofNat (width str)
      { s with buf := (s.buf.pushBack { tok := .text str, size := len }).2
               rightTotal := s.rightTotal + len }
    checkStream

private def scanEof : M Unit := do
  unless (← get).scan.isEmpty do
    checkStack 0
    advanceLeft

/-- Render one token stream. -/
def render (margin : Nat) (toks : Array Tok) : String × Nat × Nat × Bool :=
  let init : St := { margin := Int.ofNat margin, space := Int.ofNat margin }
  let ((), s) := (go).run init
  (String.join s.out.toList, s.visits, s.peakBuffer, s.unbalanced)
where
  go : M Unit := do
    for tok in toks do
      match tok with
      | .text str => scanString str
      | .brk blank offset => scanBreak blank offset
      | .begin offset breaks => scanBegin offset breaks
      | .«end» => scanEnd
    scanEof

end LayoutCore.Oppen
