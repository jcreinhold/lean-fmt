#!/usr/bin/env bash
set -euo pipefail

# Does the printer's skeleton lose bytes on real parser output?
#
# `RLF-COMMANDS` puts every syntax kind on the conservative path first: a command prints as the bytes
# it was written as until a canonical layout for its kind is cited and pinned. So today
# `Printer.format` is the identity on accepted source, and that is exactly what makes this test worth
# having *now* rather than later. Three places in the skeleton can silently eat a byte — the header
# split at `headerStop`, the command extents tiling `[headerStop, terminalStop)`, and the
# uninterpreted tail from `terminalStop` — and each is checked here against code nobody wrote to suit
# the printer. Every canonical layout that lands later is a change against a skeleton already known to
# be lossless.
#
# `printer-roundtrip` checks the identity at six margins including 0, and checks the extent tiling
# directly rather than inferring it from the bytes: a command dropped whose bytes were absorbed into
# its neighbour's extent would reproduce the source perfectly.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
application=$(lake -q query lean-fmt --text)
tests=$(lake -q query lean-fmt-tests --text)

failures=0
total_commands=0
total_canonical=0
total_header_canonical=0
total_members=0

# One `key=value` out of a report line. Whole-token matching, because the report has both `canonical`
# and `header_canonical` in it and a `.*canonical=` pattern reads the wrong one.
field() {
  printf '%s' "$2" | tr ' ' '\n' | sed -n "s/^$1=\([0-9]*\)$/\1/p"
}

check_module() {
  local module=$1
  LEAN_NUM_THREADS=1 lake setup-file "$module" >"$work/setup.json"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/setup.json" "$module" "$module" 8589934592 >"$work/envelope.json"
  printf '%-34s ' "$module"
  local report
  if ! report=$("$tests" printer-roundtrip "$work/envelope.json" "$module" 2>&1); then
    printf 'FAIL %s\n' "$report" >&2
    failures=$((failures + 1))
    return
  fi
  printf '%s\n' "$report"
  total_commands=$((total_commands + $(field commands "$report")))
  total_canonical=$((total_canonical + $(field canonical "$report")))
  total_header_canonical=$((total_header_canonical + $(field header_canonical "$report")))
  total_members=$((total_members + $(field members "$report")))
}

for module in $(find LeanFmt -name '*.lean' | LC_ALL=C sort) Main.lean; do
  check_module "$module"
done

modules_checked=$(( $(find LeanFmt -name '*.lean' | wc -l | tr -d ' ') + 1 ))
printf -- '--- corpus ---\n'
printf 'modules_checked=%s commands=%s canonical=%s headers_canonical=%s members=%s failures=%s\n' \
  "$modules_checked" "$total_commands" "$total_canonical" "$total_header_canonical" \
  "$total_members" "$failures"

# Exact, not a floor: a module has exactly one header, every module here has one, and the layout is
# written to decline *per group and per gap* rather than per header — so there is no shape of header in
# this repository it should refuse outright. A refusal is a claim that the header parse and the
# projection disagree about what this file is, which is worth failing over rather than tracking as a
# statistic.
if [[ "$total_header_canonical" -ne "$modules_checked" ]]; then
  printf 'FAIL only %s of %s headers took the canonical layout; the header layout is not running\n' \
    "$total_header_canonical" "$modules_checked" >&2
  failures=$((failures + 1))
fi

# The number byte identity cannot see.
#
# Every module above round-trips exactly, and would still round-trip exactly if every guard in
# `canonical?` refused every command — the printer would fall back to bytes and be the identity
# function, which is what it was before any layout existed. This repository also happens to write its
# declarations the way the layout writes them, so even a layout that *ran* changes nothing here. So
# the corpus can report `failures=0` while proving nothing about any layout at all.
#
# `canonical` is the printer counting the commands it actually laid out. A floor rather than an exact
# count: it tracks the corpus as the project grows, and only a guard that stopped firing drives it
# down. The golden fixture below is what pins *what* the layouts produce; this pins *that* they run,
# on real code, at scale.
if [[ "$total_canonical" -lt 350 ]]; then
  printf 'FAIL only %s of %s commands took a canonical layout; the layouts are not running\n' \
    "$total_canonical" "$total_commands" >&2
  failures=$((failures + 1))
fi

# `members` is the same assertion one level down, and it needs its own floor because `canonical` cannot
# see it: a command counts once whether it claimed one region or six, so every member claim could
# vanish and `canonical` would not move. It is also the *only* assertion the corpus can make about the
# member layout — `evidence/01-projection-shape.txt` measures that no constructor or field in this
# repository holds collapsible slack, so laying them out reproduces their bytes exactly and the
# round-trip is blind to it. The wonky fixture below is what pins that it changes anything at all.
if [[ "$total_members" -lt 50 ]]; then
  printf 'FAIL only %s member shells were claimed; the ctor/field layout is not running\n' \
    "$total_members" >&2
  failures=$((failures + 1))
fi

# A corpus whose modules all projected to zero commands would pass every assertion above while
# testing nothing. A floor rather than an exact count: it rises as the project grows, and only a
# broken walk drives it toward zero.
if [[ "$total_commands" -lt 100 ]]; then
  printf 'FAIL corpus produced only %s commands; the walk is not finding them\n' "$total_commands" >&2
  failures=$((failures + 1))
fi

# --- the figures quoted in prose, and the chain that keeps them true. `RLF-FINAL`. ---
#
# The three floors above are deliberately loose so they do not move as the project grows. That is the
# right call for a floor and it leaves a real hole: this repository *is* the printer's corpus, so
# every figure describing it moves whenever `LeanFmt/` changes -- and the prompts that change
# `LeanFmt/` are not the ones that wrote the sentences quoting it. `RLF-EXTENSIONS` added
# `Tree.mayCollapse` and left `Printer.lean`, `notes/01-command-printing.md` and `state/current.md`
# claiming a node count from two prompts earlier. Nothing failed, because nothing was looking, and
# `results/01-commands.md` said so outright: "a gate that diffed the quoted figures against the
# evidence would be better and does not exist."
#
# It exists now, and it is a chain of two links, because either alone is worthless:
#
#   live printer  ->  evidence/01-projection-shape.txt  ->  the prose that quotes it
#        (here)              (check-quoted-figures.py)
#
# `check-quoted-figures.py` alone would compare prose against an evidence file that is itself stale
# whenever the probe has not been re-run -- passing while everything is wrong together. So this asserts
# the *first* link: the counts the printer just measured on the live corpus are the counts the
# committed evidence file reports. Re-run `experiments/run-projection-shape.sh` when it fires.
shape_evidence="$repo_root/docs/projects/ruff-03-language-formatting/evidence/01-projection-shape.txt"
evidence_commands=$(sed -nE 's/^# command kinds in the corpus \(([0-9]+) commands.*/\1/p' "$shape_evidence")
if [[ "$evidence_commands" != "$total_commands" ]]; then
  printf 'FAIL the shape evidence is stale: it reports %s commands, the live corpus has %s.\n' \
    "$evidence_commands" "$total_commands" >&2
  printf '     Re-run experiments/run-projection-shape.sh; every figure quoted from it is now wrong.\n' >&2
  failures=$((failures + 1))
fi

# And the second link, on the evidence this run just agreed with.
if python3 "$repo_root/experiments/check-quoted-figures.py"; then
  printf '  ok   the figures quoted in Printer.lean, notes/01 and state agree with the evidence\n'
