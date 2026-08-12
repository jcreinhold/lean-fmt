module

public import Test

/-!
# The native-layout suite

The native grammar adapter's invariant families, one declared fixture module each:

- `Alignment.lean` — positional terminal alignment: repeated spellings, multibyte columns, and
  literal bases whose source spelling the formatter is free to change
- `Boundaries.lean` — comment ownership at every boundary the adapter distinguishes
- `Chains.lean` — operator chains, whose links each inherit an indent level from the link outside
  them, and the one shape that is a chain by node kind with no break in it
- `Islands.lean` — typed exact islands: multiline payloads, interpolation, quotation
- `MathlibStyle.lean` — the grammar shapes mathlib's style linters flag: broken import rows,
  isolated focusing dots, attribute-owned doc comments nested past their payload's column
- `Offside.lean` — parser-significant columns native layout alone does not preserve
- `BracketedSequences.lean` — the two bracketed `sepByIndentSemicolon` families, whose narrow-width
  refusal became admission under `LAY-INDENTED-SEQUENCES`; the case pins the anchored width-20
  rows, and is not in the admission `fixtures` array (it has its own)

Constructor coverage: the `Std.Format` constructors reachable from registered-formatter output over
parsed source are `nil`, `append`, `text` (plain and newline-bearing — `sepByIndent`'s line-break
separator path), `line`, positive `nest`, `group` (both flatten behaviors), and `align true` (the
same `sepByIndent` path). `tag` is unreachable: `withMaybeTag` reads `getExprPos?`, which only
`SourceInfo.synthetic` populates. `align false` and negative `nest` have no producer in the pinned
toolchain's formatter pipeline. The fixtures cover every reachable constructor and all five
`sepByIndent` families — structInst fields, indented and bracketed tactic sequences, indented and
bracketed conv sequences, and `where` decls, the bracketed halves in `BracketedSequences.lean`.

Everything runs through `format --check`, never `format`: these fixtures are committed, and a
suite that invokes a writing mode against a committed fixture rewrites it the first time the path
under test starts succeeding.

Lane: workspace — the preamble clears the root cache.
-/

open LeanFmt.Test

namespace NativeLayout

structure Ctx where
  root : System.FilePath
  application : String
  work : System.FilePath
  /-- The width-100 renders, per fixture. -/
  once : String → IO String

private def fixtures : Array String :=
  #["Alignment", "Boundaries", "Chains", "Islands", "MathlibStyle", "Offside"]

/-- Lines containing the needle (grep -cF). -/
private def count (text needle : String) : Nat :=
  (text.splitOn "\n").filter (·.contains needle) |>.length

/-- Lines exactly equal (grep -c '^x$'). -/
private def countExact (text line : String) : Nat :=
  (text.splitOn "\n").filter (· == line) |>.length

/-- Lines equal to any of the given (an alternation anchored at both ends). -/
private def countAny (text : String) (choices : List String) : Nat :=
  (text.splitOn "\n").filter (choices.contains ·) |>.length

/-- Lines starting with the given prefix. -/
private def countPrefix (text pfx : String) : Nat :=
  (text.splitOn "\n").filter (·.startsWith pfx) |>.length

/-- The line `skip` after the first line containing `needle` (grep -A{skip} | tail -1). -/
private def lineAfter (text needle : String) (skip : Nat := 1) : IO String := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (·.contains needle) | throw <| IO.userError s!"lineAfter: {needle} not found"
  return lines[index + skip]?.getD "<missing>"

/-- The line `skip` after the first line *equal to* `line` (grep -A{skip} -Fx | tail -1). -/
private def lineAfterExact (text line : String) (skip : Nat := 1) : IO String := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (· == line) | throw <| IO.userError s!"lineAfterExact: {line} not found"
  return lines[index + skip]?.getD "<missing>"

/-- The `count` lines after the first line *equal to* `line`, rejoined. -/
private def linesAfterExact (text line : String) (count : Nat) : IO String := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (· == line) | throw <| IO.userError s!"linesAfterExact: {line} not found"
  return "\n".intercalate ((lines.drop (index + 1)).take count)

/-- The `count` lines after the first line containing `needle`, rejoined (grep -A{count} |
tail -{count}). -/
private def linesAfter (text needle : String) (count : Nat) : IO String := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (·.contains needle) | throw <| IO.userError s!"linesAfter: {needle} not found"
  return "\n".intercalate ((lines.drop (index + 1)).take count)

/-- The line before the first line containing `needle` (grep -B1 | head -1). -/
private def lineBefore (text needle : String) : IO String := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (·.contains needle) | throw <| IO.userError s!"lineBefore: {needle} not found"
  return lines[index - 1]?.getD "<missing>"

