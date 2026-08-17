module

public import Test

/-!
# The upstream-defect expiry suite

Every other suite in this package asserts that lean-fmt behaves correctly, which stays true whether
or not the toolchain defect underneath is still there. So a compensation mechanism that upstream has
made unnecessary looks exactly like one that is still load-bearing, and the reproduction recorded in
`docs/upstream-defects/` quietly becomes fiction. This suite is the other half: it asserts each
defect **still reproduces**, and fails when one stops.

That failure is the good kind. The weekly `next-toolchain` probe says something moved upstream; it
cannot say whether upstream broke us or fixed something we pay for. This suite is that
discriminator, so every message here names the mechanism to delete and the section to rewrite.

Scope is §§1-9, the pretty-printer defects, which have no other expiry signal. §§10-11 are parser
defects and the `lossless` suite's `stranded-trivia` and `verso-heading` cases already assert both
halves of each — the projection covers the byte, the independent oracle still reports it missing —
so a fix upstream already turns those red. §12 is residue: no reproduction, nothing to delete.

`tests/fixtures/upstream-defects/Probe.lean` is the reproduction, run once by `main`; this file is
the expectation. The split matters: the fixture must be runnable by hand exactly as
`docs/upstream-defects/README.md` says to run it, and only this file knows what each row costs us.

Two disciplines the assertions follow, both learned the hard way:

- **Assert the coarsest thing that still discriminates.** A reworded error message is not a fix —
  §9 records that a *partial* upstream fix turns `Unknown constant …` into `uncaught backtrack
  exception` while the defect stands. So the outcome class is the assertion, and a fragment is
  pinned only where that fragment is itself the defect: §4's lost space, §9's doubled name, §6's
  newline placement, §8's overrun.
- **Every section carries the document's controls.** Without them a preamble that stopped parsing
  would read as "still defective" forever, which is precisely the rot this suite exists to catch. A
  control failing is reported as a broken probe, in different words, and is checked first.
-/

open LeanFmt.Test

namespace UpstreamDefects

private def fixture : String :=
  "tests/fixtures/upstream-defects/Probe.lean"

private def fail {α} (message : String) : IO α :=
  throw <| IO.userError message

/-- One row of one section's table. `tag` is the outcome class the fixture prints — `OK`, `THREW`,
`PARSE-ERROR`, or §8's `OVERRUN`/`WITHIN`.