else
  printf 'FAIL prose quotes a corpus figure the evidence does not support (see above).\n' >&2
  failures=$((failures + 1))
fi

# The corpus above is this project's own code: no custom syntax, no `#exit`, and almost no non-ASCII.
# Those are exactly the cases the roadmap's stop rules name, so they come from a generated fixture on
# the real parser, with the setup borrowed as `tests/layout/run.sh` borrows one.
printf -- '--- hostile shapes, on the real parser ---\n'
LEAN_NUM_THREADS=1 lake setup-file tests/check/Clean.lean >"$work/borrowed.setup.json"
cat >"$work/hostile.lean" <<'FIXTURE'
module

/-! A module docstring, which is a real token and not trivia. -/

-- A command whose kind this printer has never heard of. `RLF-COMMANDS` stops rather than
-- reformatting it, so it must come back byte-for-byte.
syntax "greet" ident : command
macro_rules | `(greet $x) => `(def $x : Nat := 0)

greet hello

/-- Columns are codepoints (`RLC-SPEC` §4.7), so these under-count their terminal cells by half.
Nothing here may be re-measured, re-indented, or re-wrapped. -/
def unicode : String := "日本語 🎉 café café"

def spanning : String := "a
multi-line literal whose newlines are not the formatter's to touch"

def block : Nat := /- inline -/ 3 /- block comment
spanning a newline -/

#exit
Everything from here is never parsed. It is not a token, it has no kind, and it must survive
verbatim: 日本語 🎉 def this is not real Lean at all /- unterminated
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/hostile.lean" "hostile.lean" 8589934592 \
  >"$work/hostile.json"
if ! hostile=$("$tests" printer-roundtrip "$work/hostile.json" "$work/hostile.lean" 2>&1); then
  printf 'FAIL hostile.lean %s\n' "$hostile" >&2
  failures=$((failures + 1))
else
  printf '%-34s %s\n' "hostile.lean" "$hostile"
  # Exact, because each is a separate claim:
  #   tail_bytes   the `#exit` tail is real and non-empty, so the terminal path is exercised rather
  #                than trivially zero as it is on every module of this repository.
  #   header_bytes the module header is non-empty, so the `[0, headerStop)` split is exercised too.
  tail_bytes=$(field tail_bytes "$hostile")
  header_bytes=$(field header_bytes "$hostile")
  if [[ "$tail_bytes" -lt 1 ]]; then
    printf 'FAIL the #exit tail is empty; the terminal path was not exercised\n' >&2
    failures=$((failures + 1))
  else
    printf '  ok   the #exit tail round-trips (%s bytes)\n' "$tail_bytes"
  fi
  if [[ "$header_bytes" -lt 1 ]]; then
    printf 'FAIL the module header is empty; the header split was not exercised\n' >&2
    failures=$((failures + 1))
  else
    printf '  ok   the module header round-trips (%s bytes)\n' "$header_bytes"
  fi
fi

# The module header, on a header that is not already canonical.
#
# Every header in this repository is written the way the layout writes it, so the corpus proves only
# that the layout runs (`headers_canonical` above) and loses nothing. What it *decides* needs a header
# somebody wrote badly on purpose. This is a fixture of its own rather than lines bolted onto
# `wonky.lean` below, because the header needs real imports, and an import that stops resolving should
# fail as a header problem rather than as forty lines of unrelated diff.
printf -- '--- the module header, on a header that needs canonicalizing ---\n'
cat >"$work/header.lean" <<'FIXTURE'
module
import     Lean.Data.Position


public import Lean.Data.Format

-- Which imports are load-bearing is a comment somebody wrote on purpose.
import all LeanFmt.Doc
import Lean.Data.Json
  import     Lean.Data.Name
import /- why -/ Lean.Data.Options

def probe : Nat := 0
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/header.lean" "header.lean" 8589934592 >"$work/header.json"
"$tests" printer-format "$work/header.json" "$work/header.lean" 80 >"$work/header.out"

# Each line is a separate claim:
#   `module` then a blank line   the fixture has none. The blank is the grammar's own: `header` opens
#                                with `optional (moduleTk >> ppLine >> ppLine)`
#                                (`Lean/Parser/Module/Syntax.lean:26`), and two `ppLine`s is a blank
#                                line. This is the formatter deciding vertical space for the first
#                                time — every command layout so far has only ever chosen spaces.
#   `import Lean.Data.Position`  the run of spaces collapses to one, and the two blank lines below it
#                                collapse to a single newline: one `ppLine` per import, no more.
#   `public import ...Format`    modifiers are laid out without being enumerated. `import` is
#                                `optional public >> optional meta >> "import " >> optional all >>
#                                ident` (`Module/Syntax.lean:22-25`); the layout space-separates
#                                whatever leaves are there, so `public`, `meta` and `all` need no case.
#   the comment, then a blank    UNCHANGED. A comment in the gap means the gap's bytes are not the
#                                layout's to choose, so the blank line above it and the newline below
#                                it stand exactly as written. The import *under* it is still laid out:
#                                the refusal is the gap's, not the header's. This module's own header
#                                has a comment between its imports, so an all-or-nothing rule here
#                                would have switched the layout off for the file that introduced it.
#   `import all LeanFmt.Doc`     ...which is the `all` modifier, and the proof of the previous line.
#   `  import Lean.Data.Name`    STAYS INDENTED, and its spaces still collapse. Both halves matter.
#                                `Doc.hard` emits a newline plus the current indentation and this
#                                printer never nests, so a break here would de-indent it silently —
#                                the same reason `def indented` below keeps its bytes. The gap declines
#                                and the indent survives; the *group* is unaffected and lays out
#                                anyway. That the two decide separately is the whole point of splitting
#                                them. (The same guard is what leaves `module import Foo` written on
#                                one line alone: no newline in the gap means no line start.)
#   `import /- why -/ ...`       UNCHANGED: a comment *inside* a group, where re-spacing would drop it.
#                                The group keeps its bytes, and — unlike the comment in the gap above —
#                                this is a group-level refusal, so the gaps on either side still lay
#                                out normally.
#   ORDER: Position, Format,     **never sorted.** Alphabetical would be Doc, Format, Json, Name,
#   Doc, Json, Name, Options     Options, Position — a different order in five of six positions. Import
#                                order is semantic in Lean's module system, and `RLF-COMMANDS` scopes
#                                sorting out as a separate opt-in fix, so the walk keeps source order.
cat >"$work/header.golden" <<'GOLDEN'
module

import Lean.Data.Position

public import Lean.Data.Format

-- Which imports are load-bearing is a comment somebody wrote on purpose.
import all LeanFmt.Doc
import Lean.Data.Json
  import Lean.Data.Name
import /- why -/ Lean.Data.Options

def probe : Nat := 0
GOLDEN
if diff -u "$work/header.golden" "$work/header.out" >"$work/header.diff" 2>&1; then
  printf '  ok   the header layout matches the golden file\n'
else
  printf 'FAIL the header layout does not match the golden file:\n' >&2
  cat "$work/header.diff" >&2
  failures=$((failures + 1))
fi

# ...and it must have done something, or the golden above is a copy of the input.
if diff -q "$work/header.lean" "$work/header.out" >/dev/null 2>&1; then
  printf 'FAIL the header layout changed nothing; it is not being exercised\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the header layout changed the source (%s lines rewritten)\n' \
    "$(diff "$work/header.lean" "$work/header.out" | grep -c '^<')"