private def formatCheck (ctx : Ctx) (fixture : String) (config? : Option System.FilePath)
    (label : String) : IO String := do
  let configArgs :=
    match config? with
    | some path => #["--config", path.toString]
    | none => #[]
  let result ←
    expectExit 1 label ctx.application
        (#["format", "--check", "--root", ".", "--json", "--no-cache"] ++ configArgs ++
          #[s!"tests/fixtures/native-layout/{fixture}.lean"])
        (cwd? := some ctx.root)
  let report ← parseJson result.stdout label
  let file := (jsonAt? report [.field "files", .index 0]).getD .null
  let status := (file.getObjValAs? String "status").toOption.getD ""
  let diagnosticEntries := (jsonAt? file [.field "diagnostics"]).bind (·.getArr?.toOption)
  let diagnostics := (diagnosticEntries.getD #[]).toList.map (·.compress)
  ensureEq s!"{fixture} does not format and validate{diagnostics}" "would-format" status
  let some formatted :=
    (file.getObjValAs? String
        "formatted").toOption | throw <| IO.userError s!"{label}: no formatted text"
  return formatted

/-- §1: every family formats and validates under the exact module setup; §1b: and still validates
at narrow widths, where a flat boundary's re-measured break is the one that moves. -/
private def testAdmission (ctx : Ctx) : IO Unit := do
  for fixture in fixtures do
    discard <| formatCheck ctx fixture none s!"admission {fixture}"
  for width in [20, 40] do
    let config := ctx.work / s!"width-{width}.toml"
    writeFile config s!"[format]\nline-width = {width}\n"
    for fixture in fixtures do
      discard <| formatCheck ctx fixture (some config) s!"admission {fixture} at {width}"

/-- §2: formatting is a fixed point, end to end, on output the caller can actually see. -/
private def testIdempotence (ctx : Ctx) : IO Unit := do
  for fixture in fixtures do
    let once ← ctx.once fixture
    let twice ←
      expectExit 0 s!"second pass {fixture}" ctx.application
          #["format", "-", "--stdin-filename", s!"tests/fixtures/native-layout/{fixture}.lean",
            "--root", "."]
          (input? := some once) (cwd? := some ctx.root)
    ensureEq s!"{fixture} is not idempotent" once twice.stdout

/-- No line ends in whitespace, and no candidate holds two consecutive blank lines, in any
fixture, at every rendered width. Both are stated over every candidate because a trailing space
and a blank line are invisible in a diff and the validator reparses, where they change no
token. -/
private def testHygiene (ctx : Ctx) : IO Unit := do
  for fixture in fixtures do
    let mut renders := #[(← ctx.once fixture)]
    for width in [20, 40] do
      let config := ctx.work / s!"width-{width}.toml"
      renders := renders.push (← formatCheck ctx fixture (some config) s!"hygiene {fixture}")
    for render in renders do
      let trailing :=
        (render.splitOn "\n").filter
            (fun line => line.back?.map Char.isWhitespace |>.getD false) |>.length
      ensureEq s!"{fixture} leaves trailing whitespace" 0 trailing
      ensureEq s!"{fixture} holds a double blank line" 0 ((render.splitOn "\n\n\n").length - 1)

/-- The leading-space count of each line after the one equal to `header`, up to the next blank line.
A staircase is visible in this list and in nothing shorter: every row is a legal place to break, so
what is wrong with an uncompensated chain is only that the numbers keep going up. -/
private def bodyIndents (text header : String) : IO (List Nat) := do
  let lines := text.splitOn "\n"
  let some index :=
    lines.findIdx? (· == header) | throw <| IO.userError s!"bodyIndents: {header} not found"
  let body := (lines.drop (index + 1)).takeWhile (· != "")
  return body.map fun line => line.length - (line.dropWhile (· == ' ')).length

/-- §2b: one operator chain, one column. Lean's generated formatters wrap every category node in
`group (nest format.indent …)`, so a chain — one node per link — stacks one `nest` per link, and each
break lands one column further in than the one before it. `LAY-CHAIN-COMPENSATION` cancels the level
each link inherits, and these are the rows that says. The width-40 render is where it is legible: the
chains are long enough there that an uncompensated one would walk off the margin. -/
private def testChains (ctx : Ctx) : IO Unit := do
  let chains ← ctx.once "Chains"
  ensureEq "an infixl chain breaks one level in at width 100" "    \"golf\""
      (← lineAfter chains "\"foxtrot\" ++ f ++")
  -- A `let` holds its body's row at a source column, and a chain's leftmost operand starts exactly
  -- where that row does. Declining an operand that merely *touches* a pin declined every chain
  -- written as a `let` body -- ordinary Lean, and 152 columns of indent in this repository's own
  -- `catalogSchemaJson` until it was narrowed to pins strictly inside.
  ensureEq "a chain that is a let body is compensated like any other" [4, 4, 4]
      (←
        bodyIndents chains
            "  head ++ \"alpha\" ++ a ++ \"bravo\" ++ b ++ \"charlie\" ++ c ++ \
\"delta\" ++ d ++ \"echo\" ++ e ++")
  -- `proj` inside `proj` is a chain by node kind with no break in it, so the compensation finds no
  -- `nest` to cancel and lands nowhere. A corpus module carrying one refused outright while these
  -- constraints were required; this row is what says they are not.
  ensureEq "a dot-projection chain formats rather than refusing" 1 (countExact chains "  p.1.2")
  let config := ctx.work / "width-40-chains.toml"
  writeFile config "[format]\nline-width = 40\n"
  let narrow ← formatCheck ctx "Chains" (some config) "chains at 40"
  let joined ← bodyIndents narrow "    (a b c d e f : String) : String :="
  ensureEq "an infixl chain breaks nine times" 9 (joined.length - 1)
  ensureEq "  ... and every one of them at the same column" [] (joined.drop 1 |>.filter (· != 4))
  let stacked ← bodyIndents narrow "public def stacked (a b c d : Nat) :"
  ensureEq "an infixr chain, which nests the other way, does the same" []
      (stacked.drop 2 |>.filter (· != 4))
  -- The negative half. Parentheses interpose a node of another kind, so the sub-chain does not
  -- continue the chain around it: it keeps the level the parenthesis opened, and the outer chain
  -- keeps its own. Two columns, neither of them climbing.
  ensureEq "a parenthesised sub-chain holds a column of its own" [6, 6, 6, 6, 6, 6, 6, 4, 4, 4]
      (← bodyIndents narrow "  (a ++ \"alpha\" ++ b ++ \"bravo\" ++ c ++")

/-- §3: terminal payloads are original bytes, matched by position. Includes the live upstream pin: the
space Lean's `pushToken` used not to put between `]` and `do` — inverted since v4.34.0-rc1, which fixed it. -/
private def testAlignment (ctx : Ctx) : IO Unit := do
  let alignment ← ctx.once "Alignment"
  ensureEq "a guillemet name survives" 1 (count alignment "def «name with spaces»")
  ensureEq "greek binders and arrows survive" 1
      (count alignment "(α : Type) (compose : α → α) : α → α")
  ensureEq "the compose operator survives" 1 (count alignment "compose ∘ compose")
  -- Literal bases: `Nat.repr` would print `255` and `10`. The source spelling is the contract, so
  -- the absence of the decimal forms is as much the claim as the presence of the others.
  ensureEq "hex and binary literals keep their spelling" 1 (count alignment "(0xff, 0b1010)")
  ensureEq "no literal was renormalized to decimal" 0 (count alignment "(255, 10)")
  -- Repeated spellings: a by-spelling matcher cannot say which occurrence a native leaf denotes.
  ensureEq "a four-fold repeated identifier survives" 1
      (count alignment "value + value + value + value")
  ensureEq "two same-spelled calls keep their own arguments" 1
      (count alignment "Nat.succ pair.fst + Nat.succ pair.snd")
  ensureEq "an escaped string is not re-escaped" 1 (count alignment "\"tab\\there\"")
  -- A blank line the source put between a leading comment and its owner: the copyright block
  -- ends flush against `module` in neither direction.
  let lines := alignment.splitOn "\n"
  let some closer :=
    lines.findIdx? (· == "-/") | throw <| IO.userError "alignment: no copyright block"
  ensureEq "the blank line after the copyright block survives" ""
      (lines[closer + 1]?.getD "<missing>")
  ensureEq "and module follows it directly" "module" (lines[closer + 2]?.getD "<missing>")
  -- §7 (upstream, fixed in v4.34.0-rc1): the space Lean's formatter used to drop between `]` and
  -- `do`. leanprover/lean4#14389 moved `doForDecl` to `withForbiddens #["do", "invariant"]`, whose
  -- registered combinator formatter keeps the space; the flush form is now absent by design. The
  -- pin stays, inverted, so a regression that reintroduces the flush form fails loudly again.
  ensureEq "a for over a bracketed collection keeps the space before do" 1
      (count alignment "for value in #[1, 2, 3] do")
  ensureEq "  ... and the flush form is gone" 0 (count alignment "for value in #[1, 2, 3]do")
  ensureEq "  ... and the same loop over an identifier keeps it" 1
      (count alignment "for value in list do")

/-- §4: every comment is placed exactly once, and owned by the construct the source wrote it
on. -/
private def testBoundaries (ctx : Ctx) : IO Unit := do
  let boundaries ← ctx.once "Boundaries"
  for body in
    ["-- leading line comment", "-- trailing line comment", "/- leading block comment -/",
      "-- first of two consecutive comments", "-- second of two consecutive comments",
      "-- interior line comment before a continuation",
      "/- interior block comment inside a delimiter -/",
      "/-- A declaration doc comment stays on its declaration. -/",
      "/-- A field doc comment stays on its field, not on the structure. -/",
      "/-- A constructor doc comment stays on its constructor. -/",
      "-- an ordinary comment above a docstring is not part of it",
      "-- the first of two comments above a docstring",
      "-- the second of two comments above a docstring",
      "-- dangling comment after the last statement",
      "-- indented past every block, aligned with none of them"] do
    ensureEq s!"placed once: {body}" 1 (count boundaries body)
  -- Ownership, not just presence: the field docstring pins to the line directly above the field.
  ensureEq "the field docstring still precedes its field" "  first : Nat"
      (← lineAfter boundaries "/-- A field doc comment")
  -- A docstring on a `where` binding is an exact island *and* the terminal a doc boundary
  -- was collected at. Both bindings, because `where` is `checkColGe` against the first.
  ensureEq "a where binding's docstring keeps its own line" 1
      (countExact boundaries "  /-- Doubles its argument. -/")
  ensureEq "  ... and so does the second one, whose column the first fixes" 1
      (countExact boundaries "  /-- Adds one to its argument. -/")
  ensureEq "  ... and both bindings land on one column" 2
      (countPrefix boundaries "   twice (n : Nat) : Nat := n + " +
        countPrefix boundaries "   once (n : Nat) : Nat := n + ")
  -- Three runs the source spells on one line, each a list whose items the parser measures
  -- against a column no `Format` constructor names.
  ensureEq "a field's binders stay on one line however its body breaks" 1
      (countExact boundaries "  bounded {n} m h := by")
  ensureEq "  ... an induction's generalized variables stay together" 1
      (count boundaries "generalizing firstGeneralized secondGeneralized with")
  ensureEq "  ... and a structure instance's ellipsis keeps the line the source gave it" 1
      (countExact boundaries "    .. }")
  ensureEq "the constructor docstring keeps its constructor's indentation" 1
      (countExact boundaries "  /-- A constructor doc comment stays on its constructor. -/")
  ensureEq "  ... and its constructor follows on the next line, with no blank between" "  | left"
      (← lineAfter boundaries "A constructor doc comment stays on its constructor")
  -- A docstring spanning more than one line: the continuation lines do not move with its first.
  ensureEq "a constructor docstring's continuation lines do not move with its first"
      "  exact island already carries exactly where they are. -/"
      (← lineAfter boundaries "A constructor doc comment can run onto a second line" 2)
  ensureEq "  ... and its constructor still follows it" "  | only"
      (← lineAfter boundaries "A constructor doc comment can run onto a second line" 3)
  -- The comment is placed at the forced alignment between `by` and its first tactic, and its
  -- continuation line keeps the column the source gave it.
  ensureEq "a comment in a forced alignment is placed on the align's own column" 1
      (countExact boundaries
        "  /- A comment written between `by` and the first tactic, too long to join the `by` line, with a")
  ensureEq "  ... with its continuation line still at the column the source gave it" 1
      (countExact boundaries "  continuation line that owns its own column. -/")
  ensureEq "  ... and the tactic it leads at that same column, with its siblings"
      "  let doubled := n\n  have step : doubled + 0 = doubled := Nat.add_zero doubled"
      (← linesAfterExact boundaries "  continuation line that owns its own column. -/" 2)
  -- The ordinary comment stays *above* the docstring, and the docstring appears once. The
  -- defect dropped the command's entire leading trivia whenever it contained doc syntax.
  ensureEq "an ordinary comment stays above the docstring it precedes"
      "/-- A doc comment can be preceded by ordinary comments the command does not own. -/"
      (← lineAfter boundaries "-- an ordinary comment above a docstring is not part of it")
  ensureEq "  ... and that docstring is emitted exactly once" 1
      (count boundaries
        "/-- A doc comment can be preceded by ordinary comments the command does not own. -/")
  ensureEq "both of two comments above a docstring survive, in order"
      "-- the second of two comments above a docstring"
      (← lineAfter boundaries "-- the first of two comments above a docstring")
  ensureEq "the trailing comment stays on its owner's last line" "  0 -- trailing line comment"
      ((boundaries.splitOn "\n").filter (·.contains "-- trailing line comment") |>.head?.getD "")
  -- An *ownership* defect. The comment lines up with the statement it follows, and the
  -- statement is still the last thing in the block.
  ensureEq "a block's dangling comment stays inside the block" "    return value"
      (← lineBefore boundaries "-- dangling comment after the last statement")
  ensureEq "  ... at the column of the statement it follows" 1
      (countExact boundaries "    -- dangling comment after the last statement")
  -- The negative half of the same rule: aligned with no block item, the comment keeps its leading
  -- assignment.
  ensureEq "a comment aligned with no block item keeps its leading assignment" 1
      (countExact boundaries "-- indented past every block, aligned with none of them")
  -- The same rule one nesting level in. At 6 the comment reparses as dangling on the `if`'s
  -- block, at 4 as leading trivia of the next statement, at 8 as dangling on the branch. All
  -- three parse; only one is the comment the source wrote.
  ensureEq "a comment closing an inner block stays at that block's column" 1
      (countExact boundaries "      -- dangling on the block the `if` opens")
  ensureEq "  ... and a second one leaves with it" 1
      (countExact boundaries "      -- and a second one, which leaves with the first")
  ensureEq "  ... and the statement after the block keeps its own column" 1
      (countExact boundaries "    total := total + 3")
  ensureEq "the interior comment stays between the operator and its continuation" "    4"
      (← lineAfter boundaries "-- interior line comment")
  -- The adapter owns *both* sides of a comment. `[` and `5` are adjacent in the list grammar,
  -- so the native boundary between them is empty.
  ensureEq "a block comment closing mid-row is separated from the token after it"
      "  [ /- interior block comment inside a delimiter -/ 5, 6]"
      ((boundaries.splitOn "\n").filter
          (·.contains "/- interior block comment inside a delimiter -/") |>.head?.getD
        "")

/-- §5: exact islands keep payload columns — the continuation lines are asserted at the columns
the *source* gave them. -/
private def testIslands (ctx : Ctx) : IO Unit := do
  let islands ← ctx.once "Islands"
  ensureEq "a multiline payload reaches column zero" 1 (countExact islands "gamma\"")
  ensureEq "a multiline payload keeps its own indented line" 1 (countExact islands "  beta")
  ensureEq "the same payload one level deeper still owns its columns" 1
      (countExact islands "  second\"")
  ensureEq "an interpolated string keeps both holes" 1
      (count islands "s!\"hello {name} and {name}\"")
  ensureEq "a quotation with an antiquotation survives" 1 (count islands "`($(Lean.quote value))")
  ensureEq "a multiline doc comment keeps its second line at column zero" 1
      (countExact islands "Its second line owns its own column. -/")
  -- The dynamic quotation is an island because Lean's formatter cannot reach it at all.
  ensureEq "a dynamic quotation survives as its own bytes" 1
      (count islands "`(Lean.explicitBinders| (x : Nat))")
  -- Twice-escalated protection; the island covers every terminal the first one replaced.
  ensureEq "a twice-escalated quotation covers all of its own terminals" 1
      (count islands "`($(_) fun $_:ident ↦ $body)")
  -- A quotation whose body the grammar calls a command; an unapplied boundary is a refusal.
  ensureEq "a command quotation keeps its body inside the island" 1
      (count islands "`(command| #eval $value)")
  -- `sepBy.antiquot_scope` and `sepBy.antiquot_suffix_splice` name no formatter at all;
  -- protection is what lets a macro body carrying them format.
  ensureEq "an antiquotation splice survives as its own bytes" 1 (count islands "($[have := $h];*)")
  ensureEq "a suffix splice survives as its own bytes" 1 (count islands "$xs,*")
  -- A binder whose whole type applies a doubly-declared infix backtracks the upstream formatter
  -- uncaught (`format: uncaught backtrack exception`); the command degrades to its source bytes
  -- verbatim, odd spacing and all, and the command after it still formats.
  ensureEq "a backtracked command keeps its source bytes verbatim" "        T) : True := trivial"
      (←
        lineAfterExact islands
            "theorem backtrackBinder (M : Type) (T : BacktrackTheo) (hM : M   ⊨⊨")
  ensureEq "the command after a backtracked one still formats" "  Nat.add_zero n"
      (← lineAfterExact islands "theorem formatsAroundBacktrack (n : Nat) : n + 0 = n :=")
  -- The island the walk meets while the cursor is still behind it. Before the plan ruled a cut
  -- terminal out statically, this reported as an island defect and refused the whole file; it is a
  -- native document that dropped a subtree, so the command degrades and its bytes stand.
  ensureEq "an island reached with the cursor behind degrades rather than refusing"
      "    \"`infer_probe_param` only solves goals of the form `optParam _ _` or `autoParam _ _`, \
not {tgt}\""
      (← lineAfterExact islands "  else throwError")
  ensureEq "the command after a truncated island still formats" "  Nat.add_zero n"
      (← lineAfterExact islands "theorem formatsAroundIslandTruncation (n : Nat) : n + 0 = n :=")

/-- §6: offside carriers compose — `sepByIndent` covers record fields and tactic/conv sequences;
`do`, `match`, and equation alternatives have no algebra carrier at all. -/
private def testOffside (ctx : Ctx) : IO Unit := do
  let offside ← ctx.once "Offside"
  ensureEq "a record update opens its field sequence on its own line"
      "    first := 1, second := 2, third := 3, fourth := 4 }"
      (← lineAfterExact offside "def updated (base : Packet) : Packet :=" 2)
  ensureEq "match arms stay siblings at one column" 1 (countExact offside "      | 0 => 1")
  ensureEq "the nested match indents one level further" 1 (countExact offside "        | 0 => 2")
  ensureEq "equation alternatives stay at the declaration's own indent" 1
      (countExact offside "  | n + 2 => alternatives n + alternatives (n + 1)")
  ensureEq "tactic steps stay siblings" "  exact step" (← lineAfter offside "have step : n + 0 = n")
  -- `Term.byTactic` declares `ppAllowUngrouped` to keep `by` on the `:=` line; a flat boundary at
  -- the `by` terminal is what holds it, since the adapter does not own `fill`'s measurement. The
  -- count covers the five carrier theorems, `letIdBodyJoins`, and its tactic-level `have step`.
  -- The conv coverage added `convSiblings`, `convSemicolon`, and `convNested`; the
  -- mid-row `change (letI …` example adds one more, and the equal-column `change` example one
  -- after that.
  ensureEq "by stays on the := line" 12
      ((offside.splitOn "\n").filter (·.endsWith " := by") |>.length)
  ensureEq "and its first tactic still starts the next line"
      "  have step : n + 0 = n := Nat.add_zero n"
      (← lineAfterExact offside "theorem tacticSiblings (n : Nat) : n + 0 = n := by")
  -- The cascade pin: a signature that fits joined stays joined when the proof breaks. A
  -- newline-separated sequence's first item is preceded by `sepByIndent`'s `align(true)`, whose
  -- measurement charges phantom columns instead of stopping (`Init/Data/Format/Basic.lean`'s
  -- `spaceUptoLine`), and once the `:= by` join removes the soft `line` that stopped the fill
  -- groups' fit measurement there, every signature group measured through to the phantom and
  -- broke -- this theorem's 48-column signature used to shatter at the `:`. The `hard` boundary
  -- the ungrouped collector now spells for a written-separator sequence too makes the align's
  -- newline a real `text "\n"` and stops the measurement where the row ends.
  ensureEq "a fitting signature survives a multi-line proof" 1
      (countExact offside "theorem tacticSiblings (n : Nat) : n + 0 = n := by")
  ensureEq "  ... and the longer conjunction one too" 1
      (countExact offside "theorem carriedTactics (a : Nat) : a = a ∧ a = a := by")
  -- A `;`-separated tactic sequence is a `sepByIndent` list, and `by ` lands its first tactic
  -- at one column past the indent the separators break to.
  ensureEq "a semicolon-separated tactic sequence opens on its own line"
      "  constructor; exact Nat.add_zero n; exact Nat.add_zero n"
      (← lineAfterExact offside "theorem semicolonTactics (n : Nat) : n + 0 = n ∧ n + 0 = n := by")
  -- The negative half: one item has no separator, so there is nothing to position.
  ensureEq "a single tactic stays on the by line" 1
      (countExact offside "theorem singleTactic (n : Nat) : n + 0 = n := by rfl")
  -- The rule reads the *carrier* rather than the sequence's own kind.
  ensureEq "a parenthesised tactic sequence stays on its carrier's line" 1
      (count offside "by constructor <;> (skip; rfl)")
  ensureEq "  ... as does a focus dot's" 2 (countExact offside "  · skip; rfl")
  ensureEq "  ... while a case arm's still opens on its own line" "    skip; rfl"
      (← lineAfterExact offside "  case left =>")
  ensureEq "  ... and a show's by opens its sequence as by's own does" "    constructor; rfl; rfl"
      (← lineAfterExact offside "  show value + 0 = value ∧ value + 0 = value by")
  -- The fifth `sepByIndent` family. `conv =>` is a delimiter-intervenes carrier like `case h =>`,
  -- so its `;`-spelled list opens on its own line; the line-break spelling is the formatter's own
  -- `align`; one item has nothing to position; the bracketed spelling is already positioned.
  ensureEq "a line-break conv sequence keeps its rows"
      "  conv =>\n    lhs\n    rw [Nat.add_zero]\n    rw [h]"
      (← linesAfter offside "theorem convSiblings" 4)
  ensureEq "a semicolon conv sequence opens on its own line" "    lhs; rw [Nat.add_zero]"
      (← lineAfterExact offside "theorem convSemicolon (a : Nat) : a + 0 = a := by" 2)
  ensureEq "a single conv tactic stays on the => line" 1
      (countExact offside
        "theorem convSingle (a : Nat) : a + 0 = a := by conv => rw [Nat.add_zero]")
  ensureEq "a nested conv carrier's sequence opens on its own line" 1
      (countExact offside "    conv =>")
  ensureEq "  ... and its list indents one level further" 1
      (countExact offside "      lhs; rw [Nat.add_zero]")
  -- The other half of that rule: `sepByIndent.formatter` emits a forced `align` when the source spelled
  -- the separators as line breaks, which already positions the sequence.
  ensureEq "a line-break-separated record update keeps its own alignment" "    first := 1"
      (← lineAfterExact offside "def relaid (base : Packet) : Packet :=" 2)
  ensureEq "  ... with its siblings at that same column and no blank line above them" 2
      (countAny offside ["    second := 2", "    third := 3"])
  -- A guarded `let`'s siblings are the offside constraint's own job: native layout reparents them
  -- *into* the guard, where they would run conditionally.
  ensureEq "a guarded let's bail-out stays on the bar's line" 1
      (countExact offside "    let some current := value | return 0")
  ensureEq "  ... and its siblings stay at the owning indentation"
      "    let doubled := current + current\n    return doubled + 1"
      (← linesAfter offside "let some current := value |" 2)
  ensureEq "two guards in one sequence each join their own bail-out" 2
      (countAny offside
        ["    let some first := left | return 0", "    let some second := right | return first"])
  -- An arrow guard parses through `doPatDecl`, which wraps the bar one `null` deeper; the
  -- bail-out's interpolated string is a protected island the toolchain's formatter drops from
  -- the document. Both halves are `Mathlib/Tactic/Simproc/VecPerm.lean`'s `0/2` refusal: the
  -- island glued anywhere but to `throwError` leaves no node for the flatten or the constraint.
  ensureEq "an arrow guard's interpolated bail-out joins its bar" 1
      (countExact offside "  let some current ← pure value | Lean.throwError m!\"missing {value}\"")
  ensureEq "  ... and the continuation still stays at the owning indentation" "  return current"
      (← lineAfter offside "Lean.throwError m!")
  -- The join has to survive a bail-out long enough to break: flattening the joined span leaves no
  -- break there to land wrong. §1b renders this same fixture at 20 and 40.
  ensureEq "a bail-out long enough to break still joins the bar" 1
      (countExact offside
        "    let some measured := value | return (Array.replicate 12 0).size + Array.size #[1, 2, 3]")
  -- The closing-brace rule. A comment forces the brace onto its own row; the source's brace was
  -- not at the field column, so the candidate's dedents to the collection's line -- the field
  -- column is the one position that would spell a `sepByIndent` continuation the source did not
  -- have. Both comment fixtures render this, `MathlibTest/Spread.lean`'s refusal.
  ensureEq "a comment-forced closing brace dedents to the collection's line" 2
      (countExact offside "  }")
  -- The mirror: a source brace alone at the field column carries the continuation slot, so the
  -- fields break onto their own rows and the brace lands at that same nest -- equal by
  -- construction, `Mathlib/Algebra/Category/AlgCat/Limits.lean`'s refusal.
  ensureEq "a field-column brace keeps the fields on their own rows" "    retries := 3"
      (← lineAfterExact offside "def rebuiltConfig (config : Config) : Config :=" 2)
  ensureEq "  ... and the brace lands at the fields' own column" 1 (countExact offside "    }")
  -- The negative half: the document hugs the brace, and a source that hugged it stays hugged.
  ensureEq "a hugged closing brace stays hugged" 1
      (countExact offside "  { baseConfig with retries := 5 }")
  -- The `where` field list rides the generic anchor (LAY-INDENTED-SEQUENCES): the first field of
  -- a `;`-separated list joins the `where` row and the later field breaks at its column -- the
  -- positioning the retired carve-out forced a break for, now stated without a break decision.
  ensureEq "a ;-separated where field list hugs the where row" 1
      (countExact offside "def semiOps : SemiOps where toFun := id;")
  ensureEq "  ... and the later field lands at the first field's column" 1
      (countExact offside
        "                            map_mul' x y := (x * y) + (y * x) + (x * y * x) + (y * x * y)")
  ensureEq "  ... while a flat source keeps the join" 1
      (countExact offside "def semiOpsFlat : SemiOps where toFun := id; map_mul' := Nat.add")
  -- A `have` whose body sits left of the keyword keeps no pin: the keyword's own formatter
  -- dedents the body two under the keyword, which stays at-or-left-of the keyword wherever the
  -- keyword lands -- the absolute pin's crossing was `Logic/Function/Basic.lean`'s refusal.
  ensureEq "a have body left of the keyword follows the keyword's dedent"
      "      have h : someLongVariableName = someLongVariableName := rfl\n      h⟩"
      (← linesAfter offside "(rfl : someLongVariableName = someLongVariableName) ▸" 2)
  -- The join is collected only where the source already spelled the bail-out on one line.
  ensureEq "a bail-out the source spelled on several lines keeps its break"
      "      let fallback := 3" (← lineAfterExact offside "    let some measured := value |")
  ensureEq "  ... and the only bars left bare are the two negative halves" 2
      ((offside.splitOn "\n").filter
          (fun line => line.startsWith "    let some " && line.endsWith " |") |>.length)
  -- A brace collection's continuation row: left of the first element is what excludes the
  -- `structInst` reading of `{a, b, c}`, so indenting it makes the reparse a `choice` and the
  -- structure gate refuses. The row must come back at the column the source gave it.
  ensureEq "a brace collection's continuation row keeps its source column" "  fourthCollected}"
      (← lineAfterExact offside "  {firstCollected, secondCollected, thirdCollected,")
  -- A two-statement bail-out falsifies the one-line precondition (`doSeqIndent`'s formatter emits
  -- the inter-item break as a leaf flattening cannot remove): the join is not collected, and the
  -- guard keeps the upstream break after the bar, both statements at one column under it.
  ensureEq "a two-statement bail-out is not joined onto the bar's line"
      "      dbg_trace \"missing\";\n      return 0"
      (← linesAfterExact offside "    let some current := value |" 2)
  -- A nested command starts at column zero, whatever the embedding node's `nest` chose.
  ensureEq "a command nested in another command starts at column zero" 1
      (countExact offside "#eval 1 + 2")
  ensureEq "  ... and the enclosing command keeps its own line" 3
      (countExact offside "#guard_msgs in")
  ensureEq "  ... and one Lean already dedented is spelled the same way" 1
      (countExact offside "def afterOpen : Nat :=")
  -- The same dedent with a comment in the gap. Both columns are asserted.
  ensureEq "  ... and a comment in the gap keeps its own column zero" 1
      (countExact offside "-- the comment the dedent has to survive")
  ensureEq "  ... and the command after that comment starts at column zero too" 1
      (countExact offside "#eval 3 + 4")
  -- The rows *after* the one the boundary opened. Asserted at the exact column, because the
  -- defect is a column and the output parses either way.
  ensureEq "  ... and the nested command's own body lands one level in, not two" 1
      (countExact offside "  refine ⟨rfl, ?_⟩")
  -- The `then` line ends at `then`.
  ensureEq "a do-block's indented if body leaves nothing after then" 1
      (countExact offside "    if value != 0 then")
  ensureEq "  ... and the body is still indented under it" 1
      (countExact offside "      total := total + value")
  -- An interior doc comment keeps the side of the break the source put it on.
  ensureEq "an interior doc comment keeps its own line" 1
      (countExact offside "    /-- Applies the mapping to a position. -/")
  ensureEq "  ... and nothing shares the line the rec keyword ends" 1
      (countExact offside "  let rec")
  -- A tactic-level `have` spells `:= body` through `Term.letIdDecl`, not `Command.declValSimple`:
  -- the join has to name it too, or the over-measured soft `line` breaks the declaration from its
  -- `by` however short the line (`GlobalMinimalModel.lean`'s cascade).
  ensureEq "a tactic-level have keeps its `:= by` joined" 1
      (countExact offside
        "  have step : n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n ∧ n + 0 = n := by")
  -- The `letI`-family alignment is a parse constraint (`argument` is `checkColGt` against the
  -- keyword's saved column), not a style: one column right and the body is read as the value's
  -- next argument. The `columned` boundaries hold the keyword's row and the body's row at their
  -- source columns -- here the keywords at three spaces and the body aligned under them.
  ensureEq "a letI chain keeps its keyword rows at their source columns"
      "  (letI : Inhabited Nat := ⟨x⟩\n   letI : OfNat Nat x := ⟨x⟩\n   (default, 5, x))"
      (← linesAfter offside "def letChainAligned" 3)

/-- §6b: mathlib's style linters, as grammar shapes. An import row never breaks across lines; a
focusing `·` keeps its first tactic on its own row; an attribute-owned doc comment keeps the
column its fixed payload was authored to fit. -/
private def testMathlibStyle (ctx : Ctx) : IO Unit := do
  let style ← ctx.once "MathlibStyle"
  -- An import cannot be shortened, so a row too long for the width overflows whole rather than
  -- stacking `public`/`import`/the module name. Asserted again at width 20 below, where the row
  -- cannot fit at all.
  ensureEq "an import row stays one line" 1 (countExact style "public import Lean.Parser.Module")
  -- The cdot linter's shape: no line is a bare `·`.
  ensureEq "no focusing dot is isolated" 0
      ((style.splitOn "\n").filter (fun line => line.trimAscii.copy == "·") |>.length)
  ensureEq "a calc hugs its focusing dot" 1 (countExact style "  · calc")
  ensureEq "a nested focusing dot hugs twice" 1 (countExact style "  · · calc")
  ensureEq "a comment between dot and tactic keeps the tactic's row" "    calc"
      (← lineAfter style "-- a comment before the tactic")
  ensureEq "a multi-tactic sequence hugs only its first tactic" "    exact h"
      (← lineAfterExact style "  · skip")
  -- The negative half: a case arm's break is its own layout, not the dot's rule.
  ensureEq "a case arm still opens its tactic block on the next line" "    calc"
      (← lineAfterExact style "  case left =>")
  -- The term-level `·` (`Term.cdot`) is a different kind and is untouched.
  ensureEq "the term-level cdot is untouched" 1 (countExact style "  (· + ·)")
  -- A doc-bearing attribute broken in the source dedents to the `@[` column: the payload was
  -- authored to fit there and cannot shrink, so entry and closing bracket both take it.
  ensureEq "an attribute's doc comment keeps the attribute list's column" 1
      (countExact style
        "/-- The **integralization** of a commutative additive monoid: the image of the universal")
  ensureEq "  ... and the closing bracket follows it to that column" "]"
      (← lineAfter style "universal integral additive monoid under the source. -/")
  -- The hugged pair is pinned bracket-included: the previous needle ended at `-/`, which made the
  -- detached `]` invisible -- the defect shipped green. `countExact` sees the whole line.
  ensureEq "a hugged doc comment keeps the attribute's row, bracket included" 1
      (countExact style
        "@[doc_carrier /-- A short hugged doc comment keeps the attribute's own row. -/]")
  -- Chained command embeddings. Every row of the declaration is the whitespace linter's subject, so
  -- each is pinned exactly: a row indented by one space fails `countExact` where a `contains` check
  -- would pass. The body rows are pinned too -- the first fix for this straightened the boundary
  -- rows by flooring the count everywhere, which stranded each body at column zero instead.
  ensureEq "the second embedding of a chain stays at column zero"
      "set_option maxHeartbeats 400000 in" (← lineAfterExact style "set_option maxRecDepth 2000 in")
  ensureEq "  ... and so does the attribute it embeds" "@[simp]"
      (← lineAfterExact style "set_option maxHeartbeats 400000 in")
  ensureEq "  ... and the declaration under it" 1
      (countExact style "theorem chainedEmbeddings (n : Nat) : n + 0 = n :=")
  ensureEq "  ... while its body keeps the indent the enclosing command gives it" "  rfl"
      (← lineAfterExact style "theorem chainedEmbeddings (n : Nat) : n + 0 = n :=")
  ensureEq "a chain of `open`s behaves the same" "theorem chainedOpens (n : Nat) : n + 0 = n :="
      (← lineAfterExact style "open List in")
  ensureEq "  ... body included" "  rfl"
      (← lineAfterExact style "theorem chainedOpens (n : Nat) : n + 0 = n :=")
  -- The hugged pair is one decision at any width: the detachment reproduced at line-width 1000, so
  -- width must play no role in the pin either.
  let wideConfig := ctx.work / "width-1000.toml"
  writeFile wideConfig "[format]\nline-width = 1000\n"
  let wide ← formatCheck ctx "MathlibStyle" (some wideConfig) "mathlib-style at 1000"
  ensureEq "at width 1000 the hugged bracket still does not fall" 1
      (countExact wide
        "@[doc_carrier /-- A short hugged doc comment keeps the attribute's own row. -/]")
  -- Width 20: the import row still cannot break, and the dot still hugs.
  let narrowConfig := ctx.work / "width-20.toml"
  writeFile narrowConfig "[format]\nline-width = 20\n"
  let narrow ← formatCheck ctx "MathlibStyle" (some narrowConfig) "mathlib-style at 20"
  ensureEq "at width 20 the import row is still one line" 1
      (countExact narrow "public import Lean.Parser.Module")
  ensureEq "at width 20 no focusing dot is isolated" 0
      ((narrow.splitOn "\n").filter (fun line => line.trimAscii.copy == "·") |>.length)

/-- §6a: `RootedKind.lean` holds a command whose node kind names no constant, so no formatter can
be resolved for it. The file formats anyway: that one command is emitted as its own bytes and
counted, and the rest of the file is laid out. The pin is the *count* as much as the survival —
a degradation that reported nothing would be indistinguishable from a command lean-fmt formatted.

The directive half stays because it is a second route to the same outcome, and the only one a
user can reach deliberately. -/
private def testRootedKind (ctx : Ctx) : IO Unit := do
  let fixture := ctx.root / "tests" / "fixtures" / "native-layout" / "RootedKind.lean"
  let degraded ←
    expectExit 0 "RootedKind degrades rather than refusing" ctx.application
        #["format", "-", "--stdin-filename", "tests/fixtures/native-layout/RootedKind.lean",
          "--root", "."]
        (input? := some (← IO.FS.readFile fixture)) (cwd? := some ctx.root) (env :=
        #[("LEAN_FMT_PROFILE_PHASES", some "1")])
  ensureEq "the unresolvable command survives verbatim" 1
      (countExact degraded.stdout "register_label_attr leanFmtRootedKindFixture")
  ensureEq "  ... and exactly one command was emitted verbatim" 1
      (← statFrom degraded.stderr "verbatim_commands")
  -- The command before it is re-rendered, not passed through: its body moves to its own row.
  -- A degradation that took the whole file verbatim would leave the source's one-line form.
  ensureEq "the rest of the file was laid out" 1
      (countExact degraded.stdout "def beforeTheRootedCommand : Nat :=")
  let ignored :=
    (← IO.FS.readFile fixture).replace "register_label_attr"
      "-- lean-fmt: format-ignore-next\nregister_label_attr"
  let formatted ←
    expectExit 0 "RootedKind with the directive" ctx.application
        #["format", "-", "--stdin-filename", "tests/fixtures/native-layout/RootedKind.lean",
          "--root", "."]
        (input? := some ignored) (cwd? := some ctx.root)
  ensureEq "  ... and the directive it names leaves the command verbatim" 1
      (countExact formatted.stdout "register_label_attr leanFmtRootedKindFixture")

/-- §6c: the two bracketed `sepByIndentSemicolon` families hug at width 100, and at width 20 -- where
the list must break left of the column `sepByIndent`'s inner `withPosition` saved -- they admit
rather than refuse. `LAY-INDENTED-SEQUENCES` is what changed that, and the pins below are the rows
it produces. -/
private def testBracketedSequences (ctx : Ctx) : IO Unit := do
  let once ← formatCheck ctx "BracketedSequences" none "bracketed-sequences admission"
  ensureEq "a hugged conv bracket stays hugged" 1
      (countExact once
        "theorem convBracketedBreak (a : Nat) : a + 0 = a := by conv => {lhs; rw [Nat.add_zero]}")
  ensureEq "the tactic bracket hugs its opening row" 1
      (countExact once
        "theorem tacticBracketedBreak (a : Nat) : a + 0 = a := by { skip; rw [Nat.add_zero a]")
  ensureEq "  ... and its closing brace takes its own row" 1 (countExact once "}")
  let twice ←
    expectExit 0 "bracketed-sequences second pass" ctx.application
        #["format", "-", "--stdin-filename", "tests/fixtures/native-layout/BracketedSequences.lean",
          "--root", "."]
        (input? := some once) (cwd? := some ctx.root)
  ensureEq "bracketed sequences are not idempotent" once twice.stdout
  let config := ctx.work / "width-20-bracketed.toml"
  writeFile config "[format]\nline-width = 20\n"
  let result ←
    runProc ctx.application
        #["format", "--check", "--root", ".", "--json", "--no-cache", "--config", config.toString,
          "tests/fixtures/native-layout/BracketedSequences.lean"]
        (cwd? := some ctx.root)
  -- `LAY-INDENTED-SEQUENCES` turned the width-20 refusal into admission: the anchor interval over
  -- the sequence's items re-bases the `;` break to the first item's column. The pins below are the
  -- anchored rows, not the gate.
  let report ← parseJson result.stdout "bracketed-sequences at 20"
  ensureEq "bracketed sequences admit at width 20" 1 result.exitCode
  let narrow ←
    expectExit 0 "bracketed-sequences width-20 render" ctx.application
        #["format", "-", "--stdin-filename", "tests/fixtures/native-layout/BracketedSequences.lean",
          "--root", ".", "--config", config.toString, "--no-cache"]
        (input? :=
        some (← IO.FS.readFile (ctx.root / "tests/fixtures/native-layout/BracketedSequences.lean")))
        (cwd? := some ctx.root)
  ensureEq "the tactic bracket breaks its semicolon at the first item's column" 1
      (countExact narrow.stdout "    rw [Nat.add_zero")
  ensureEq "the conv bracket breaks its semicolon at the first item's column" 1
      (countExact narrow.stdout "           rw [Nat.add_zero]}")
  discard <| pure report