`needle` and `absent` are the two shapes a formatter defect takes, and each has real callers: wrong
bytes present (§4's `"a""b"`, §6's missing newline) and right bytes missing (§1 deletes its
argument, and the only honest way to say so is that the argument's name does not appear). -/
private structure Probe where
  label : String
  /-- A control must keep working whatever upstream does. Its failure means the probe broke, not
  that a defect expired. -/
  control : Bool := false
  tag : String
  needle : String := ""
  absent : String := ""

/-- One file of `docs/upstream-defects/`. -/
private structure Defect where
  id : Nat
  /-- The file under `docs/upstream-defects/`, named `<NN>-<slug>.md`. -/
  file : String
  /-- The file's H1, verbatim after the `# ` prefix. Renumbering or retitling a defect is a change
  to the record this suite is anchored to, so it is asserted rather than assumed. -/
  heading : String
  probes : Array Probe
  /-- What a fix upstream lets us delete, from the section's own "would let us delete" sentence.
  This is the whole payload of a failure: without it a red suite is a puzzle. -/
  expiry : String

private def Defect.section (defect : Defect) : String :=
  s!"§{defect.id}"

/-- The sections, in the document's order. Every expectation below was written from a run of the
fixture, not from the document's tables — the tables are prose and two of them had rotted. -/
private def defects : Array Defect :=
  #[{ id := 1
      file := "01-interpolatedstr-walks-any-node.md"
      heading := "1. `interpolatedStr.formatter` walks whatever node it is handed"
      expiry :=
        "nothing. §1 records that no protection was added and none should be — two always-on gates \
        contain it. But `NativeLayoutIslands.droppedTermArgument` in \
        tests/fixtures/native-layout/Islands.lean goes vacuous, and §1's containment paragraph \
        becomes wrong."
      probes :=
        #[ -- The argument is gone from the output. Naming its absence is the only honest assertion:
          -- a substring of what remains would still match if `foo` came back beside it.
          { label := "s1-ident", tag := "OK", absent := "foo" },
          { label := "s1-num", tag := "THREW" }, { label := "s1-paren", tag := "THREW" },
          { label := "s1-app", tag := "THREW" }, { label := "s1-infix", tag := "THREW" },
          { label := "s1-anonymous", tag := "THREW" },
          -- Formats, but the `"pp3 "` atom's trailing space is lost with it.
          { label := "s1-string", tag := "OK", needle := "pp3\"x\"" },
          { label := "s1-control-paren", control := true, tag := "OK", needle := "pp4 (foo)" },
          { label := "s1-control-app", control := true, tag := "OK", needle := "pp4 (foo bar)" },
          { label := "s1-control-string", control := true, tag := "OK", needle := "pp4 \"x\"" },
          -- The same two failures on real core parsers, which is what makes §1 more than a
          -- curiosity about a probe syntax.
          { label := "s1-throwerror-ident", tag := "OK", absent := "err" },
          { label := "s1-throwerror-string", tag := "OK", needle := "throwError\"boom\"" },
          { label := "s1-throwerror-paren", tag := "THREW" },
          { label := "s1-trace-paren", tag := "THREW" },
          { label := "s1-trace-app", tag := "THREW" },
          { label := "s1-trace-interpolated", tag := "THREW" }] },
    { id := 2
      file := "02-parserofstack-off-by-one.md"
      heading := "2. `parserOfStack.formatter` reads one slot short — and `conv` is the loud case"
      expiry :=
        "no explicit deletion is recorded. Dynamic quotations are protected as exact islands \
        (`dynamicQuotationKind` in LeanFmt/Formatter/NativeLayout.lean) and a fix makes that \
        protection reviewable rather than obviously dead — §2 says the degradations that do reach \
        the ledger are the ones the islands do not cover. Read the section before deleting."
      probes :=
        #[ -- `term` and `tactic` have dedicated quotation parsers; everything else goes through
          -- `dynamicQuot`. The controls are the two that do not.
          { label := "s2-control-term", control := true, tag := "OK", needle := "`(1 + 1)" },
          { label := "s2-control-tactic", control := true, tag := "OK",
            needle := "`(tactic| skip)" },
          -- Two spellings of one defect. §2 records that why `conv` throws the backtrack rather
          -- than `Unknown constant «|»` was never established, so neither message is pinned.
          { label := "s2-conv", tag := "THREW" }, { label := "s2-doelem", tag := "THREW" },
          { label := "s2-command", tag := "THREW" },
          { label := "s2-macro-conv", tag := "THREW" }] },
    { id := 3
      file := "03-positional-capture.md"
      heading := "3. A `%$` positional capture makes any quotation unformattable"
      expiry :=
        "`tokenSlotCapture` in LeanFmt/Formatter/NativeLayout.lean, the `tokenCapture` and \
        `tokenCaptureInSplice` declarations in tests/fixtures/native-layout/Islands.lean, and \
        their assertions in tests/Suites/NativeLayout.lean."
      probes :=
        #[{ label := "s3-control-plain", control := true, tag := "OK" },
          { label := "s3-capture", tag := "THREW" },
          { label := "s3-control-optional", control := true, tag := "OK" },
          { label := "s3-capture-in-splice", tag := "THREW" },
          { label := "s3-capture-keyword", tag := "THREW" },
          { label := "s3-capture-quotation", tag := "THREW" },
          -- A bare term quotation: one capture, no macro, no optional splice, no tactic.
          { label := "s3-capture-term", tag := "THREW" },
          { label := "s3-control-bare", control := true, tag := "OK", needle := "exact trivial" },
          -- Outside every quotation the backtrack does not escape: a surrounding combinator
          -- absorbs it and the whole tactic block is deleted instead. Same mechanism, and the
          -- consequence §1 is singled out for. `docs/upstream-defects/03-positional-capture.md`
          -- said this row refuses; it does not, and the file now records the correction.
          { label := "s3-capture-bare", tag := "OK", absent := "trivial" }] },
    { id := 4
      file := "04-forgotten-separators.md"
      heading := "4. Two forgotten separators in `src/Lean/Parser/Syntax.lean`"
      expiry := "`collectForgottenSpaceRuns` in LeanFmt/Formatter/NativeLayout.lean."
      probes :=
        #[ -- §4a: `optKind` spells `":="` where every sibling spells `" := "`.
          { label := "s4-optkind", tag := "OK", needle := "(kind:=spcat)" },
          { label := "s4-control-behavior", control := true, tag := "OK",
            needle := "(behavior := symbol)" },
          { label := "s4-control-name", control := true, tag := "OK", needle := "(name := nm1)" },
          -- The outer element list in `«syntax»` is right, which is what makes the five below a
          -- forgotten `ppSpace` rather than a policy.
          { label := "s4-control-outer-list", control := true, tag := "OK",
            needle := "\"t6\" \"a\" \"b\"" },
          -- §4b: five nested element lists, plus `syntaxAbbrev`, all spelling `many1
          -- syntaxParser` with no `ppSpace`.
          { label := "s4-paren", tag := "OK", needle := "(\"a\"\"b\")" },
          { label := "s4-optional", tag := "OK", needle := "optional(\"a\"\"b\")" },
          { label := "s4-andthen", tag := "OK", needle := "andthen(\"a\"\"b\", \"c\"\"d\")" },
          { label := "s4-sepby", tag := "OK", needle := "sepBy(\"a\"\"b\", \",\")" },
          { label := "s4-sepby1", tag := "OK", needle := "sepBy1(\"a\"\"b\", \",\")" },
          { label := "s4-abbrev", tag := "OK", needle := ":= \"a\"\"b\"" }] },
    { id := 5
      file := "05-sepbyindent-drops-splice.md"
      heading := "5. `sepByIndent.formatter` drops the antiquotation splice its own parser adds"
      expiry :=
        "the `sepBy` clause of the antiquotation-splice island protection in \
        LeanFmt/Formatter/NativeLayout.lean. §5 records why the base test is the whole \
        discriminator: `sepBy` is protected because a `sepBy` splice cannot be told apart from \
        `sepByIndent`'s, and a fix removes that."
      probes :=
        #[ -- The thrown names are node kinds, not prose, and each names the wrapper the formatter
          -- failed to reproduce. Pinning them is pinning the defect, not its wording.
          { label := "s5-splice-scope", tag := "THREW", needle := "sepBy.antiquot_scope" },
          { label := "s5-splice-suffix", tag := "THREW", needle := "sepBy.antiquot_suffix_splice" },
          -- `p3` and `p4` share the `sepBy` base and go through the derived formatter, so they
          -- isolate `sepByIndent`'s hand-rolled override rather than the splice.
          { label := "s5-control-sepby-scope", control := true, tag := "OK",
            needle := "#[$[$xs],*]" },
          { label := "s5-control-sepby-suffix", control := true, tag := "OK",
            needle := "#[$xs,*]" },
          { label := "s5-control-many", control := true, tag := "OK" },
          { label := "s5-control-optional", control := true, tag := "OK" }] },
    { id := 6
      file := "06-ctor-docstring-newline.md"
      heading := "6. `ctor` puts the newline after the docstring it should precede"
      expiry :=
        "`ctorDocComment?` and `collectCtorDocStarts` plus the matching offside constraint in \
        LeanFmt/Formatter/NativeLayout.lean, which elide the first of the two newlines and cancel \
        the dedent over the docstring's range."
      probes :=
        #[ -- The docstring lands against the `where` it should sit below, and the newline that
          -- should have preceded it follows it instead.
          { label := "s6-first-constructor", tag := "OK", needle := "where/-- the doc -/" },
          { label := "s6-later-constructor", tag := "OK", needle := ": Bar/-- second's doc -/" },
          -- A structure field's docstring is laid out correctly, so this is `ctor`'s composition
          -- rather than doc comments generally.
          { label := "s6-control-structure-field", control := true, tag := "OK",
            needle := "where\\n  /-- the field -/" },
          -- Narrow enough that the docstring's own group breaks, and the category formatter's
          -- dedent then puts the continuation at column zero.
          { label := "s6-narrow", tag := "OK", needle := "/--\\nthe doc -/" }] },
    { id := 7
      file := "07-guardmsgs-missing-dedent.md"
      heading := "7. `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has"
      expiry :=
        "the `dedented` boundary keyed on the live `command` category in \
        LeanFmt/Formatter/NativeLayout.lean — keyed on the category rather than on a list of the \
        parsers that forgot, which is why a fix retires the whole boundary and not an entry."
      probes :=
        #[{ label := "s7-guard-msgs", tag := "OK", needle := "in\\n  example" },
          { label := "s7-guard-panic", tag := "OK", needle := "in\\n  example" },
          -- `set_option … in` carries the `ppDedent`, so its embedded command starts at column
          -- zero where the two above are indented one level.
          { label := "s7-control-set-option", control := true, tag := "OK",
            needle := "in\\nexample" }] },
    { id := 8
      file := "08-category-nest-accumulates.md"
      heading := "8. The category formatter's `nest` accumulates once per link of an operator chain"
      expiry :=
        "`LAY-CHAIN-COMPENSATION` in LeanFmt/Formatter/NativeLayout.lean, \
        tests/fixtures/native-layout/Chains.lean and its assertions in \
        tests/Suites/NativeLayout.lean. §8 warns that fixing this upstream moves the layout of \
        every construct in the language, so it is a change to propose on its own evidence."
      probes :=
        #[ -- The tag, not the table. §8's indent figures depend on operand width and are marked
          -- re-fit-before-you-quote; what does not move is that the engine returned a row wider
          -- than the width it was asked for. The operand count is a knob, the overrun is the
          -- assertion.
          { label := "s8-control-short-chain", control := true, tag := "WITHIN" },
          { label := "s8-long-chain", tag := "OVERRUN" }] },
    { id := 9
      file := "09-rooted-node-kind.md"
      heading := "9. Four toolchain parsers declare a node kind that names no constant"
      expiry :=
        "`rootedKind?` and `formatCommandForKind` in LeanFmt/Formatter/NativeLayout.lean, \
        tests/fixtures/native-layout/RootedKind.lean and its assertions in \
        tests/Suites/NativeLayout.lean."
      probes :=
        #[ -- `_root_` in the middle of a node kind is the defect itself: the parser constant
          -- honours `_root_`, the node kind does not. §9 notes a partial fix would change the
          -- message while leaving the defect, so the doubled name is what is pinned, not the
          -- wording around it.
          { label := "s9-label-attr", tag := "THREW", needle := "_root_" },
          { label := "s9-simp-attr", tag := "THREW", needle := "_root_" },
          { label := "s9-grind-attr", tag := "THREW", needle := "_root_" },
          { label := "s9-control", control := true, tag := "OK" }] }]