fi

# The corpus above cannot test a canonical layout at all: this repository already writes
# `namespace Foo` with one space, so the layout runs and changes nothing, and `printer-roundtrip`
# passing on it says only that the formatter agrees with code already in its own house style. A
# canonical layout is only tested by source that is *not* canonical.
printf -- '--- canonicalization, on source that needs it ---\n'
cat >"$work/wonky.lean" <<'FIXTURE'
module

namespace     Alpha
def a : Nat := 0
end     Alpha

namespace Beta
end Beta

namespace /- a comment between the keyword and the name -/ Gamma
end Gamma

def     b     : Nat := 1

private def     c : Nat := 2

/-- A one-line doc comment. -/
def     d : Nat := 3

@[inline] def     e : Nat := 4

/-- A doc comment that
spans lines, and whose prose is not the formatter's to re-space. -/
def     multi : Nat := 5

section
  /-- Indented, and a line break cannot preserve that. -/
  def     indented : Nat := 6
end

section     Labeled
def     labeled : Nat := 7
end     Labeled

noncomputable     section
def     nc : Nat := 8
end

@[expose]     public     section
def     exposed : Nat := 9
end

universe     u     v

def     applied : Nat := id     7

def     multiArg : List Nat := List.replicate     3     8

def     nestedApp : Nat := id     (id     9)

def     commentedApp : Nat := id     /- why -/     10

def     brokenApp : Nat :=
  id
    11

def     insideNotation : Nat := id     12 + id     13

def     binderSpaced (  x     y  :  Nat  ) : Nat := x

def     binderTight (x :Nat) : Nat := x

def     binderImplicit {  a  :  Nat  } : Nat := a

def     binderInst [  Inhabited Nat  ] : Nat := default

def     binderCommented (  /- why -/  x  :  Nat  ) : Nat := x

def     matchAlt : Nat → Nat
  |     0     =>     1
  |     n     =>     n

def     matchAltPaired : Nat → Nat → Nat
  |     0,     m     =>     m
  |     n,     _     =>     n

def     matchAltCommented : Nat → Nat
  |     /- why -/     0     =>     1
  |     n     =>     n

def     matchAltBroken : Nat → Nat
  |     0     =>
    1
  |     n     =>     n

structure     Str     where
  field     : Nat
  private     modified     : Nat
  /-- The modifier run is a doc comment, so the shell spans a line break. -/
  documented     : Nat

class     Cls     where
  method     : Nat

structure     Ctor     where
  private     mk     ::
  payload     : Nat

inductive     Ind     where
  |     first
  | second
  |     /- why -/     third

instance     : Inhabited Ind := ⟨.first⟩

open     Alpha

open     Alpha     hiding     a

open     scoped     Alpha

open     Alpha     (a)

open     Alpha     renaming     a     →     myA
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/wonky.lean" "wonky.lean" 8589934592 >"$work/wonky.json"
"$tests" printer-format "$work/wonky.json" "$work/wonky.lean" 80 >"$work/wonky.out"

