# Lean's pretty-printer is a printer, not a re-printer

Rules for the layout adapter. The root `AGENTS.md` owns the product constraints, and nothing here contradicts it.

Lean ships both endpoints of the layout/fidelity axis and nothing in between. `Lean.Syntax.reprint`
(`Lean/Syntax.lean`) emits `lead ++ val ++ trail` from each leaf's `SourceInfo`: exact source bytes, zero layout
decisions. `Lean.PrettyPrinter` renders syntax the *elaborator* produced, for error messages, `#print`, and infoview
hovers: every layout decision, no source fidelity — there is no original to be faithful to and nobody can diff the
output against source.

A formatter is the missing third row: full layout *and* exact fidelity. `NativeLayout.lean` is that row written out by
hand, and most difficulty in it is a guarantee a printer has no reason to make. Each one already costs a mechanism
there. Before adding a new mechanism, decide which of these you are paying for; if it is none of them, you have found a
ninth and it goes in this list.

- **It can silently drop a leaf.** The combinators backtrack, so a subtree the formatter cannot format is omitted rather
  than reported. `dbg_trace s!"…"` with the interpolated string replaced by a marker formats to
  `grp[nest2[T"dbg_trace"]]` — no marker, no `line`, no diagnostic. A missing marker in the native document is expected;
  the adapter owns what surrounds a dropped island, including the separator, because the document holds no decision
  about a leaf it never emitted.
- **Failure is unstructured when it does escape.** The same mismatch inside `` `(…) `` surfaces as the bare string
  `uncaught backtrack exception`: no node, no range, no expected shape.
- **There is no leaf-to-source correspondence.** `withMaybeTag` tags with `getExprPos?`, populated for delaborated
  syntax and not for syntax parsed from source, so a parsed command yields zero `Format.tag` nodes. Correspondence is
  positional; a divergence is a refusal, not a lookup.
- **Parser-significant columns are not in the document.** See the `align`/`sepByIndent` note in `NativeLayout.lean`'s
  module docstring.
- **A parser-significant column cannot be expressed even where it is known.** The note above says the document does not
  say which columns matter; this one says knowing one does not help. `nest n` is relative to the current *indent* and
  `align force` pads *to* that indent, so no constructor means "indent this subtree's continuations to the column where
  it starts" — which is what `many1Indent` saves and `checkColGe` measures against. A break that has to land at such a
  column cannot be *placed*, so `collectGuardBailouts`/`flattenNative` *remove* it instead, under a source precondition
  that makes removal total. Refuse rather than emit a break you cannot position.
- **Comments are not in the algebra**, there is **no verbatim leaf** (`Format.text` re-indents embedded newlines), and
  there is **no protocol for source-sensitive syntax** — hence trivia stripping, the cancelling `nest`, and marker
  substitution respectively.
- **Output nobody can see is not output to a printer.** A `line` in front of a `text` carrying its own newline is a
  space at the end of a line when its group flattens and a blank line when it does not. Lean's `doIf` spells one before
  every indented `doSeq` body. It costs a printer nothing — a trailing space is invisible in an error message and a
  re-print is never diffed against source — so nothing upstream removes it and no gate here would catch it: the
  validator reparses, and a space before a newline changes no token. A formatter's output is read as text, so the
  adapter drops the break, and only the one *in front of* the newline. The mirror rule moves columns: `sepByIndent`
  spells its first item after an `align` and the rest after a `text "\n"`.
- Ordinary upstream bugs, each repaired against the mechanism rather than the parser: `def ctor` puts the newline inside
  the `"\n| "` atom *after* `optional docComment`, so a constructor docstring renders as `where/-- doc -/` followed by a
  blank line, and at a narrow width its continuation lands at column zero (it still reparses onto the same constructor —
  measured, see `docs/upstream-defects/06-ctor-docstring-newline.md`); `parserOfStack.formatter` reads one stack slot short of the `ident`, so `` `(cat| body) `` dies
  as ``Unknown constant «|»``; `guardMsgsCmd` omits the `ppDedent` every other command-embedding parser has;
  `tokenWithAntiquot.formatter` answers a `tok%$x` capture with `visitArgs`, which runs the *token* formatter on the
  node's last child — the antiquotation expression — so every atom in the grammar can carry a backtrack, quotation or
  not. That last one is the only repair whose position admits no marker. Every other protection replaces a node in a
  syntax *category* position, which accepts any leaf; a `token_antiquot` stands where an atom of one spelling does, so
  an in-place marker reproduces the original failure byte for byte and protection escalates to the enclosing node
  instead. Ask which kind of slot you are in before adding a protection — the four older ones assume a category slot
  without saying so.

Do not reimplement what Lean does do. `pushToken` inserts a discretionary space exactly when concatenation would re-lex
as one token, using the real tokenizer; an adapter-side merge rule over-fires. Read `format.indent` through
`Lean.Std.Format.getIndent`, never as a literal `2`. And `reprint` handles `choice` by reprinting every alternative and
checking they agree. Four walks in `NativeLayout.lean` take `children[0]?` and would each *assume* it — `terminalsFrom`,
`selectedLeafRanges`, `containsAtom`, `collectRecordUpdateFieldStarts` — so one gate at `NativeLayout.command` compares
every alternative's ordered `(range, sourceSpelling)` sequence and refuses with the node and range named, making the
assumption true for all four rather than repeating the comparison. Do the same for a fifth walk: verify once at the
entry point, not per walk. The handwritten `Formatter.Command` header path still assumes, and is the remaining place it
is unchecked.