private structure Ctx where
  root : System.FilePath
  /-- `(label, tag, detail)` for every row the fixture printed. -/
  observed : Array (String × String × String)

/-- Check one row, reporting a control's failure as a broken probe and a defect row's failure as an
expiry with the mechanism named. -/
private def verify (ctx : Ctx) (defect : Defect) (probe : Probe) : IO Unit := do
  let some (_, tag, detail) := ctx.observed.find? (·.1 == probe.label)
    |
    fail
        s!"{fixture} printed no row labelled {repr probe.label}. The fixture and this suite have \
      drifted apart; they are edited together."
  let complaint : Option String :=
    if tag != probe.tag then some s!"expected {probe.tag}, observed {tag} {detail}"
    else
      if probe.needle != "" && !detail.contains probe.needle then
        some s!"the output no longer contains {repr probe.needle}: {detail}"
      else
        if probe.absent != "" && detail.contains probe.absent then
          some s!"the output now contains {repr probe.absent}, which the defect deletes: {detail}"
        else none
  match complaint with
  | none =>
    return ()
  | some complaint =>
    if probe.control then
      fail
          s!"the {defect.section} probe is broken, not upstream: its control {probe.label} \
        {complaint}.\nFix {fixture} before reading anything into the other rows of this section."
    else
      fail
          s!"{defect.section} no longer reproduces at {probe.label}: {complaint}.\n  \
        {defect.heading}\nIf upstream fixed it, delete: {defect.expiry}"