# The golden file. Each line of it is a separate claim about the layout:
#   `namespace Alpha` / `end Alpha`  the runs of spaces collapse to exactly one. This is the first
#                                    thing this formatter has ever decided.
#   `def a : Nat := 0`               already canonical, and stays byte-identical.
#   `namespace Beta` / `end Beta`    already canonical, and stays byte-identical.
#   `namespace /- ... -/ Gamma`      a comment sits between the tokens, so re-spacing would drop it.
#                                    `respaceable` refuses and the command keeps its bytes, comment
#                                    and all. This is the guard, not an accident.
#   `def b     : Nat := 1`           the declaration *shell* — the keyword and the name — is laid out,
#                                    and stops there. The five spaces before `:` survive because the
#                                    signature is a term and `RLF-EXPRESSIONS` owns it, not this
#                                    stack. A layout that claimed the whole command would have eaten
#                                    them, which is exactly the failure this split exists to prevent.
#   `private def c`                  a keyword modifier joins the flat run, one space apart.
#   `/-- ... -/` then `def d`        the doc comment is emitted verbatim and the declaration goes on
#                                    the next line. That break is the grammar's own: `docComment` ends
#                                    in `ppLine` (`Lean/Parser/Term.lean:91-93`). The source had it on
#                                    its own line already; `@[inline]` below is where the break is
#                                    visibly the formatter's doing.
#   `section Labeled` / `end Labeled`  the label is `optional`, so a section is one token or two and
#                                    `spaceSeparated` handles both without knowing which. The bare
#                                    `section` above is the one-token case, and it is byte-identical --
#                                    which is why it cannot be the only section here. These two collapse
#                                    a run of spaces and are the evidence the layout decides anything.
#   `noncomputable section`          `sectionHeader`'s keyword slots join the flat run. This is the
#                                    header shape that actually occurs in the wild.
#   `@[expose]     public     section`  the fourth header slot is bracketed, so the layout is refused
#                                    and every space survives -- including the ones a claimed section
#                                    would have collapsed. The slack is the point: it is what makes the
#                                    guard's mutation visible rather than a no-op, and `def exposed`
#                                    on the next line still gets its shell, so this is the guard
#                                    refusing one command and not the file.
#   `universe u v`                   `many1 ident` is a flat run whatever its length.
#   `id 7`                           the first *term* this formatter decides. `app` declares no atom
#                                    (`Lean/Parser/Term.lean:892`) and its `argument` opens with
#                                    `checkWsBefore` (`:885-888`), so the parser *rejects* `id7` and
#                                    one space is the grammar's minimum rather than a preference.
#   `List.replicate 3 8`             BOTH gaps collapse. `many1 argument` builds one `null` around
#                                    every argument, so reading the app's own parts would collapse
#                                    only the gap to the first one and leave `3     8` alone. This
#                                    line is the whole evidence `liftedParts` lifts the null.
#   `id (id 9)`                      the recursion. The outer app's argument is a `paren`, which has
#                                    no layout -- so its bytes are kept while the app *inside* it is
#                                    still found and still collapsed. A fallback that emitted the
#                                    paren wholesale would leave `(id     9)` and pass every other
#                                    check here.
#   `id     /- why -/     10`        a comment sits in the gap, so the space that would replace it
#                                    would delete it. `gapDoc` refuses and the app keeps its bytes.
#   `id` then `11` on two lines      the gap holds a newline. Refused, and not for tidiness:
#                                    `argument`'s `checkColGt "expected to be indented"` makes an
#                                    app's line breaks parser-significant, so joining these two lines
#                                    could move `11` to a column where it stops being an argument.
#                                    Vertical layout is not this prompt's to decide.
#   `id 12 + id 13`                  both apps collapse and the spaces around `+` do not. `+` is a
#                                    notation whose atom is declared `" + "` (`Init/Notation.lean:284`)
#                                    -- spacing this printer cannot read, so it keeps those bytes and
#                                    claims only the two apps the parser marked for it.
#   `(x y : Nat)`                    the brackets go tight and the interior gaps go to one space, and
#                                    the two halves have different citations. `explicitBinder` opens
#                                    with a **bare** `"("` (`Term/Basic.lean:206-207`) -- not `" ( "` --
#                                    so no declared space, and none from the lexical rule either since
#                                    `(x` does not re-lex as one token. The interior is `many1
#                                    binderIdent` (two idents always take a space,
#                                    `Formatter.lean:387-389`) then `binderType`, whose atom is
#                                    declared `" : "` (`:181-182`). Four spaces before `y` and two
#                                    around `:` all go to one.
#   `(x : Nat)` from `(x :Nat)`      **the layout ADDS a space** -- the first time it has. `(x :Nat)`
#                                    parses, because `" : "` is a pretty-printing string and not a
#                                    parsing one, so nothing was wrong with the input and the layout
#                                    still rewrites it. Every other line here collapses; this one is
#                                    the evidence the rule is the grammar's declared spacing and not
#                                    "squeeze runs of spaces".
#   `{a : Nat}` / `[Inhabited Nat]`  one rule, three binders, and `instBinder` is the shape that shows
#                                    it is a rule: `[` >> term >> `]` is three parts, so its single
#                                    interior gap is both the first gap and the last, and both are
#                                    tight. `Inhabited Nat` inside it is an app, found and collapsed by
#                                    the same recursion that finds it inside a `paren`.
#   `| 0 => 1`                       every gap a match alternative owns is one space, and all three
#                                    are declared: `"| "` carries a trailing space and `darrow :=
#                                    " => "` (`Term.lean:265-270`, `:99`) carries one on each side.
#                                    So `matchAlt` is `flat` for the same reason `app` is, by a
#                                    different route -- `app` has no atoms and the parser *requires*
#                                    the space; here the atoms declare it.
#   `| 0,     m => m`                the run between two patterns SURVIVES, and this is the
#                                    conservative direction rather than an oversight.
#                                    `sepBy1 (sepBy1 termParser ", ") " | "` builds **two** levels of
#                                    `null` and `liftedParts` lifts one, so the pattern run arrives as
#                                    a single opaque part and keeps its bytes. `| 0` and `=> m` around
#                                    it still collapse, which is what makes this line evidence rather
#                                    than a shrug: the alternative is laid out and the inner run is
#                                    not.
#   `|     /- why -/     0 => 1`     the per-gap refusal again, one construct further out.
#   `| 0 =>` then `    1`            the gap holds a newline, so it is refused and the indentation
#                                    survives. `matchAlt` has a live `checkColGe` and no
#                                    `withoutPosition` -- collapsing it is still safe because
#                                    `matchAlts` saves its position at the *first* `|`
#                                    (`:279-280`), at the start of a line, left of every token a
#                                    same-line collapse can move. That is the test `structInst` fails.
#
# READ THE GOLDEN BEFORE THIS COMMENT: every `matchAlt` gap above now KEEPS ITS BYTES, and the
# paragraph either side of this one describes a collapse that no longer happens. The grammar reading
# is not what changed -- `matchAlts` really does save at the first `|` and the collapse really is
# safe. `Tree.mayCollapse` cannot use that, because it is kind-free by necessity: it cannot tell
# `matchAlts` spanning lines (harmless) from a custom `withPosition(term colEq term)` spanning lines
# (a broken parse, `evidence/04-coleq-break.txt`), and every alternative in THIS fixture is inside a
# multi-line command.
#
# The entry is not dead, and `inline.lean` below proves it: alternatives written on one line still
# collapse. What the guard withdrew is "matchAlt spread across lines", not "matchAlt".
#
# It is still a real regression against `RLF-EXPRESSIONS`, taken deliberately because the alternative
# was emitting Lean this printer cannot re-read, and priced at zero on real code: `match_slack=0`
# across all 62 sample modules. Recovering the cross-line case needs a table of the cross-line kinds
# whose grammar this stack has read and cleared. `RLF-EXTENSIONS` refused to build it, on the ground
# `notes/02-expressions.md` §6 already refused the notation table: every entry is a claim about
# `Lean/Parser/Term.lean` that goes stale silently, and it would buy back a collapse that fires zero
# times on real Lean.
#   `(  /- why -/  x : Nat)`         the refusal is **the gap's alone, and the rest of the binder is
#                                    still laid out**. The comment sits in the first gap, so that gap
#                                    keeps all of its bytes -- the tight rule is precisely what would
#                                    have deleted it -- while the three gaps after it collapse
#                                    normally, `Nat  )` included. The source is written with slack in
#                                    those later gaps on purpose: with `(  /- why -/  x : Nat)` as the
#                                    input, a per-gap refusal and an all-or-nothing one produce the
#                                    same bytes and this line would pin neither. This is the header's
#                                    per-gap rule (`import` above) reaching the terms.
#   `@[inline]` then `def e`         written on ONE line in the fixture and split into two, because
#                                    `declModifiers` follows attributes with `ppDedent ppLine` unless
#                                    `inline`, and `declaration` passes `inline := false`
#                                    (`Command.lean:114-121`, `:282`). The brackets are not re-spaced:
#                                    the slot goes out verbatim, so `@[ inline ]` cannot happen.
#   `/-- multi\nline -/ def multi`   **a multi-line doc comment must still be laid out.** The token
#                                    check that would refuse it is asked only of the flat run, never
#                                    of the verbatim slots — collapsing the two into one guard here
#                                    would silently drop this declaration onto the conservative path,
#                                    and most real docstrings with it.
#   `structure Str     where`        the shell is the keyword and the name, and it stops there: the
#   `class Cls     where`            signature keeps its bytes, `where` included. `class` is a
#   `inductive Ind     where`        `«structure»` node — `classTk` is one of its two openers — so it
#                                    needs no case of its own. The name is *found* among the shape's
#                                    children rather than indexed, because `«structure»` puts
#                                    `structureTk` ahead of it while `definition` puts `declId` first.
#   `  field     : Nat`              UNCHANGED: an unmodified field is a one-token shell. There is no
#                                    gap in it to collapse, so no layout could change it, and the
#                                    printer makes no claim rather than a claim that does nothing.
#                                    `     : Nat` is `optDeclSig` — a term, and `RLF-EXPRESSIONS`'s.
#   `  private modified     : Nat`   the field's shell is its modifiers and its name, so the run
#                                    `private     modified` collapses and the signature does not.
#                                    This line is the whole reason the member layout exists: no
#                                    constructor or field in the corpus holds collapsible slack
#                                    (`evidence/01-projection-shape.txt`), so nothing but a written
#                                    fixture can show the layout changing a byte.
#   `  /-- ... -/`                   UNCHANGED, and this is a refusal, not an oversight. A
#   `  documented     : Nat`         `structSimpleBinder`'s doc comment is inside its `declModifiers`
#                                    and therefore inside the shell, so the shell spans the line break
#                                    after it. A flat run would pull the name up onto the doc
#                                    comment's line; `hard` cannot put it back, because `hard` indents
#                                    to nothing and this field is indented — and `structFields` is
#                                    `manyIndent`, so a field at column 0 would not even parse.
#                                    `flatGaps` refuses the shape. Contrast `Doc.lean`'s own
#                                    documented constructors, which are laid out: a `ctor`'s doc
#                                    comment sits under `optional`, outside the shell, and so keeps
#                                    its bytes and its break without the shell having to reproduce it.
#   `  private mk     ::`            a `structCtor`'s claim stops at the name, like every member's.
#                                    `     ::` is untouched because `many (ppSpace >>
#                                    Term.bracketedBinder)` may sit between the name and `" :: "`,
#                                    which would make the shell two runs rather than one — and a
#                                    `Claim` is one contiguous run.
#   `  | first`                      a `ctor`'s shell is `|`, its modifiers, and its name.
#   `instance     : ...`             UNCHANGED: excluded, and its grammar says why. `declId` is
#                                    optional there (anonymous instances are ordinary Lean), so the
#                                    shell would have to end at the keyword, and `optNamedPrio` is
#                                    bracketed. Two separate claims, neither made yet.
#   `open Alpha`                     three of `openDecl`'s six alternatives are flat runs of
#   `open Alpha hiding a`            identifiers and keywords (`openSimple`, `openScoped`,
#   `open scoped Alpha`              `openHiding`), so one space between tokens is their layout.
#   `open     Alpha     (a)`         UNCHANGED, and the other two say why. `openOnly` is
#   `open     Alpha  renaming ...`   `ident >> " (" >> many1 ident >> ")"`, so a flat run gives
#                                    `Alpha ( a )`; `openRenaming` is `sepBy1 openRenamingItem ", "`,
#                                    so a flat run gives `a → myA , b → myB` -- a space before the
#                                    comma. Brackets and separators need a layout that knows about
#                                    them, and this prompt has not made that claim.
#   `  def     indented`             UNCHANGED, spaces and all: it is not at column 0, and the line
#                                    break the layout would emit indents to nothing, so the docstring
#                                    would stay indented while the `def` jumped to column 0. Whether
#                                    top-level commands belong at column 0 is a language decision no
#                                    prompt here has made, so this keeps its bytes rather than guess.
cat >"$work/wonky.golden" <<'GOLDEN'
module