end NativeLayout

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  removeDirAll? (root / ".lean-fmt-cache")
  discard <|
      expectExit 0 "lake build NativeLayoutFixtures" "lake" #["build", "NativeLayoutFixtures"]
        (cwd? := some root)
  withScratchDir "native-layout" fun work => do
      let renders ← IO.mkRef (#[] : Array (String × String))
      -- Render each family once at width 100 and share the text across the content cases.
      let application := (root / ".lake" / "build" / "bin" / "lean-fmt").toString
      for fixture in NativeLayout.fixtures do
        let result ←
          expectExit 1 s!"render {fixture}" application
              #["format", "--check", "--root", ".", "--json", "--no-cache",
                s!"tests/fixtures/native-layout/{fixture}.lean"]
              (cwd? := some root)
        let report ← LeanFmt.Test.parseJson result.stdout fixture
        let some formatted :=
          (LeanFmt.Test.jsonAt? report [.field "files", .index 0, .field "formatted"]).bind
            (·.getStr?.toOption) | throw <| IO.userError s!"{fixture}: no formatted text"
        renders.modify (·.push (fixture, formatted))
      let once (fixture : String) : IO String := do
        let some (_, render) :=
          (← renders.get).find? (·.1 == fixture) | throw <| IO.userError s!"{fixture}: not rendered"
        return render
      let ctx : NativeLayout.Ctx := { root, application, work, once }
      let cases : Array Case :=
        #[{ name := "admission", run := NativeLayout.testAdmission ctx },
          { name := "idempotence", run := NativeLayout.testIdempotence ctx },
          { name := "hygiene", run := NativeLayout.testHygiene ctx },
          { name := "chains", run := NativeLayout.testChains ctx },
          { name := "alignment-payloads", run := NativeLayout.testAlignment ctx },
          { name := "boundaries-comments", run := NativeLayout.testBoundaries ctx },
          { name := "islands", run := NativeLayout.testIslands ctx },
          { name := "offside", run := NativeLayout.testOffside ctx },
          { name := "bracketed-sequences", run := NativeLayout.testBracketedSequences ctx },
          { name := "mathlib-style", run := NativeLayout.testMathlibStyle ctx },
          { name := "rooted-kind", run := NativeLayout.testRootedKind ctx }]
      runCases "native-layout" cases args