/-- Controls first: a broken probe environment must never be read as a defect that persists. -/
private def testDefect (ctx : Ctx) (defect : Defect) : IO Unit := do
  for probe in defect.probes do
    if probe.control then
      verify ctx defect probe
  for probe in defect.probes do
    unless probe.control do
      verify ctx defect probe

/-- The suite is anchored to `docs/upstream-defects/` at one end and to the fixture at the other,
so both anchors are asserted. A renumbered or retitled defect is a one-line fix here; a *new* file
is a decision about whether it gets a probe, and the count is what forces it to be made. A
row added to the fixture and not claimed here would simply never be asserted, which is the quiet
failure this whole suite exists to rule out. -/
private def testRecordMatchesSuite (ctx : Ctx) : IO Unit := do
  let claimed := defects.flatMap (·.probes.map (·.label))
  for (label, _, _) in ctx.observed do
    ensure (claimed.contains label)
        s!"{fixture} prints a row labelled {repr label} that no section here claims, so nothing \
      asserts it. Add it to the section it belongs to, or delete the row."
  let dir := ctx.root / "docs" / "upstream-defects"
  for defect in defects do
    ensure (defect.heading.startsWith s!"{defect.id}. ")
        s!"{defect.section}'s heading in this suite does not begin with its own number: \
      {defect.heading}"
    let path := dir / defect.file
    ensure (← path.pathExists)
        s!"docs/upstream-defects/{defect.file} does not exist. {defect.section}'s probes are \
      pointed at a record that is not there."
    let lines := (← IO.FS.readFile path).splitOn "\n"
    ensure (lines.contains ("# " ++ defect.heading))
        s!"docs/upstream-defects/{defect.file} no longer carries this heading verbatim:\n  \
      # {defect.heading}\nIf the defect was only retitled, copy the new heading here. If it was \
      renumbered or removed, {defect.section}'s probes are pointed at the wrong record."
  let numbered :=
    (← dir.readDir).filter fun entry =>
      let name := entry.fileName
      name.endsWith ".md" && name.length > 3 && (name.toList.take 2).all Char.isDigit
  ensureEq
      "docs/upstream-defects/ gained or lost a numbered file; decide whether it needs a probe \
    here, then update this count"
      12 numbered.size

private def cases (ctx : Ctx) : Array Case :=
  (defects.map fun defect => { name := s!"s{defect.id}", run := testDefect ctx defect }).push
    { name := "record-matches-suite", run := testRecordMatchesSuite ctx }

end UpstreamDefects

public def main (args : List String) : IO UInt32 := do
  let root ← repoRoot
  -- One run for every case: the fixture imports `Lean`, and nine startups to answer nine questions
  -- about one program would be nine times the cost for none of the information.
  let result ←
    expectExit 0 "lake env lean (the upstream-defect probe)" "lake"
        #["env", "lean", UpstreamDefects.fixture] (cwd? := some root)
  let observed :=
    (result.stdout.splitOn "\n").filterMap fun line =>
      match line.splitOn " " with
      | "PROBE" :: label :: tag :: detail => some (label, tag, " ".intercalate detail)
      | _ => none
  ensure (!observed.isEmpty)
      s!"{UpstreamDefects.fixture} printed no rows at all:\n{result.stdout}\n{result.stderr}"
  LeanFmt.Test.runCases "upstream-defects"
      (UpstreamDefects.cases { root, observed := observed.toArray }) args