namespace Alpha
def a : Nat := 0
end Alpha

namespace Beta
end Beta

namespace /- a comment between the keyword and the name -/ Gamma
end Gamma

def b     : Nat := 1

private def c : Nat := 2

/-- A one-line doc comment. -/
def d : Nat := 3

@[inline]
def e : Nat := 4

/-- A doc comment that
spans lines, and whose prose is not the formatter's to re-space. -/
def multi : Nat := 5

section
  /-- Indented, and a line break cannot preserve that. -/
  def     indented : Nat := 6
end

section Labeled
def labeled : Nat := 7
end Labeled

noncomputable section
def nc : Nat := 8
end

@[expose]     public     section
def exposed : Nat := 9
end

universe u v

def applied : Nat := id 7

def multiArg : List Nat := List.replicate 3 8

def nestedApp : Nat := id (id 9)

def commentedApp : Nat := id     /- why -/     10

def brokenApp : Nat :=
  id
    11

def insideNotation : Nat := id 12 + id 13

def binderSpaced (x y : Nat) : Nat := x

def binderTight (x : Nat) : Nat := x

def binderImplicit {a : Nat} : Nat := a

def binderInst [Inhabited Nat] : Nat := default

def binderCommented (  /- why -/  x : Nat) : Nat := x

def matchAlt : Nat → Nat
  |     0     =>     1
  |     n     =>     n

def matchAltPaired : Nat → Nat → Nat
  |     0,     m     =>     m
  |     n,     _     =>     n

def matchAltCommented : Nat → Nat
  |     /- why -/     0     =>     1
  |     n     =>     n

def matchAltBroken : Nat → Nat
  |     0     =>
    1
  |     n     =>     n

structure Str     where
  field     : Nat
  private modified     : Nat
  /-- The modifier run is a doc comment, so the shell spans a line break. -/
  documented     : Nat

class Cls     where
  method     : Nat

structure Ctor     where
  private mk     ::
  payload     : Nat

inductive Ind     where
  | first
  | second
  |     /- why -/     third

instance     : Inhabited Ind := ⟨.first⟩

open Alpha

open Alpha hiding a

open scoped Alpha

open     Alpha     (a)

open     Alpha     renaming     a     →     myA
GOLDEN
if diff -u "$work/wonky.golden" "$work/wonky.out" >"$work/wonky.diff" 2>&1; then
  printf '  ok   canonical layout matches the golden file\n'
else
  printf 'FAIL canonical layout does not match the golden file:\n' >&2
  cat "$work/wonky.diff" >&2
  failures=$((failures + 1))
fi

# The layout must actually have *done* something, or the golden file above is just a copy of the
# input and pins nothing.
if diff -q "$work/wonky.lean" "$work/wonky.out" >/dev/null 2>&1; then
  printf 'FAIL the formatter changed nothing; the canonical layout is not being exercised\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the formatter changed the source (%s)\n' \
    "$(diff "$work/wonky.lean" "$work/wonky.out" | grep -c '^<') lines rewritten"
fi

# `app_slack` counts the application gaps holding more than one space, and it is reported over the
# frozen mathlib sample where the answer is **0 across all 62 modules** — real Lean does not write
# `f     a`. A counter that answered 0 because it was broken would say exactly the same thing, so it
# is validated here against a corpus whose answer is known by reading it: `id     7` is one gap,
# `List.replicate     3     8` is two, `id     (id     9)` is two (outer and inner), and
# `id     12 + id     13` is two. `commentedApp` and `brokenApp` contribute none — their gaps are not
# spaces-only, which is the same predicate the layout refuses on. Seven.
#
# This is `RLF-COMMANDS`'s lesson applied before the fact rather than after: its `misordered=0` was a
# number no input could have contradicted, and it took a mutation to notice.
expected_slack=7
actual_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" \
  | tr ' ' '\n' | sed -n 's/^app_slack=\([0-9]*\)$/\1/p')
if [[ "$actual_slack" == "$expected_slack" ]]; then
  printf '  ok   app_slack counts the fixture'\''s %s application gaps (so 0 on mathlib is a fact)\n' \
    "$expected_slack"
else
  printf 'FAIL app_slack reported %s on the wonky fixture, expected %s; the sample'\''s 0 is vacuous\n' \
    "$actual_slack" "$expected_slack" >&2
  failures=$((failures + 1))
fi

# `binder_slack` is the same measurement for the three bracketed binders, and it needs its own count
# because `app_slack` cannot see it: they are disjoint sets of nodes. It is *not* the same predicate
# either. An application's gaps are all "one space", so slack there means a run of two or more; a
# binder's declared spacing differs per gap, so this counts every gap whose bytes are not what the
# grammar declares -- which includes gaps that are **too tight**. `binderTight`'s `:Nat` is one of
# them, and it is why this cannot be a "count the long runs" check.
#
# Counted by reading the fixture. `binderSpaced (  x     y  :  Nat  )` is five: four interior gaps
# plus both brackets. `binderTight (x :Nat)` is one -- only the missing space after `:`; its other
# three gaps are already exactly right. `binderImplicit {  a  :  Nat  }` is four, `binderInst
# [  Inhabited Nat  ]` is two (`Inhabited Nat` is an app, and is `app_slack`'s to count, not this
# one's). `binderCommented` is three: its commented gap is skipped by the same spaces-only predicate
# the layout refuses on, and the three behind it still count. Fifteen.
expected_binder_slack=15
actual_binder_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" \
  | tr ' ' '\n' | sed -n 's/^binder_slack=\([0-9]*\)$/\1/p')
if [[ "$actual_binder_slack" == "$expected_binder_slack" ]]; then
  printf '  ok   binder_slack counts the fixture'\''s %s binder gaps (so 0 on mathlib is a fact)\n' \
    "$expected_binder_slack"
else
  printf 'FAIL binder_slack reported %s on the wonky fixture, expected %s; the sample'\''s count is vacuous\n' \
    "$actual_binder_slack" "$expected_binder_slack" >&2
  failures=$((failures + 1))
fi

# `match_slack`, the third of these, and the fixture is counted the same way. Each alternative owns
# exactly three gaps -- `| pat`, `pat =>`, `=> rhs` -- and each is one space when declared, so a
# five-space run in any of them is one. `matchAlt` and `matchAltPaired` are 3+3 each; the pattern run
# inside `0,     m` is NOT counted, because it is inside the `sepBy1` null and neither the layout nor
# this counter reaches it. `matchAltCommented` is 2+3 and `matchAltBroken` is 2+3: each loses exactly
# the gap whose bytes are not spaces-only -- the comment in one, the newline in the other -- which is
# the same predicate the layout refuses on. Twenty-two.
expected_match_slack=22
actual_match_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" \
  | tr ' ' '\n' | sed -n 's/^match_slack=\([0-9]*\)$/\1/p')
if [[ "$actual_match_slack" == "$expected_match_slack" ]]; then
  printf '  ok   match_slack counts the fixture'\''s %s alternative gaps (so 0 on mathlib is a fact)\n' \
    "$expected_match_slack"
else
  printf 'FAIL match_slack reported %s on the wonky fixture, expected %s; the sample'\''s count is vacuous\n' \
    "$actual_match_slack" "$expected_match_slack" >&2
  failures=$((failures + 1))
fi

# The tactic block, and the counter that decided not to lay it out.
#
# `RLF-TACTICS` found exactly one change it could make to a tactic block without moving a column:
# rewrite the newline run inside a separator gap to a single newline, re-emitting the gap's trailing
# indentation byte for byte (`notes/03-tactics.md` §8, design B). Re-indenting is not on the table --
# the column between two tactics *is* the separator (`checkColEq`, `Lean/Parser/Extra.lean:206-208`),
# and `Doc.nest` moves a printer-emitted newline but cannot move a `.keep` gap, so a partial vertical
# layout strands each tactic's continuation lines on the separator column, where they stop being
# continuations and become tactics that do not parse (§5).
#
# `tactic_blank_gaps` is the whole of what design B would have rewritten, and on the frozen sample it
# is **0, across all 62 modules and 1,966 blocks**: real Lean does not put a blank line between two
# tactics. Every blank line in that sample is followed by a column-0 line -- it *ends* an indented
# block rather than sitting inside one (`evidence/03-blank-line-columns.txt`). So design B ships
# nothing, and tactic blocks stay on the conservative path.
#
# That 0 is a fact only if the counter can count, which is what this fixture is for -- `RLF-COMMANDS`'s
# `misordered=0` was a number no input could have contradicted, and it took a mutation to notice.
# Counted by reading it: `gapOne` is one gap, `gapTwo` is two, `noGap` is none (a single newline is
# the separator, not a blank), and `gapCommented` is none -- its gap holds a comment, so it is not
# whitespace-only, which is the same predicate every other layout in this file refuses on. Three.
printf -- '--- the tactic block, and the counter that left it alone ---\n'
cat >"$work/tactic.lean" <<'FIXTURE'
module

theorem gapOne : True := by
  skip

  trivial

theorem gapTwo : True := by
  skip

  skip

  trivial

theorem noGap : True := by
  skip
  trivial

theorem gapCommented : True := by
  skip

  -- A comment is not whitespace, so these are not the formatter's bytes to choose.
  trivial

theorem nestedBlocks : True ∧ True := by
  constructor
  · skip
    trivial
  · trivial

theorem nestedOwnLine : True := by
  have h : True := by
    trivial
  exact h

theorem inlineBlock : True := by trivial
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/tactic.lean" "tactic.lean" 8589934592 >"$work/tactic.json"
tactic_report=$("$tests" printer-report "$work/tactic.json" "$work/tactic.lean")
expected_blank_gaps=3
actual_blank_gaps=$(field tactic_blank_gaps "$tactic_report")
if [[ "$actual_blank_gaps" == "$expected_blank_gaps" ]]; then
  printf '  ok   tactic_blank_gaps counts the fixture'\''s %s blank gaps (so 0 on mathlib is a fact)\n' \
    "$expected_blank_gaps"
else
  printf 'FAIL tactic_blank_gaps reported %s on the tactic fixture, expected %s; the sample'\''s 0 is vacuous\n' \
    "$actual_blank_gaps" "$expected_blank_gaps" >&2
  failures=$((failures + 1))
fi

# The blocks themselves, because `tactic_blank_gaps` cannot see them: a counter that found no blocks
# at all would report 0 gaps and look exactly like a counter that found blocks with no gaps in them.
# Exact, and countable by eye: six `by` blocks, plus three nested inside them -- one per bullet, since
# `· tac` nests a tactic sequence of its own (`Init/NotationExtra.lean:320-322`), and one for the inner
# `by` of `nestedOwnLine`'s `have`. Ten. This is also what makes `tactic_ownable`'s 1,422-of-1,966 on
# the sample a measurement rather than a guess.
expected_tactic_blocks=10
actual_tactic_blocks=$(field tactic_blocks "$tactic_report")
if [[ "$actual_tactic_blocks" == "$expected_tactic_blocks" ]]; then
  printf '  ok   tactic_blocks finds the fixture'\''s %s blocks\n' "$expected_tactic_blocks"
else
  printf 'FAIL tactic_blocks reported %s on the tactic fixture, expected %s\n' \
    "$actual_tactic_blocks" "$expected_tactic_blocks" >&2
  failures=$((failures + 1))
fi

# `ownable`, `own_line` and `at_two`: the split that retired design A. Every shape below is in the
# fixture because it lands in a different bucket, and a bucket nothing reaches is a number that cannot
# be wrong.
#
# **ownable = 8.** All ten but `nestedBlocks`' own block and `nestedOwnLine`'s own block -- each has a
# part spanning two lines (a bullet, and a `have ... := by` with its proof under it), so the printer
# cannot own their newlines (§5).
#
# **own_line = 5.** The four column-2 blocks, plus `nestedOwnLine`'s inner `trivial`. The bullets' own
# blocks are *not* here: `· skip` puts `skip` on the bullet's line, so the block begins inline even
# though it is nested. Neither is `inlineBlock` -- `by trivial` never starts a line at all.
#
# **at_two = 4.** `gapOne`, `gapTwo`, `noGap`, `gapCommented`. Design A is the identity on exactly
# these: `tactic_blank_gaps=0` says the separators are already one newline, so a block already
# beginning its line at column 2 is a block A rewrites to its own bytes.
#
# The other four are what A cannot have, and they fail in two unlike ways. `nestedOwnLine`'s inner
# block is at column 4 on its own line, so A would move it to 2 -- out of the `have` it belongs to,
# which is §5's `.keep` trap with a number on it and the prompt's own "fallback must remain
# parse-preserving" broken. The two bullets and `inlineBlock` begin inline, so A would break them onto
# a new line, which is a *wrapping* decision wanting a margin no prompt in this stack has set (§7).
# Neither is licensed, and `ownable` alone cannot tell any of the three apart -- which is what it means
# for it to be an upper bound, made countable.
expected_ownable=8
expected_own_line=5
expected_at_two=4
actual_ownable=$(field tactic_ownable "$tactic_report")
actual_own_line=$(field tactic_ownable_own_line "$tactic_report")
actual_at_two=$(field tactic_ownable_at_two "$tactic_report")
if [[ "$actual_ownable" == "$expected_ownable" && "$actual_own_line" == "$expected_own_line" &&
      "$actual_at_two" == "$expected_at_two" ]]; then
  printf '  ok   tactic_ownable=%s own_line=%s at_two=%s; all three buckets are reached\n' \
    "$expected_ownable" "$expected_own_line" "$expected_at_two"
else
  printf 'FAIL tactic_ownable=%s own_line=%s at_two=%s, expected %s, %s and %s\n' \
    "$actual_ownable" "$actual_own_line" "$actual_at_two" \
    "$expected_ownable" "$expected_own_line" "$expected_at_two" >&2
  failures=$((failures + 1))
fi

# And the decision itself: the printer does not touch a tactic block. Byte identity is a weak
# assertion everywhere else in this file -- it is what a printer that refused everything would also
# produce -- but here that is precisely the claim being pinned, and the fixture is built so it can
# fail. Every blank gap above survives, because `tactic_blank_gaps=0` on real code is what retired
# design B rather than any doubt about whether it could be written.
"$tests" printer-format "$work/tactic.json" "$work/tactic.lean" 80 >"$work/tactic.out"
if diff -u "$work/tactic.lean" "$work/tactic.out" >"$work/tactic.diff" 2>&1; then
  printf '  ok   tactic blocks come back byte-for-byte, blank gaps and all\n'
else
  printf 'FAIL the printer rewrote a tactic block; it is meant to be on the conservative path:\n' >&2
  cat "$work/tactic.diff" >&2
  failures=$((failures + 1))
fi

# --- the collapse guard, and the parse it would otherwise break ---
#
# This fixture is the one in `evidence/04-coleq-break.txt`, and before `Tree.mayCollapse` it made the
# printer emit Lean the printer could not re-read. Collapsing `(id     True)` moves `skip` four columns
# left; `trivial`, on the next line, does not move; `sepByIndent`'s separator is
# `checkColEq .. >> checkLinebreakBefore` (`Parser/Extra.lean:202-208`), so it stops matching and
# `trivial` falls out of the block and becomes a bogus command.
#
# The three declarations are one test because the guard has to be a line, not a refusal. `tA` must keep
# its bytes, and `tB` and `dC` must still collapse -- a guard that refused all three would pass a byte
# check on `tA` alone while quietly deleting the layer.
printf -- '--- the collapse guard ---\n'
cat >"$work/coleq.lean" <<'FIXTURE'
module

theorem tA : (id     True) := by skip
                                 trivial

theorem tB : (id     True) := by trivial

def dC : Nat := (id     1)

def dE : Nat := (id     1)  theorem tF : True := by skip
                                                    trivial
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/coleq.lean" "coleq.lean" 8589934592 >"$work/coleq.json"
"$tests" printer-format "$work/coleq.json" "$work/coleq.lean" 100 >"$work/coleq.out"

if grep -qF 'theorem tA : (id     True) := by skip' "$work/coleq.out"; then
  printf '  ok   the app whose collapse would move a tactic block keeps its bytes\n'
else
  printf 'FAIL tA was collapsed; its `by` block is measured from a column this moves:\n' >&2
  cat "$work/coleq.out" >&2
  failures=$((failures + 1))
fi

if grep -qF 'theorem tB : (id True) := by trivial' "$work/coleq.out" &&
   grep -qF 'def dC : Nat := (id 1)' "$work/coleq.out"; then
  printf '  ok   apps with no later line to break still collapse\n'
else
  printf 'FAIL the guard refused tB or dC; nothing on their lines is measured across a break:\n' >&2
  cat "$work/coleq.out" >&2
  failures=$((failures + 1))
fi

# `dE` is the case a command's own subtree cannot see: the block that breaks belongs to `tF`, the
# *next* command, and it is only reachable because two commands share a line. This is what the
# `crossLineStarts` sentinel is for, and this is the only test that holds it.
if grep -qF 'def dE : Nat := (id     1)  theorem tF' "$work/coleq.out"; then
  printf '  ok   an app is not collapsed under the next command on its line\n'
else
  printf 'FAIL dE collapsed; it moves tF'\''s `by` block, which is not in dE'\''s subtree:\n' >&2
  cat "$work/coleq.out" >&2
  failures=$((failures + 1))
fi

# `matchAlt` is NOT dead, and this is the fixture that says so. The golden above keeps every
# multi-line alternative's bytes, which makes it look as though `spacingOf`'s `matchAlt` entry can
# never fire -- an earlier revision of this file claimed exactly that, and it is false. Alternatives
# are legal on one line, and there `mayCollapse` is true and the layout runs. So the entry stays,
# `match_slack` stays a real counter, and what the guard withdrew is narrower than "matchAlt": it is
# "matchAlt spread across lines".
cat >"$work/inline.lean" <<'FIXTURE'
module

def inlineMatch (x : Nat) : Nat := match x with |     0     =>     1 |     n     =>     n

def inlineAlts : Nat → Nat |     0     =>     1 |     n     =>     n
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/inline.lean" "inline.lean" 8589934592 >"$work/inline.json"
"$tests" printer-format "$work/inline.json" "$work/inline.lean" 200 >"$work/inline.out"
if grep -qF 'def inlineMatch (x : Nat) : Nat := match x with | 0 => 1 | n => n' "$work/inline.out" &&
   grep -qF 'def inlineAlts : Nat → Nat | 0 => 1 | n => n' "$work/inline.out"; then
  printf '  ok   a one-line match still collapses; matchAlt is not dead code\n'
else
  printf 'FAIL a one-line match did not collapse, so spacingOf'\''s matchAlt entry is unreachable:\n' >&2
  cat "$work/inline.out" >&2
  failures=$((failures + 1))
fi

# The custom `colEq`, which is why the guard asks about the command and not about nodes. A user's
# `withPosition(term:max colEq term:max)` compiles to NO node -- the only node here opens at `tbl`,
# LEFT of the gap inside `(id     1)` -- so a census of nodes starting to the gap's right looks
# straight past it, and an earlier version of this guard did exactly that and emitted
# `expected checkColEq`. `term:max` matters twice over: without it the macro pattern's `$a $x` parses
# as one application and the quotation itself will not compile.
cat >"$work/tbl.lean" <<'FIXTURE'
module

syntax:max "tbl " term:max ppSpace withPosition(term:max colEq term:max) : term
macro_rules
  | `(tbl $a $x
             $y) => `(($a, $x, $y))

def broken : Nat × Nat × Nat := tbl (id     1) 2
                                               3
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/tbl.lean" "tbl.lean" 8589934592 >"$work/tbl.json"
"$tests" printer-format "$work/tbl.json" "$work/tbl.lean" 100 >"$work/tbl.out"
if diff -u "$work/tbl.lean" "$work/tbl.out" >"$work/tbl.diff" 2>&1; then
  printf '  ok   a custom notation with a live colEq keeps its bytes\n'
else
  printf 'FAIL the printer collapsed under a column check declared by syntax it cannot read:\n' >&2
  cat "$work/tbl.diff" >&2
  failures=$((failures + 1))
fi

# The property itself, and the only assertion here that would survive a rewrite of the rule: the
# formatter's output parses. `__analyze-exact` emits no artifact for a module with parse errors, so
# this fails loudly rather than silently comparing bytes that were never Lean.
if LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
     "$work/borrowed.setup.json" "$work/coleq.out" "coleq.out.lean" 8589934592 \
     >"$work/coleq.out.json" 2>"$work/coleq.out.err" &&
   grep -qF '"artifact"' "$work/coleq.out.json"; then
  printf '  ok   the formatted output still parses\n'
else
  printf 'FAIL the printer emitted Lean it cannot re-read:\n' >&2
  cat "$work/coleq.out.json" "$work/coleq.out.err" >&2
  failures=$((failures + 1))
fi

# ...and the assertion that the assertion means something. `RLF-FINAL`.
#
# The two parse checks in this file are `grep -qF '"artifact"'`, and they are worth exactly as much as
# the claim that `__analyze-exact` *omits* that key for a module with parse errors. If it emitted an
# artifact regardless -- or emitted one holding a diagnostics list nobody reads -- both checks would
# pass on every input, including the broken Lean they exist to catch, and nothing in this suite would
# notice. That is the shape of a vacuous test: not a check that is wrong, but a check that cannot fail.
#
# So the absence is pinned directly, on the real frontend, against source that is definitely not Lean.
# This is the negative half of `evidence/04-coleq-break.txt` -- that file records the printer emitting
# a broken parse and this records what "broken parse" looks like coming back.
#
# The check guards its own fixture, which is not a bonus but the reason it can be trusted: this
# fixture's first draft was `def wrong : Nat := 1`, which is perfectly good Lean, and the run said so
# by failing here rather than by printing `ok`. A fixture that stopped being malformed -- a future
# grammar accepting what this one rejects -- cannot quietly turn the check into a tautology.
#
# `:= :=` is a parse error and not an elaboration error, and the difference does not matter to the
# property: `analyzeExact` withholds the artifact on `messages.hasErrors` (`LeanFmt/Analysis.lean:79`),
# which is any error at all. A parse error is chosen because it is the one this suite's `"artifact"`
# checks exist to catch -- the printer's own output failing to re-parse.
printf -- '--- malformed input: what makes the parse checks non-vacuous ---\n'
cat >"$work/broken.lean" <<'FIXTURE'
module

def wrong : Nat := := 1
FIXTURE
if LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
     "$work/borrowed.setup.json" "$work/broken.lean" "broken.lean" 8589934592 \
     >"$work/broken.json" 2>"$work/broken.err"; then
  if grep -qF '"artifact"' "$work/broken.json"; then
    printf 'FAIL __analyze-exact emitted an artifact for source that does not parse.\n' >&2
    printf '     Every `"artifact"` check in this file is therefore vacuous.\n' >&2
    head -c 400 "$work/broken.json" >&2
    failures=$((failures + 1))
  else
    printf '  ok   a module that does not parse yields no artifact (so the checks above can fail)\n'
  fi
else
  # A non-zero exit is also a refusal to hand back an artifact, which is the property being pinned.
  printf '  ok   a module that does not parse is rejected outright (so the checks above can fail)\n'
fi

# --- the extension boundary: the four cases RLF-EXTENSIONS names ---
#
# `twice` is syntax declared earlier in the same file, `oplus` is scoped notation, `quoted` is a macro
# quotation, and `mixed` is a built-in tree under a custom head. The boundary is two closed matches
# with conservative defaults -- `canonical? | _ => none` and `spacingOf | _ => .keep` -- and what this
# pins is that `.keep` is not a wall. `termDoc` recurses through a kind it cannot read, so `twice`'s
# and `oplus`'s own gaps keep their bytes while the built-in `app` nested inside them is still laid
# out. That is what makes the default lossless rather than lazy, and it is only sound because
# `mayCollapse` has already established that nothing here is measured across a line break.
printf -- '--- the extension boundary ---\n'
cat >"$work/ext.lean" <<'FIXTURE'
module

namespace Ext

syntax:max "twice " term : term
macro_rules | `(twice $x) => `(($x, $x))

def usesTwice : Nat × Nat := twice (id     1)

scoped notation:65 a " oplus " b => (a, b)

def usesScoped : Nat × Nat := (id     1) oplus (id     2)

open Lean in
def quoted (stx : Term) : MacroM Term := `($stx + $stx)

def mixed : Nat × Nat := twice (id     (1 + 2))

end Ext
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/ext.lean" "ext.lean" 8589934592 >"$work/ext.json"
"$tests" printer-format "$work/ext.json" "$work/ext.lean" 100 >"$work/ext.out"

if grep -qF 'def usesTwice : Nat × Nat := twice (id 1)' "$work/ext.out" &&
   grep -qF 'def usesScoped : Nat × Nat := (id 1) oplus (id 2)' "$work/ext.out" &&
   grep -qF 'def mixed : Nat × Nat := twice (id (1 + 2))' "$work/ext.out"; then
  printf '  ok   the walk descends through custom syntax and lays out the built-ins inside it\n'
else
  printf 'FAIL a `.keep` kind stopped the walk; the fallback is meant to recurse, not to wall off:\n' >&2
  diff -u "$work/ext.lean" "$work/ext.out" >&2 || true
  failures=$((failures + 1))
fi

# The custom heads themselves are never respaced -- there is no grammar here this printer can read,
# so `twice `, ` oplus ` and the quotation keep every byte they were written with.
if grep -qF 'scoped notation:65 a " oplus " b => (a, b)' "$work/ext.out" &&
   grep -qF 'def quoted (stx : Term) : MacroM Term := `($stx + $stx)' "$work/ext.out" &&
   grep -qF 'macro_rules | `(twice $x) => `(($x, $x))' "$work/ext.out"; then
  printf '  ok   custom heads, scoped notation and quotations keep their bytes\n'
else
  printf 'FAIL the printer respaced syntax whose declaration it cannot read:\n' >&2
  diff -u "$work/ext.lean" "$work/ext.out" >&2 || true
  failures=$((failures + 1))
fi

if LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
     "$work/borrowed.setup.json" "$work/ext.out" "ext.out.lean" 8589934592 \
     >"$work/ext.out.json" 2>"$work/ext.out.err" &&
   grep -qF '"artifact"' "$work/ext.out.json"; then
  printf '  ok   the formatted extension module still parses\n'
else
  printf 'FAIL formatting a module of custom syntax produced Lean that does not parse:\n' >&2
  cat "$work/ext.out.json" "$work/ext.out.err" >&2
  failures=$((failures + 1))
fi

# Idempotence, the roadmap's "formatting twice is byte-identical to formatting once". The second pass
# re-parses the first pass's *output*, so this is a real second format and not a repeated call: if the
# layout emitted something the parser reads back differently, this is where it shows.
#
# Both fixtures, because they can fail differently. `wonky` re-spaces within a line; the header is the
# only layout so far that emits *vertical* structure, and a rule that adds a line each pass would be
# invisible here on `wonky` and obvious on the header.
printf -- '--- idempotence ---\n'
check_idempotent() {
  local name=$1 once=$2
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$once" "$name.lean" 8589934592 >"$work/$name.2.json"
  "$tests" printer-format "$work/$name.2.json" "$once" 80 >"$work/$name.out2"
  if diff -u "$once" "$work/$name.out2" >"$work/$name.idem.diff" 2>&1; then
    printf '  ok   %s: formatting twice is byte-identical to formatting once\n' "$name"
  else
    printf 'FAIL %s: formatting is not idempotent:\n' "$name" >&2
    cat "$work/$name.idem.diff" >&2
    failures=$((failures + 1))
  fi
}
check_idempotent wonky "$work/wonky.out"
check_idempotent header "$work/header.out"

printf -- '--- result ---\n'
printf 'failures=%s\n' "$failures"
[[ "$failures" -eq 0 ]]
