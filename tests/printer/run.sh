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

modules_checked=$(($(find LeanFmt -name '*.lean' | wc -l | tr -d ' ') + 1))
printf -- '--- corpus ---\n'
printf 'modules_checked=%s commands=%s canonical=%s headers_canonical=%s members=%s failures=%s\n' \
  "$modules_checked" "$total_commands" "$total_canonical" "$total_header_canonical" \
  "$total_members" "$failures"

# Exact, not a floor: a module has exactly one header, every module here has one, and the layout is
# written to decline *per group and per gap* rather than per header — so there is no shape of header in
# this repository it should refuse outright. A refusal is a claim that the header parse and the
# projection disagree about what this file is, which is worth failing over rather than tracking as a
# statistic.
if [[ $total_header_canonical -ne $modules_checked ]]; then
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
if [[ $total_canonical -lt 350 ]]; then
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
if [[ $total_members -lt 50 ]]; then
  printf 'FAIL only %s member shells were claimed; the ctor/field layout is not running\n' \
    "$total_members" >&2
  failures=$((failures + 1))
fi

# A corpus whose modules all projected to zero commands would pass every assertion above while
# testing nothing. A floor rather than an exact count: it rises as the project grows, and only a
# broken walk drives it toward zero.
if [[ $total_commands -lt 100 ]]; then
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
if [[ $evidence_commands != "$total_commands" ]]; then
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
  if [[ $tail_bytes -lt 1 ]]; then
    printf 'FAIL the #exit tail is empty; the terminal path was not exercised\n' >&2
    failures=$((failures + 1))
  else
    printf '  ok   the #exit tail round-trips (%s bytes)\n' "$tail_bytes"
  fi
  if [[ $header_bytes -lt 1 ]]; then
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
actual_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" |
  tr ' ' '\n' | sed -n 's/^app_slack=\([0-9]*\)$/\1/p')
if [[ $actual_slack == "$expected_slack" ]]; then
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
actual_binder_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" |
  tr ' ' '\n' | sed -n 's/^binder_slack=\([0-9]*\)$/\1/p')
if [[ $actual_binder_slack == "$expected_binder_slack" ]]; then
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
actual_match_slack=$("$tests" printer-report "$work/wonky.json" "$work/wonky.lean" |
  tr ' ' '\n' | sed -n 's/^match_slack=\([0-9]*\)$/\1/p')
if [[ $actual_match_slack == "$expected_match_slack" ]]; then
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
if [[ $actual_blank_gaps == "$expected_blank_gaps" ]]; then
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
if [[ $actual_tactic_blocks == "$expected_tactic_blocks" ]]; then
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
if [[ $actual_ownable == "$expected_ownable" && $actual_own_line == "$expected_own_line" &&
  $actual_at_two == "$expected_at_two" ]]; then
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

# --- notation spacing, from the ruff-05b semantic fact (RLF-NOTATION) ---
#
# The first layer to read a fact the projection cannot carry. `ruff-05b` captures each notation's
# declared untrimmed atom strings from the live `Environment` (`" + "`, `" ⊗"`) into the `v4` artifact,
# and this section is the printer consuming them. Every other fixture in this file analyzes with
# `captureSemantic=0`, so its artifact holds no fact and its notations keep their bytes -- which is why
# `wonky`'s `id 12 + id 13` above still keeps the spaces around `+`. Here the analysis passes `1`, the
# fact is present, and the notations take their declared spacing.
#
# Each golden line is a separate claim:
#   `1 + 2`, `1 + 2 * 3`   core `+`/`*`, imported and module-value-stripped, recovered by `ruff-05b`'s
#                          `evalConst` path and emitted as the declared `" + "` / `" * "`. Precedence is
#                          the parser's and untouched: `1 + 2 * 3` keeps its tree.
#   `8 + 9` from `8  +  9` slack around a notation collapses to the declared single space, the same way
#                          an app's does -- but chosen from the fact, not from a rule in `Printer.lean`.
#   `3 ⊗4` from `3⊗4`      the asymmetric case, and the whole reason the separator is per-gap. The
#                          corpus notation declares its atom `" ⊗"` -- a space on the left, tight on the
#                          right -- so the gap before `⊗` opens to one space and the gap after it stays
#                          tight. A uniform one-space rule would emit `3 ⊗ 4` and be wrong; the fact
#                          says `3 ⊗4`, and this is that per-gap fidelity pinned.
#   `6 /- keep -/ + 7`     UNCHANGED: the comment sits in the gap left of `+`, so that gap keeps its
#                          bytes (the declared space would delete it) while the gap right of `+`, already
#                          one space, is the declared spacing. The per-gap comment refusal reaching a
#                          notation.
#   `notation:65 ... => Prod.mk a b`  the declaration itself is a `notation` command on the conservative
#                          path -- no fact keys it -- so it and its `" ⊗"` atom string keep every byte.
printf -- '--- notation spacing, from the ruff-05b semantic fact ---\n'
cat >"$work/notation.lean" <<'FIXTURE'
module

notation:65 a:66 " ⊗" b:65 => Prod.mk a b

def add : Nat := 1+2
def prec : Nat := 1+2*3
def slack : Nat := 8  +  9
def asym : Nat × Nat := 3⊗4
def commented : Nat := 6 /- keep -/ + 7
FIXTURE
# captureSemantic=1: the fact is captured and carried in the artifact the printer reads.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/notation.lean" "notation.lean" 8589934592 1 >"$work/notation.json"
"$tests" printer-format "$work/notation.json" "$work/notation.lean" 100 >"$work/notation.out"
cat >"$work/notation.golden" <<'GOLDEN'
module

notation:65 a:66 " ⊗" b:65 => Prod.mk a b

def add : Nat := 1 + 2
def prec : Nat := 1 + 2 * 3
def slack : Nat := 8 + 9
def asym : Nat × Nat := 3 ⊗4
def commented : Nat := 6 /- keep -/ + 7
GOLDEN
if diff -u "$work/notation.golden" "$work/notation.out" >"$work/notation.diff" 2>&1; then
  printf '  ok   the notation layout matches the golden file\n'
else
  printf 'FAIL the notation layout does not match the golden file:\n' >&2
  cat "$work/notation.diff" >&2
  failures=$((failures + 1))
fi

# ...and it changed something, or the fact is doing nothing and the golden is a copy of the input.
if diff -q "$work/notation.lean" "$work/notation.out" >/dev/null 2>&1; then
  printf 'FAIL the notation layout changed nothing; the fact is not being consumed\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the notation layout changed the source (%s lines rewritten)\n' \
    "$(diff "$work/notation.lean" "$work/notation.out" | grep -c '^<')"
fi

# The fact is load-bearing. The SAME source analyzed with captureSemantic=0 carries no fact, and every
# notation then keeps its bytes. This is the conservative fallback, and it is what says the spacing
# above came from the fact rather than from the printer inventing it -- the difference between reading a
# declaration and guessing one.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/notation.lean" "notation.lean" 8589934592 0 >"$work/notation.off.json"
"$tests" printer-format "$work/notation.off.json" "$work/notation.lean" 100 >"$work/notation.off.out"
if diff -q "$work/notation.lean" "$work/notation.off.out" >/dev/null 2>&1; then
  printf '  ok   with no fact captured, every notation keeps its bytes (spacing is never invented)\n'
else
  printf 'FAIL a notation was respaced with no fact present; the fallback is not conservative:\n' >&2
  diff -u "$work/notation.lean" "$work/notation.off.out" >&2
  failures=$((failures + 1))
fi

# Parse-preservation: the respaced output re-parses, and to the same token count. `__analyze-exact`
# yields no artifact for a module with parse errors (pinned non-vacuous by `broken.lean` above), so an
# artifact coming back is the output parsing; the token count is checked too, because respacing must
# move whitespace and nothing else -- no token added, dropped, or merged. The comment's survival is
# pinned by the golden line above.
if LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/notation.out" "notation.out.lean" 8589934592 1 \
  >"$work/notation.out.json" 2>"$work/notation.out.err" &&
  grep -qF '"artifact"' "$work/notation.out.json"; then
  if python3 -c "
import json, sys
a = json.load(open('$work/notation.json'))['artifact']['source']['tokens']
b = json.load(open('$work/notation.out.json'))['artifact']['source']['tokens']
sys.exit(0 if len(a) == len(b) else 1)
"; then
    printf '  ok   the respaced output re-parses to the same token count (parse-preserving)\n'
  else
    printf 'FAIL the respaced output re-parses to a different token count; a token moved\n' >&2
    failures=$((failures + 1))
  fi
else
  printf 'FAIL the printer emitted notation Lean it cannot re-read:\n' >&2
  cat "$work/notation.out.json" "$work/notation.out.err" >&2
  failures=$((failures + 1))
fi

# Idempotence, on the fact path. `check_idempotent` below re-analyzes with captureSemantic=0, so it
# cannot exercise this; the notation layout only fires when the fact is present, so its second pass
# must capture the fact again.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/notation.out" "notation.lean" 8589934592 1 >"$work/notation.idem.json"
"$tests" printer-format "$work/notation.idem.json" "$work/notation.out" 100 >"$work/notation.out2"
if diff -u "$work/notation.out" "$work/notation.out2" >"$work/notation.idem.diff" 2>&1; then
  printf '  ok   notation: formatting twice is byte-identical to formatting once\n'
else
  printf 'FAIL notation: formatting is not idempotent:\n' >&2
  cat "$work/notation.idem.diff" >&2
  failures=$((failures + 1))
fi

# --- offside re-indent, the RLF-OFFSIDE primitive ---
#
# The capability `RLF-OFFSIDE` delivers, proven in isolation: emit a multi-line offside block at a
# chosen canonical base column, preserving every internal `colEq`/`colGt`/`colGe` so the parse never
# changes (`notes/06-offside-primitive.md`). The design-twice chose a printer-side `reindentBlock` over
# a new `Doc` constructor -- re-indent is width-independent, so the engine stays frozen and `ruff-02` is
# not reopened. `printer-reindent` drives it: auto-detect the fixture's one indented offside block, shift
# every structural line by one delta so the block's first token lands at `base`, and splice back.
#
# Parse-preservation is checked by the *fresh frontend at several bases*, not argued. The block's anchor
# is column 4 (the `match`); re-indenting to a left base (2), the identity (4), and a right base (6) each
# reparses, and the token stream is identical across all three -- re-indent moves whitespace and nothing
# else (`notes/05-reflow-architecture.md` §4.1). The arms stay `colEq` the `match` at every base, which
# is the offside relationship a naive per-line shift would break.
printf -- '--- offside re-indent (RLF-OFFSIDE primitive) ---\n'
cat >"$work/offside.lean" <<'FIXTURE'
module

def f : Nat :=
    match 0 with
    | 0 => 1
    | _ => 2
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/offside.lean" "offside.lean" 8589934592 >"$work/offside.json"

# Each base reparses. `broken.lean` above pins that a parse error yields no artifact, so an artifact
# coming back *is* the output parsing.
offside_parses=1
for base in 2 4 6; do
  "$tests" printer-reindent "$work/offside.json" "$work/offside.lean" "$base" >"$work/offside.$base.lean"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/offside.$base.lean" "offside.lean" 8589934592 \
    >"$work/offside.$base.json" 2>/dev/null || true
  if ! grep -qF '"artifact"' "$work/offside.$base.json"; then
    printf 'FAIL re-indent to base %s produced Lean that does not re-parse:\n' "$base" >&2
    cat "$work/offside.$base.lean" >&2
    offside_parses=0
  fi
done
if [ "$offside_parses" = 1 ]; then
  printf '  ok   re-indent to bases 2, 4, 6 each re-parses\n'
else
  failures=$((failures + 1))
fi

# Re-indent to the anchor column (4) is the identity: Δ = 0, byte-for-byte the input. A primitive that
# perturbed a block it was asked to leave in place would be caught here, and idempotence rests on it.
if diff -q "$work/offside.lean" "$work/offside.4.lean" >/dev/null 2>&1; then
  printf '  ok   re-indent to the anchor column is the identity\n'
else
  printf 'FAIL re-indent to the anchor column changed the block:\n' >&2
  diff -u "$work/offside.lean" "$work/offside.4.lean" >&2
  failures=$((failures + 1))
fi

# ...and the off-anchor bases actually moved bytes, or the property above is vacuous.
if diff -q "$work/offside.lean" "$work/offside.2.lean" >/dev/null 2>&1 ||
  diff -q "$work/offside.lean" "$work/offside.6.lean" >/dev/null 2>&1; then
  printf 'FAIL an off-anchor base did not change the block; the re-indent is doing nothing\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   bases 2 and 6 each moved the block off its anchor\n'
fi

# The property: same token stream across all three bases, and the columns of `match`, `| 0` and `| _`
# stay equal within each base (the `colEq` matchAlts require). Token texts are the source sliced at each
# token's `[start, stop)`; columns are codepoints since the line's start, which is what the parser's
# checks count (`Printer.lean` `columnOf`).
cat >"$work/offside_verify.py" <<'PY'
import json, sys
work = sys.argv[1]

def load(lean, js):
    src = open(lean, 'rb').read()
    toks = json.load(open(js))['artifact']['source']['tokens']
    texts, cols = [], []
    for t in toks:
        start, stop = t[1], t[2]
        texts.append(src[start:stop].decode('utf8'))
        line_start = src.rfind(b'\n', 0, start) + 1
        cols.append(len(src[line_start:start].decode('utf8')))
    return texts, cols

fails = 0
streams = {b: load(f"{work}/offside.{b}.lean", f"{work}/offside.{b}.json") for b in (2, 4, 6)}
orig = load(f"{work}/offside.lean", f"{work}/offside.json")

t2, t4, t6 = (streams[b][0] for b in (2, 4, 6))
if t2 == t4 == t6 == orig[0]:
    print("  ok   the token stream is identical across bases 2, 4, 6 and the input")
else:
    print("FAIL the token stream differs across bases (a token was added, dropped or merged)", file=sys.stderr)
    print(f"  base2={t2}\n  base4={t4}\n  base6={t6}\n  input={orig[0]}", file=sys.stderr)
    fails += 1

# `match`, first `|`, second `|` are token indices 5, 8, 12 in `def f : Nat := match 0 with | 0 => 1 | _ => 2`.
for b in (2, 4, 6):
    texts, cols = streams[b]
    assert texts[5] == 'match' and texts[8] == '|' and texts[12] == '|', texts
    if not (cols[5] == cols[8] == cols[12] == b):
        print(f"FAIL at base {b} the match/arm columns are {cols[5]},{cols[8]},{cols[12]}, not all {b}", file=sys.stderr)
        fails += 1
if fails == 0:
    print("  ok   at every base the match and both arms share one column (colEq preserved)")

sys.exit(fails)
PY
if python3 "$work/offside_verify.py" "$work"; then :; else failures=$((failures + $?)); fi

# The verbatim interior is never re-indented. A block whose arm holds a multi-line string literal:
# re-indenting the block shifts the structural lines, but the string's second line is the token's
# *value* and must stay byte-exact (`Doc.lean:62-68`, the reason `verbatim` exists). Re-indent to 4
# (identity) and 8 (shift right); both reparse, the streams are equal, and the multi-line string token
# is byte-identical -- its interior did not move with the block.
cat >"$work/mlstring.lean" <<'FIXTURE'
module

def g : String :=
    match 0 with
    | 0 => "line one
line two"
    | _ => "z"
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/mlstring.lean" "mlstring.lean" 8589934592 >"$work/mlstring.json"
ml_parses=1
for base in 4 8; do
  "$tests" printer-reindent "$work/mlstring.json" "$work/mlstring.lean" "$base" >"$work/mlstring.$base.lean"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/mlstring.$base.lean" "mlstring.lean" 8589934592 \
    >"$work/mlstring.$base.json" 2>/dev/null || true
  grep -qF '"artifact"' "$work/mlstring.$base.json" || ml_parses=0
done
if [ "$ml_parses" = 1 ]; then
  printf '  ok   a block holding a multi-line string re-indents and re-parses\n'
else
  printf 'FAIL re-indenting a block with a multi-line string produced unparseable Lean\n' >&2
  failures=$((failures + 1))
fi
cat >"$work/mlstring_verify.py" <<'PY'
import json, sys
work = sys.argv[1]

def toks(b):
    src = open(f"{work}/mlstring.{b}.lean", 'rb').read()
    a = json.load(open(f"{work}/mlstring.{b}.json"))['artifact']['source']['tokens']
    return [src[t[1]:t[2]].decode('utf8') for t in a]

fails = 0
t4, t8 = toks(4), toks(8)
if t4 != t8:
    print("FAIL the multi-line-string block's token stream changed under re-indent", file=sys.stderr)
    fails += 1
ml = [t for t in t4 if '\n' in t]
if not (ml and ml == [t for t in t8 if '\n' in t] and ml[0] == '"line one\nline two"'):
    print(f"FAIL the multi-line string token was not preserved byte-exact: {ml}", file=sys.stderr)
    fails += 1
if fails == 0:
    print("  ok   the multi-line string token is byte-exact across bases (its interior never shifts)")
sys.exit(fails)
PY
if python3 "$work/mlstring_verify.py" "$work"; then :; else failures=$((failures + $?)); fi

# --- reflow, margin-driven line breaking, the RLF-REFLOW capability ---
#
# The first layout that makes the engine *decide* (notes/07-reflow-policy.md). An over-margin
# single-line command hangs its app value onto its own indented line and, if that still exceeds the
# margin, breaks one argument per line -- flat when it fits. The corpus is canonical and never exceeds
# the margin (printer-roundtrip above holds byte-identity at every fitting width), so the capability can
# only be tested on synthetic *over-margin* source, which is what these goldens are.
printf -- '--- reflow, margin-driven line breaking (RLF-REFLOW) ---\n'
cat >"$work/reflow.lean" <<'FIXTURE'
module

def target (a1 a2 a3 a4 a5 a6 a7 a8 a9 : Nat) : Nat := a1

def wide : Nat := target 1111111111 2222222222 3333333333 4444444444 5555555555 6666666666 7777777777 8888888888 9999999999

def nested : Nat := target (target 1111111111 2222222222 3333333333 4444444444 5555555555 6666666666 7777777777 8888888888 9999999999) 1010101010 1111111111 1212121212 1313131313 1414141414 1515151515 1616161616 1717171717

def fits : Nat := target 1 2 3 4 5 6 7 8 9
FIXTURE

LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/reflow.lean" "reflow.lean" 8589934592 >"$work/reflow.json"

# Format at the margins the prompt names, and reparse each output. `|| true` so a non-parsing output
# does not abort the run before the verifier can report *which* margin broke and how.
reflow_margins="0 1 40 80 100 1000"
for w in $reflow_margins; do
  "$tests" printer-format "$work/reflow.json" "$work/reflow.lean" "$w" >"$work/reflow.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/reflow.$w.out" "reflow.lean" 8589934592 \
    >"$work/reflow.$w.json" 2>"$work/reflow.$w.err" || true
done

# A margin wider than every line breaks nothing: the whole file is the identity.
if diff -q "$work/reflow.lean" "$work/reflow.1000.out" >/dev/null 2>&1; then
  printf '  ok   at margin 1000 nothing exceeds the margin, so the output is its input (identity)\n'
else
  printf 'FAIL at margin 1000 the formatter changed a file that fits\n' >&2
  failures=$((failures + 1))
fi

# At margin 100 the wide commands exceed it and must change -- the goldens cannot degenerate to copies.
if diff -q "$work/reflow.lean" "$work/reflow.100.out" >/dev/null 2>&1; then
  printf 'FAIL at margin 100 the over-margin commands were not broken\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   at margin 100 the over-margin commands were broken (%s lines rewritten)\n' \
    "$(diff "$work/reflow.lean" "$work/reflow.100.out" | grep -c '^<')"
fi

# Parse-preservation: every margin's output reparses to the SAME token stream as the input. A break
# that violated `argument`'s checkColGt (Lean/Parser/Term.lean:889) would fail to reparse, or reparse
# to a different stream -- the wrapped token would stop being an argument.
cat >"$work/reflow_verify.py" <<'PY'
import json, sys
work, margins = sys.argv[1], sys.argv[2].split()

def stream(lean, js):
    src = open(lean, 'rb').read()
    toks = json.load(open(js))['artifact']['source']['tokens']
    return [src[t[1]:t[2]].decode('utf8') for t in toks]

fails = 0
orig = stream(f"{work}/reflow.lean", f"{work}/reflow.json")
for w in margins:
    try:
        s = stream(f"{work}/reflow.{w}.out", f"{work}/reflow.{w}.json")
    except Exception as e:
        print(f"FAIL margin {w}: output did not reparse ({e})", file=sys.stderr)
        fails += 1
        continue
    if s != orig:
        print(f"FAIL margin {w}: token stream differs from the input (a token moved)", file=sys.stderr)
        fails += 1
if fails == 0:
    print(f"  ok   every margin ({sys.argv[2]}) reparses to the input's token stream (parse-preserving)")
sys.exit(fails)
PY
if python3 "$work/reflow_verify.py" "$work" "$reflow_margins"; then :; else failures=$((failures + $?)); fi

# checkColGt made concrete: at margin 40 the wide value hangs on its own line, its head `target` at
# column 2 and every argument strictly right of it at column 4 -- the relationship the reparse depends on.
if grep -qE '^def wide : Nat :=$' "$work/reflow.40.out" &&
  grep -qE '^  target$' "$work/reflow.40.out" &&
  grep -qE '^    1111111111$' "$work/reflow.40.out"; then
  printf '  ok   at margin 40 the value hangs: head at column 2, arguments at column 4 (checkColGt)\n'
else
  printf 'FAIL at margin 40 the wide value did not hang with the head left of its arguments\n' >&2
  cat "$work/reflow.40.out" >&2
  failures=$((failures + 1))
fi

# Idempotence at every margin: reparse the output and reformat it at the same margin; byte-identical.
# A broken command is now multi-line, so `mayCollapse` declines it and its bytes are kept -- which is
# why a second pass reproduces the first (notes/07-reflow-policy.md §4).
reflow_idem=
for w in $reflow_margins; do
  "$tests" printer-format "$work/reflow.$w.json" "$work/reflow.$w.out" "$w" >"$work/reflow.$w.out2"
  if ! diff -q "$work/reflow.$w.out" "$work/reflow.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL reflow: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/reflow.$w.out" "$work/reflow.$w.out2" >&2
    failures=$((failures + 1))
    reflow_idem=1
  fi
done
if [[ -z $reflow_idem ]]; then
  printf '  ok   reflow: formatting twice is byte-identical at every margin (%s)\n' "$reflow_margins"
fi

# --- operator / notation reflow, the RLF-OPERATOR-BREAK capability ---
#
# RLF-REFLOW broke `app`; this breaks the notation kinds it deferred (notes/09-operator-break.md). An
# over-margin operator chain hangs its value onto its own line (head at the indent base) and then breaks
# op_lead -- the operator starts each continuation line, `left` / `  + right`, Black's binary-operator
# layout -- every continuation at a single column because left-association lives in the never-nested head.
# The break is gated on the ruff-05b declared-spacing fact (captureSemantic=1 below), so a notation with
# no fact stays on the lossless flat path. Parse-preservation is checked with the *tree* gate
# (compare_tokens.py), not the token stream alone: an operator re-association emits the same tokens and a
# different tree (RLF-ACCEPT), and an operator break is exactly where that could hide.
printf -- '--- operator / notation reflow (RLF-OPERATOR-BREAK) ---\n'
cat >"$work/opbreak.lean" <<'FIXTURE'
module

def wrap (n : Nat) : Nat := n

def opchain : Nat := 1111111111 + 2222222222 + 3333333333 + 4444444444 + 5555555555 + 6666666666 + 7777777777

def opnested : Nat := wrap (1111111111 + 2222222222 + 3333333333 + 4444444444 + 5555555555 + 6666666666 + 7777777777)

def opcomment : Nat := 1111111111 + 2222222222 /- keep -/ + 3333333333 + 4444444444 + 5555555555 + 6666666666

def opfits : Nat := 1 + 2 + 3
FIXTURE

# captureSemantic=1 (the trailing 1): operators get their declared spacing AND become breakable. The same
# source with no fact keeps every notation's bytes -- proven by the notation-spacing test above.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/opbreak.lean" "opbreak.lean" 8589934592 1 >"$work/opbreak.json"

op_margins="0 1 40 80 100 1000"
for w in $op_margins; do
  "$tests" printer-format "$work/opbreak.json" "$work/opbreak.lean" "$w" >"$work/opbreak.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/opbreak.$w.out" "opbreak.lean" 8589934592 1 \
    >"$work/opbreak.$w.json" 2>"$work/opbreak.$w.err" || true
done

# A margin wider than every line breaks nothing: the whole file is the identity.
if diff -q "$work/opbreak.lean" "$work/opbreak.1000.out" >/dev/null 2>&1; then
  printf '  ok   at margin 1000 nothing exceeds the margin, so the output is its input (identity)\n'
else
  printf 'FAIL at margin 1000 the formatter changed an operator file that fits\n' >&2
  failures=$((failures + 1))
fi

# At margin 40 the wide operator chains exceed it and must change.
if diff -q "$work/opbreak.lean" "$work/opbreak.40.out" >/dev/null 2>&1; then
  printf 'FAIL at margin 40 the over-margin operators were not broken\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   at margin 40 the over-margin operators were broken (%s lines rewritten)\n' \
    "$(diff "$work/opbreak.lean" "$work/opbreak.40.out" | grep -c '^<')"
fi

# Parse-preservation, token AND tree, at every margin. An operator break that re-associated would emit the
# same token stream and a different parse tree, which a token-only gate cannot see (RLF-ACCEPT).
op_pp=
for w in $op_margins; do
  if ! python3 "$repo_root/experiments/compare_tokens.py" \
    "$work/opbreak.json" "$work/opbreak.$w.json" "$work/opbreak.lean" "$work/opbreak.$w.out" \
    >"$work/opbreak.$w.pp" 2>&1; then
    printf 'FAIL operator break at margin %s changed the parse: %s\n' "$w" "$(cat "$work/opbreak.$w.pp")" >&2
    failures=$((failures + 1))
    op_pp=1
  fi
done
if [[ -z $op_pp ]]; then
  printf '  ok   every margin (%s) reparses to the input token stream AND tree (no re-association)\n' "$op_margins"
fi

# op_lead made concrete: at margin 40 the operator leads each continuation at column 4, strictly right of
# the head at column 2 -- the same relationship app's checkColGt needs, though operators impose no such
# check (notes/09 §1.1), which is why the head hangs left of its operands and still reparses.
if grep -qE '^def opchain : Nat :=$' "$work/opbreak.40.out" &&
  grep -qE '^  1111111111 ' "$work/opbreak.40.out" &&
  grep -qE '^    \+ 4444444444$' "$work/opbreak.40.out"; then
  printf '  ok   at margin 40 the chain breaks op_lead: head at column 2, `+ operand` at column 4\n'
else
  printf 'FAIL at margin 40 the operator chain did not break op_lead\n' >&2
  cat "$work/opbreak.40.out" >&2
  failures=$((failures + 1))
fi

# The comment survives at every margin: a gap holding `/- keep -/` fails the clean guard, so the node
# holding it stays flat (its bytes kept) while the chain around it breaks -- the comment is never a line.
op_cmt=
for w in $op_margins; do
  if ! grep -qF '/- keep -/' "$work/opbreak.$w.out"; then
    printf 'FAIL operator break at margin %s dropped the comment\n' "$w" >&2
    failures=$((failures + 1))
    op_cmt=1
  fi
done
if [[ -z $op_cmt ]]; then
  printf '  ok   the /- keep -/ comment survives at every margin (the clean guard keeps its node flat)\n'
fi

# The fits case stays byte-canonical -- a short operator is never moved or broken.
if grep -qE '^def opfits : Nat := 1 \+ 2 \+ 3$' "$work/opbreak.40.out"; then
  printf '  ok   a fitting operator stays flat and byte-canonical at margin 40\n'
else
  printf 'FAIL a fitting operator was broken or moved at margin 40\n' >&2
  failures=$((failures + 1))
fi

# Idempotence at every margin: a broken command is multi-line, so `mayCollapse` declines it and its bytes
# are kept -- a second pass reproduces the first.
op_idem=
for w in $op_margins; do
  "$tests" printer-format "$work/opbreak.$w.json" "$work/opbreak.$w.out" "$w" >"$work/opbreak.$w.out2"
  if ! diff -q "$work/opbreak.$w.out" "$work/opbreak.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL operator break: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/opbreak.$w.out" "$work/opbreak.$w.out2" >&2
    failures=$((failures + 1))
    op_idem=1
  fi
done
if [[ -z $op_idem ]]; then
  printf '  ok   operator break: formatting twice is byte-identical at every margin (%s)\n' "$op_margins"
fi

# --- bracketed-binder signatures, the RLF-OPERATOR-BREAK binder case ---
#
# `optDeclSig`/`declSig` = `many (ppSpace >> (binderIdent <|> bracketedBinder)) >> typeSpec`
# (Lean/Parser/Command.lean:130-135) -- no colGt/colGe/colEq anywhere (`ppIndent`/`ppSpace` are
# pretty-printer hints), so an over-margin single-line signature breaks one binder per line at column 2,
# the head binder left on the `def name` line, and reparses at any column (notes/09 §1.2). explicit,
# implicit, and instance binders all break; a comment between binders keeps the whole signature flat.
printf -- '--- bracketed-binder signatures (RLF-OPERATOR-BREAK) ---\n'
cat >"$work/binder.lean" <<'FIXTURE'
module

def sig (aaaaaa : Nat) (bbbbbb : Nat) (cccccc : Nat) (dddddd : Nat) (eeeeee : Nat) : Nat := aaaaaa

def mixed (aaaaaa : Nat) ⦃ssssss : Nat⦄ {bbbbbb : Type} [Add Nat] (dddddd : Nat) (eeeeee : Nat) : Nat := dddddd

def bcomment (aaaaaa : Nat) /- keep -/ (bbbbbb : Nat) (cccccc : Nat) (dddddd : Nat) (eeeeee : Nat) : Nat := aaaaaa

theorem thm (aaaaaa : Nat) (bbbbbb : Nat) (cccccc : Nat) (dddddd : Nat) (eeeeee : Nat) : aaaaaa = aaaaaa := rfl

def small (a : Nat) : Nat := a
FIXTURE

LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/binder.lean" "binder.lean" 8589934592 1 >"$work/binder.json"

bind_margins="0 1 40 80 100 1000"
for w in $bind_margins; do
  "$tests" printer-format "$work/binder.json" "$work/binder.lean" "$w" >"$work/binder.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/binder.$w.out" "binder.lean" 8589934592 1 \
    >"$work/binder.$w.json" 2>"$work/binder.$w.err" || true
done

if diff -q "$work/binder.lean" "$work/binder.1000.out" >/dev/null 2>&1; then
  printf '  ok   at margin 1000 nothing exceeds the margin, so the output is its input (identity)\n'
else
  printf 'FAIL at margin 1000 the formatter changed a signature file that fits\n' >&2
  failures=$((failures + 1))
fi

if diff -q "$work/binder.lean" "$work/binder.40.out" >/dev/null 2>&1; then
  printf 'FAIL at margin 40 the over-margin signatures were not broken\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   at margin 40 the over-margin signatures were broken (%s lines rewritten)\n' \
    "$(diff "$work/binder.lean" "$work/binder.40.out" | grep -c '^<')"
fi

bind_pp=
for w in $bind_margins; do
  if ! python3 "$repo_root/experiments/compare_tokens.py" \
    "$work/binder.json" "$work/binder.$w.json" "$work/binder.lean" "$work/binder.$w.out" \
    >"$work/binder.$w.pp" 2>&1; then
    printf 'FAIL binder break at margin %s changed the parse: %s\n' "$w" "$(cat "$work/binder.$w.pp")" >&2
    failures=$((failures + 1))
    bind_pp=1
  fi
done
if [[ -z $bind_pp ]]; then
  printf '  ok   every margin (%s) reparses to the input token stream AND tree (no colGt to violate)\n' "$bind_margins"
fi

# The head binder stays on the `def name` line; every following binder hangs one per line at column 2.
# explicit `(...)`, implicit `{...}`, and instance `[...]` binders all break the same way.
if grep -qE '^def sig \(aaaaaa : Nat\)$' "$work/binder.40.out" &&
  grep -qE '^  \(bbbbbb : Nat\)$' "$work/binder.40.out" &&
  grep -qE '^  \{bbbbbb : Type\}$' "$work/binder.40.out" &&
  grep -qE '^  \[Add Nat\]$' "$work/binder.40.out"; then
  printf '  ok   at margin 40 binders hang one per line at column 2 (explicit, implicit, instance)\n'
else
  printf 'FAIL at margin 40 the signature did not break one binder per line\n' >&2
  cat "$work/binder.40.out" >&2
  failures=$((failures + 1))
fi

# The strict-implicit bracket `⦃x : T⦄` is a bracketedBinder like the other three, on the same
# `optDeclSig` path with no column check, so it breaks onto its own line too -- the fourth bracket kind.
if grep -qE '^  ⦃ssssss : Nat⦄$' "$work/binder.40.out"; then
  printf '  ok   a strict-implicit binder ⦃x : T⦄ hangs on its own line too (all four bracket kinds)\n'
else
  printf 'FAIL at margin 40 the strict-implicit binder did not break onto its own line\n' >&2
  cat "$work/binder.40.out" >&2
  failures=$((failures + 1))
fi

# A comment between two binders fails the clean guard, so the whole signature keeps its bytes (flat) --
# the comment is never turned into a line and dropped.
bind_cmt=
for w in $bind_margins; do
  if ! grep -qF '/- keep -/' "$work/binder.$w.out"; then
    printf 'FAIL binder break at margin %s dropped the comment\n' "$w" >&2
    failures=$((failures + 1))
    bind_cmt=1
  fi
done
if [[ -z $bind_cmt ]]; then
  printf '  ok   a comment between binders survives at every margin (its signature stays flat)\n'
fi
if grep -qE '^def bcomment .* /- keep -/ .*: Nat := aaaaaa$' "$work/binder.40.out"; then
  printf '  ok   the commented signature stays flat even over-margin (the clean guard declines it)\n'
else
  printf 'FAIL the commented signature was broken despite the comment in a gap\n' >&2
  failures=$((failures + 1))
fi

# `declSig` (a `theorem`'s required-type signature) breaks by the same rule as `optDeclSig`.
if grep -qE '^theorem thm \(aaaaaa : Nat\)$' "$work/binder.40.out"; then
  printf '  ok   a theorem declSig breaks the same way as a def optDeclSig\n'
else
  printf 'FAIL the theorem declSig did not break\n' >&2
  failures=$((failures + 1))
fi

# The fits case stays byte-canonical.
if grep -qE '^def small \(a : Nat\) : Nat := a$' "$work/binder.40.out"; then
  printf '  ok   a fitting signature stays flat and byte-canonical at margin 40\n'
else
  printf 'FAIL a fitting signature was broken at margin 40\n' >&2
  failures=$((failures + 1))
fi

bind_idem=
for w in $bind_margins; do
  "$tests" printer-format "$work/binder.$w.json" "$work/binder.$w.out" "$w" >"$work/binder.$w.out2"
  if ! diff -q "$work/binder.$w.out" "$work/binder.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL binder break: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/binder.$w.out" "$work/binder.$w.out2" >&2
    failures=$((failures + 1))
    bind_idem=1
  fi
done
if [[ -z $bind_idem ]]; then
  printf '  ok   binder break: formatting twice is byte-identical at every margin (%s)\n' "$bind_margins"
fi

# --- record layout, the RLF-RECORDS capability ---
#
# `structInst := "{ " >> (optional (… " with ") >> structInstFields (sepByIndent structInstField ", ")
# >> optEllipsis >> optional (" : " term)) >> " }"` (Term.lean:352-357). Unlike operators/binders,
# `sepByIndent` re-establishes a `withPosition` inside the braces, so a field on a continuation line must
# `checkColGe`/`checkColEq` the FIRST field's column (notes/12 §2). The A1 break -- one field per line at
# a fixed nest base -- makes that column fall out of the layout: `"{ "` is two columns and the `nest` is
# two, so field1 (right after `{ `) and every continuation land at running-indent+2, a single column. The
# break is therefore parse-safe ONLY when `{` sits at the running indent, i.e. when the record is
# line-leading -- which `leadFlat` (move-value-down) guarantees for a `:=` value. So the break is armed
# only there (breakRecord flag); a nested record (a field value, mid-line) stays flat, and a comment
# between fields makes the gap non-clean and also stays flat. The corpus is canonical and its records fit
# (printer-roundtrip above is byte-identical), so the capability shows only on over-margin fixtures.
printf -- '--- record layout, vertical A1 break (RLF-RECORDS) ---\n'
cat >"$work/records.lean" <<'FIXTURE'
module

structure P where
  x : Nat
  y : Nat
  z : Nat

structure Q where
  a : P
  b : Nat

def wide : P := { x := 111111111, y := 222222222, z := 333333333 }

def nested : Q := { a := { x := 111111111, y := 222222222, z := 333333333 }, b := 444444444 }

def commented : P := { x := 111111111, /- keep -/ y := 222222222, z := 333333333 }

def f : P := { x := 1, y := 2, z := 3 }
FIXTURE

# Records are gated on the leadFlat position, not on the ruff-05b spacing fact, so no captureSemantic here.
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/records.lean" "records.lean" 8589934592 >"$work/records.json"

rec_margins="0 1 40 80 100 1000"
for w in $rec_margins; do
  "$tests" printer-format "$work/records.json" "$work/records.lean" "$w" >"$work/records.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/records.$w.out" "records.lean" 8589934592 \
    >"$work/records.$w.json" 2>"$work/records.$w.err" || true
done

# A margin wider than every line breaks nothing: the whole file is the identity.
if diff -q "$work/records.lean" "$work/records.1000.out" >/dev/null 2>&1; then
  printf '  ok   at margin 1000 nothing exceeds the margin, so the output is its input (identity)\n'
else
  printf 'FAIL at margin 1000 the formatter changed a record file that fits\n' >&2
  failures=$((failures + 1))
fi

# At margin 40 the wide record exceeds it and must change -- the goldens cannot degenerate to copies.
if diff -q "$work/records.lean" "$work/records.40.out" >/dev/null 2>&1; then
  printf 'FAIL at margin 40 the over-margin record was not broken\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   at margin 40 the over-margin record was broken (%s lines rewritten)\n' \
    "$(diff "$work/records.lean" "$work/records.40.out" | grep -c '^<')"
fi

# Parse-preservation, token AND tree, at every margin. A record break landing a field left of the first
# field's column would violate `sepByIndent`'s checkColGe and fail to reparse (or reparse differently);
# the tree gate (compare_tokens.py) catches a same-token re-parse the token stream alone cannot.
rec_pp=
for w in $rec_margins; do
  if ! python3 "$repo_root/experiments/compare_tokens.py" \
    "$work/records.json" "$work/records.$w.json" "$work/records.lean" "$work/records.$w.out" \
    >"$work/records.$w.pp" 2>&1; then
    printf 'FAIL record break at margin %s changed the parse: %s\n' "$w" "$(cat "$work/records.$w.pp")" >&2
    failures=$((failures + 1))
    rec_pp=1
  fi
done
if [[ -z $rec_pp ]]; then
  printf '  ok   every margin (%s) reparses to the input token stream AND tree (checkColGe held)\n' "$rec_margins"
fi

# A1 made concrete: at margin 40 the value hangs (`{` at column 2), field1 lands right after `{ ` at
# column 4, and every continuation lands at that same column 4 -- the shared column sepByIndent accepts.
if grep -qE '^def wide : P :=$' "$work/records.40.out" &&
  grep -qE '^  \{ x := 111111111,$' "$work/records.40.out" &&
  grep -qE '^    z := 333333333 \}$' "$work/records.40.out"; then
  printf '  ok   at margin 40 the record breaks A1: `{` at column 2, fields at column 4 (checkColEq)\n'
else
  printf 'FAIL at margin 40 the record did not break A1 with fields at a shared column\n' >&2
  cat "$work/records.40.out" >&2
  failures=$((failures + 1))
fi

# The nested record is mid-line (a field value after `a := `), so breakRecord is false and it stays flat
# even when it overflows -- the conservative fallback (notes/12 §2). The outer record still breaks A1.
if grep -qF '{ a := { x := 111111111, y := 222222222, z := 333333333 },' "$work/records.40.out"; then
  printf '  ok   a nested (mid-line) record stays flat -- only the line-leading record breaks\n'
else
  printf 'FAIL at margin 40 the nested record was broken (mid-line break is not parse-safe)\n' >&2
  cat "$work/records.40.out" >&2
  failures=$((failures + 1))
fi

# The comment survives at every margin: a gap holding `/- keep -/` fails the clean guard, so the record
# keeps its bytes flat while its value still hangs -- the comment is never moved onto its own line.
rec_cmt=
for w in $rec_margins; do
  if ! grep -qF '/- keep -/' "$work/records.$w.out"; then
    printf 'FAIL record break at margin %s dropped the comment\n' "$w" >&2
    failures=$((failures + 1))
    rec_cmt=1
  fi
done
if [[ -z $rec_cmt ]]; then
  printf '  ok   the /- keep -/ comment survives at every margin (the clean guard keeps the record flat)\n'
fi

# The fitting record stays byte-canonical -- a short record is never moved or broken.
if grep -qE '^def f : P := \{ x := 1, y := 2, z := 3 \}$' "$work/records.40.out"; then
  printf '  ok   a fitting record stays flat and byte-canonical at margin 40\n'
else
  printf 'FAIL a fitting record was broken or moved at margin 40\n' >&2
  failures=$((failures + 1))
fi

# Idempotence at every margin: a broken record is multi-line, so `mayCollapse` declines it and its bytes
# are kept -- a second pass reproduces the first.
rec_idem=
for w in $rec_margins; do
  "$tests" printer-format "$work/records.$w.json" "$work/records.$w.out" "$w" >"$work/records.$w.out2"
  if ! diff -q "$work/records.$w.out" "$work/records.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL record break: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/records.$w.out" "$work/records.$w.out2" >&2
    failures=$((failures + 1))
    rec_idem=1
  fi
done
if [[ -z $rec_idem ]]; then
  printf '  ok   record break: formatting twice is byte-identical at every margin (%s)\n' "$rec_margins"
fi

# --- offside blocks, the RLF-BLOCKS capability ---
#
# Where "indentation is a token" (results/03-tactics.md) is finally *handled* rather than deferred: a
# command's own-line `by` block is re-indexed to its canonical offside column (commandIndent+2, or the
# enclosing `by`'s column+2 when `by` begins its own line), the RLF-OFFSIDE uniform shift applied by
# construct (notes/08-blocks-layout.md §3, Design B1). The corpus is already canonical, so this is a
# no-op there (printer-roundtrip above is byte-identical); the capability shows only on deliberately
# non-canonical source, which is what this fixture is. A `by`-block body has no external checkColGt
# (Term/Basic.lean:185), so a top-level own-line block de-indents to any column >= 1 and re-parses --
# proven here by the fresh frontend, not argued, exactly as RLF-OFFSIDE's own test proves it.
printf -- '--- offside blocks, canonical re-indentation (RLF-BLOCKS) ---\n'
cat >"$work/blocks.lean" <<'FIXTURE'
module

theorem overIndented : True := by
        skip
        trivial

theorem underIndented : True := by
 skip
 trivial

theorem nested : True ∧ True := by
      constructor
      · skip
        trivial
      · trivial

theorem withComment : True := by
        skip
        -- a reason, not whitespace: it must survive unmoved on its own line, shifted with the block
        trivial

theorem withString : True := by
        have s : String := "line one
line two"
        trivial

theorem inlineKept : True := by trivial
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/blocks.lean" "blocks.lean" 8589934592 >"$work/blocks.json"

# Re-index is width-independent (reindentBlock takes no margin), so every margin produces the *same*
# output -- a property that distinguishes it from reflow and that a width leak would break. Format at
# the reflow margins and reparse each.
block_margins="0 1 40 80 100 1000"
for w in $block_margins; do
  "$tests" printer-format "$work/blocks.json" "$work/blocks.lean" "$w" >"$work/blocks.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/blocks.$w.out" "blocks.lean" 8589934592 \
    >"$work/blocks.$w.json" 2>"$work/blocks.$w.err" || true
done

# The re-index fired: the over-margin-independent output is not a copy of its non-canonical input.
if diff -q "$work/blocks.lean" "$work/blocks.100.out" >/dev/null 2>&1; then
  printf 'FAIL RLF-BLOCKS did not re-index the non-canonical blocks; output equals input\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the non-canonical blocks were re-indexed (%s lines rewritten)\n' \
    "$(diff "$work/blocks.lean" "$work/blocks.100.out" | grep -c '^<')"
fi

# Width-independence: all six margins are byte-identical to one another.
blocks_width=
for w in $block_margins; do
  if ! diff -q "$work/blocks.0.out" "$work/blocks.$w.out" >/dev/null 2>&1; then
    printf 'FAIL RLF-BLOCKS output depends on the margin (%s differs from 0); re-index leaked a width\n' "$w" >&2
    diff -u "$work/blocks.0.out" "$work/blocks.$w.out" >&2
    failures=$((failures + 1))
    blocks_width=1
  fi
done
[[ -z $blocks_width ]] && printf '  ok   every margin (%s) produces identical output (re-index is width-independent)\n' "$block_margins"

# Parse-preservation: every output reparses to the SAME token stream as the input. A shift that broke a
# checkColEq between two tactics would fail to reparse or reparse to a different stream.
cat >"$work/blocks_verify.py" <<'PY'
import json, sys
work, margins = sys.argv[1], sys.argv[2].split()
def stream(lean, js):
    src = open(lean, 'rb').read()
    toks = json.load(open(js))['artifact']['source']['tokens']
    return [src[t[1]:t[2]].decode('utf8') for t in toks]
fails = 0
orig = stream(f"{work}/blocks.lean", f"{work}/blocks.json")
for w in margins:
    try:
        s = stream(f"{work}/blocks.{w}.out", f"{work}/blocks.{w}.json")
    except Exception as e:
        print(f"FAIL margin {w}: output did not reparse ({e})", file=sys.stderr); fails += 1; continue
    if s != orig:
        print(f"FAIL margin {w}: token stream differs from the input (a tactic fell out of its block)", file=sys.stderr)
        fails += 1
if fails == 0:
    print(f"  ok   every margin reparses to the input's token stream (checkColEq preserved)")
sys.exit(fails)
PY
if python3 "$work/blocks_verify.py" "$work" "$block_margins"; then :; else failures=$((failures + $?)); fi

# The canonical columns, read off the width-independent output (margin 100). Every re-indexed block's
# first tactic lands at column 2; the nested block's bullets share column 2 and their continuation lands
# at column 4 (colGt the bullet), the uniform shift preserving the offside relationships.
out="$work/blocks.100.out"
if grep -qxE '  skip' "$out" && grep -qxE '  trivial' "$out" && grep -qxE '  constructor' "$out" &&
  grep -qxE '  · skip' "$out" && grep -qxE '    trivial' "$out"; then
  printf '  ok   every block sits at column 2; nested bullets at 2, their continuations at 4 (colEq/colGt)\n'
else
  printf 'FAIL a re-indexed block did not land at its canonical column:\n' >&2
  cat "$out" >&2
  failures=$((failures + 1))
fi

# A comment inside a block is not whitespace: it survives, on its own line, shifted with the block.
if grep -qxF '  -- a reason, not whitespace: it must survive unmoved on its own line, shifted with the block' "$out"; then
  printf '  ok   a comment inside a block survives and shifts with it (never dropped, never re-columned)\n'
else
  printf 'FAIL the comment inside withComment was dropped or moved off the block column:\n' >&2
  cat "$out" >&2
  failures=$((failures + 1))
fi

# A multi-line string is a token interior: its second line is the token's *value* and stays byte-exact
# at column 0, unmoved by the block's shift (Doc.lean:62-68, the reason verbatim exists).
if grep -qxF 'line two"' "$out"; then
  printf '  ok   a multi-line string in a tactic keeps its interior byte-exact (unmoved by the shift)\n'
else
  printf 'FAIL the multi-line string interior was re-indented; a token value was rewritten:\n' >&2
  cat "$out" >&2
  failures=$((failures + 1))
fi

# The inline block keeps its bytes: `by trivial` on one line has a first token that does not begin its
# line (safety condition A, notes/08 §1a), so it is never re-indexed -- the counterexample's guard.
if grep -qxF 'theorem inlineKept : True := by trivial' "$out"; then
  printf '  ok   an inline `by trivial` is left alone (its first token does not begin a line)\n'
else
  printf 'FAIL the inline block was touched; condition A (firstOnLine) did not hold it back:\n' >&2
  cat "$out" >&2
  failures=$((failures + 1))
fi

# Idempotence at every margin: reformat each output at the same margin; byte-identical. The canonical
# base is a pure function of nesting depth, so the second pass recomputes it and changes nothing.
blocks_idem=
for w in $block_margins; do
  "$tests" printer-format "$work/blocks.$w.json" "$work/blocks.$w.out" "$w" >"$work/blocks.$w.out2"
  if ! diff -q "$work/blocks.$w.out" "$work/blocks.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL RLF-BLOCKS: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/blocks.$w.out" "$work/blocks.$w.out2" >&2
    failures=$((failures + 1))
    blocks_idem=1
  fi
done
[[ -z $blocks_idem ]] && printf '  ok   RLF-BLOCKS: formatting twice is byte-identical at every margin (%s)\n' "$block_margins"

# --- do blocks: the same capability over `Term.do`, and the base formula's two hard cases ---
#
# `by` and `do` bodies are both `sepByIndent` sequences with no external checkColGt (tacticSeq1Indented
# under byTactic; doSeqIndent under Term.do), so the same uniform re-index applies. What `do` adds to
# the fixtures above is the *base formula's* two failure modes, which `by` alone did not exercise:
#   * `wrapped` -- a multi-line signature lands `:= do` on a continuation line indented past the
#     command (col 4), yet the body's canonical column is commandIndent+2 = 2, NOT the keyword line's
#     4+2. The base is the offside *parent* (the command), read by climbing to the line-leading
#     ancestor at the command's own column, not the physical line the keyword sits on.
#   * `keptHead` -- an own-line `Id.run do` head is line-leading at commandIndent+2, a column this
#     layout does not own (it is neither a match arm nor the command header), so the block keeps its
#     bytes: the conservative fallback, pinned here as a deliberately non-canonical block left alone.
# `Id` is a pure monad, so the fixture needs no IO and reparses under the borrowed setup.
printf -- '--- do blocks (RLF-BLOCKS over Term.do) ---\n'
cat >"$work/doblocks.lean" <<'FIXTURE'
module

def direct : Id Nat := do
        let x := 1
        pure x

def wrapped (a : Nat) (b : Nat)
    (c : Nat) : Id Nat := do
        pure (a + b + c)

def keptHead : Nat :=
    Id.run do
        pure 0
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/doblocks.lean" "doblocks.lean" 8589934592 >"$work/doblocks.json"
for w in $block_margins; do
  "$tests" printer-format "$work/doblocks.json" "$work/doblocks.lean" "$w" >"$work/doblocks.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/doblocks.$w.out" "doblocks.lean" 8589934592 \
    >"$work/doblocks.$w.json" 2>/dev/null || true
done

# The re-index fired on the two command-parented do blocks (direct + wrapped).
if diff -q "$work/doblocks.lean" "$work/doblocks.100.out" >/dev/null 2>&1; then
  printf 'FAIL RLF-BLOCKS did not re-index the non-canonical do blocks; output equals input\n' >&2
  failures=$((failures + 1))
else
  printf '  ok   the non-canonical do blocks were re-indexed (%s lines rewritten)\n' \
    "$(diff "$work/doblocks.lean" "$work/doblocks.100.out" | grep -c '^<')"
fi

# Width-independence.
do_width=
for w in $block_margins; do
  if ! diff -q "$work/doblocks.0.out" "$work/doblocks.$w.out" >/dev/null 2>&1; then
    printf 'FAIL do-block re-index depends on the margin (%s differs from 0)\n' "$w" >&2
    failures=$((failures + 1))
    do_width=1
  fi
done
[[ -z $do_width ]] && printf '  ok   every margin (%s) produces identical output (width-independent)\n' "$block_margins"

# Parse-preservation across margins: same token stream as the input.
python3 - "$work" "$block_margins" <<'PY'
import json, sys
work, margins = sys.argv[1], sys.argv[2].split()
def stream(lean, js):
    src = open(lean, 'rb').read()
    toks = json.load(open(js))['artifact']['source']['tokens']
    return [src[t[1]:t[2]].decode('utf8') for t in toks]
orig = stream(f"{work}/doblocks.lean", f"{work}/doblocks.json")
fails = 0
for w in margins:
    try:
        s = stream(f"{work}/doblocks.{w}.out", f"{work}/doblocks.{w}.json")
    except Exception as e:
        print(f"FAIL do margin {w}: output did not reparse ({e})", file=sys.stderr); fails += 1; continue
    if s != orig:
        print(f"FAIL do margin {w}: token stream differs from the input", file=sys.stderr); fails += 1
if fails == 0:
    print("  ok   every margin reparses to the input's token stream (parse-preserving)")
sys.exit(fails)
PY
if [[ $? -ne 0 ]]; then failures=$((failures + 1)); fi

# The base formula's two cases, read off margin 100. `direct` and `wrapped` land at column 2 (the
# command's offside child), and `wrapped` proves the base is NOT the keyword line's indent+2 (=6);
# `keptHead`'s body is left at its non-canonical column 8 (conservative fallback, bytes kept).
do_out="$work/doblocks.100.out"
if grep -qxE '  let x := 1' "$do_out" && grep -qxE '  pure x' "$do_out" &&
  grep -qxE '  pure \(a \+ b \+ c\)' "$do_out"; then
  printf '  ok   direct and wrapped-signature do bodies land at column 2 (offside parent = command, not keyword line)\n'
else
  printf 'FAIL a do body did not land at its canonical column 2:\n' >&2
  cat "$do_out" >&2
  failures=$((failures + 1))
fi
if grep -qxE '        pure 0' "$do_out"; then
  printf '  ok   the own-line `Id.run do` head is a column this layout does not own; its body keeps its bytes (conservative fallback)\n'
else
  printf 'FAIL the Id.run do body was re-indexed; the conservative fallback did not hold:\n' >&2
  cat "$do_out" >&2
  failures=$((failures + 1))
fi

# Idempotence at every margin.
do_idem=
for w in $block_margins; do
  "$tests" printer-format "$work/doblocks.$w.json" "$work/doblocks.$w.out" "$w" >"$work/doblocks.$w.out2"
  if ! diff -q "$work/doblocks.$w.out" "$work/doblocks.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL do-block re-index is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/doblocks.$w.out" "$work/doblocks.$w.out2" >&2
    failures=$((failures + 1))
    do_idem=1
  fi
done
[[ -z $do_idem ]] && printf '  ok   do blocks: formatting twice is byte-identical at every margin (%s)\n' "$block_margins"

# --- match arms: offside re-index of a `by` block that is a match arm's RHS (RLF-OPERATOR-BREAK) ---
#
# `matchAlt` is NOT a β-break (`notes/09` §1.3/§4): its arms are already one-per-line by `matchAlts`'
# `sepByIndent`, and it leads with a token a β-break would split. What IS laid out is a `by`/`do` block
# that is a match arm's RHS -- `reindentClaims` (Printer.lean:1475) reads the arm as the offside parent
# and re-indexes the block to arm-col+2, exactly as it re-indexes a declaration-level block to
# commandIndent+2. A pure-term arm (no tactic/do block) and the arm placement itself keep their bytes:
# a multi-line match is `mayCollapse=false` and `matchAlts` owns the `|` columns. This fixture pins the
# arm-relative re-index (the over-indented `by` under `| 0 =>`) and the conservative pure-term arm.
printf -- '--- match arms, arm-relative block re-index (RLF-OPERATOR-BREAK) ---\n'
cat >"$work/matcharm.lean" <<'FIXTURE'
module

def wmatch (n : Nat) : True :=
  match n with
  | 0 => by
              skip
              trivial
  | _ => by trivial

def wterm (n : Nat) : Nat :=
  match n with
  | 0 => 1
  | _ => n
FIXTURE
LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
  "$work/borrowed.setup.json" "$work/matcharm.lean" "matcharm.lean" 8589934592 1 >"$work/matcharm.json"

marm_margins="40 80 100 1000"
for w in $marm_margins; do
  "$tests" printer-format "$work/matcharm.json" "$work/matcharm.lean" "$w" >"$work/matcharm.$w.out"
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/matcharm.$w.out" "matcharm.lean" 8589934592 1 \
    >"$work/matcharm.$w.json" 2>"$work/matcharm.$w.err" || true
done

# The over-indented `by` under `| 0 =>` re-indexes to arm-col+2 = 4; the pure-term arm and the `|`
# columns are untouched. The re-index is width-independent, so every margin produces the same output.
if grep -qE '^  \| 0 => by$' "$work/matcharm.100.out" &&
  grep -qE '^    skip$' "$work/matcharm.100.out" &&
  grep -qE '^    trivial$' "$work/matcharm.100.out" &&
  grep -qE '^  \| _ => n$' "$work/matcharm.100.out"; then
  printf '  ok   a `by` block inside a match arm re-indexes to arm-col+2; the pure-term arm is kept\n'
else
  printf 'FAIL the match-arm block did not re-index to arm-col+2 (or the term arm was touched)\n' >&2
  cat "$work/matcharm.100.out" >&2
  failures=$((failures + 1))
fi

# Parse-preservation, token AND tree, at every margin -- a re-index that moved a tactic between arms
# would reparent it (a re-association the token stream hides), which the tree gate catches.
marm_pp=
for w in $marm_margins; do
  if ! python3 "$repo_root/experiments/compare_tokens.py" \
    "$work/matcharm.json" "$work/matcharm.$w.json" "$work/matcharm.lean" "$work/matcharm.$w.out" \
    >"$work/matcharm.$w.pp" 2>&1; then
    printf 'FAIL match arm at margin %s changed the parse: %s\n' "$w" "$(cat "$work/matcharm.$w.pp")" >&2
    failures=$((failures + 1))
    marm_pp=1
  fi
done
if [[ -z $marm_pp ]]; then
  printf '  ok   every margin (%s) reparses to the input token stream AND tree (no re-association)\n' "$marm_margins"
fi

# Idempotence: the arm-relative base is a pure function of the arm column, so a second pass recomputes it.
marm_idem=
for w in $marm_margins; do
  "$tests" printer-format "$work/matcharm.$w.json" "$work/matcharm.$w.out" "$w" >"$work/matcharm.$w.out2"
  if ! diff -q "$work/matcharm.$w.out" "$work/matcharm.$w.out2" >/dev/null 2>&1; then
    printf 'FAIL match arm: formatting is not idempotent at margin %s:\n' "$w" >&2
    diff -u "$work/matcharm.$w.out" "$work/matcharm.$w.out2" >&2
    failures=$((failures + 1))
    marm_idem=1
  fi
done
[[ -z $marm_idem ]] && printf '  ok   match arm: formatting twice is byte-identical at every margin (%s)\n' "$marm_margins"

# --- non-vacuity: the parse-preservation gate rejects a re-association (RLF-ACCEPT) ---
#
# The gate the frozen-sample differential leans on (`experiments/compare_tokens.py`) must be *able* to
# fail, or it certifies nothing. The subtle failure it has to catch is a re-association: an offside
# re-index that moves a tactic from an inner `by` block to the outer one. `RLF-BLOCKS` provably never
# emits this — it shifts a whole block by a uniform delta, which preserves every column relation and so
# the parse tree (`notes/06` RLF-OFFSIDE) — but a formatter *bug* could, and the gate is the backstop.
#
# The trap is that a re-association emits the *same tokens in the same order*: `good` and `bad` below
# have identical token streams (asserted), so a token-only comparison is blind to it. What differs is
# the tree: the moved `skip` acquires a different parent. `compare_tokens.py` compares the node
# `(kind, parent)` sequence for exactly this reason, and this fixture is what proves that comparison is
# not vacuous — it rejects `bad` and accepts an identical-to-itself `good`.
printf -- '--- non-vacuity: the gate rejects a re-association the tokens hide (RLF-ACCEPT) ---\n'
cat >"$work/reassoc_good.lean" <<'FIXTURE'
module

theorem t : True := by
  have h : True := by
    trivial
    skip
  exact h
FIXTURE
# `bad` moves `skip` out of the inner `by` (the `have`'s proof) into the outer sequence: same tokens,
# different tree. This is what a broken re-index would produce, hand-written so the test owns the defect.
cat >"$work/reassoc_bad.lean" <<'FIXTURE'
module

theorem t : True := by
  have h : True := by
    trivial
  skip
  exact h
FIXTURE
for v in good bad; do
  LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
    "$work/borrowed.setup.json" "$work/reassoc_$v.lean" "reassoc_$v.lean" 8589934592 \
    >"$work/reassoc_$v.json" 2>/dev/null
done
# 1. The tokens are identical — a token-only gate cannot tell these two apart.
if python3 - "$work" <<'PY'; then :; else failures=$((failures + 1)); fi
import json, sys
work = sys.argv[1]
def stream(v):
    src = open(f"{work}/reassoc_{v}.lean", 'rb').read()
    toks = json.load(open(f"{work}/reassoc_{v}.json"))['artifact']['source']['tokens']
    return [src[t[1]:t[2]].decode('utf8') for t in toks]
g, b = stream('good'), stream('bad')
if g == b:
    print(f"  ok   the re-association leaves the token stream identical ({len(g)} tokens) — a token-only gate is blind to it")
    sys.exit(0)
print(f"FAIL the fixtures differ in tokens ({g} vs {b}); the non-vacuity premise does not hold", file=sys.stderr)
sys.exit(1)
PY
# 2. The tree gate REJECTS the re-association (must exit nonzero).
if python3 "$repo_root/experiments/compare_tokens.py" \
  "$work/reassoc_good.json" "$work/reassoc_bad.json" \
  "$work/reassoc_good.lean" "$work/reassoc_bad.lean" >"$work/reassoc.out" 2>&1; then
  printf 'FAIL the parse-preservation gate accepted a re-association; it is vacuous:\n' >&2
  cat "$work/reassoc.out" >&2
  failures=$((failures + 1))
else
  if grep -q 'parse tree changed' "$work/reassoc.out"; then
    printf '  ok   the gate rejects the re-association on the tree (%s)\n' "$(cat "$work/reassoc.out")"
  else
    printf 'FAIL the gate rejected the pair, but not for the tree reason:\n' >&2
    cat "$work/reassoc.out" >&2
    failures=$((failures + 1))
  fi
fi
# 3. Sanity: the gate ACCEPTS an identical pair (no false positive on a real no-op).
if python3 "$repo_root/experiments/compare_tokens.py" \
  "$work/reassoc_good.json" "$work/reassoc_good.json" \
  "$work/reassoc_good.lean" "$work/reassoc_good.lean" >/dev/null 2>&1; then
  printf '  ok   the gate accepts an identical pair (no false positive)\n'
else
  printf 'FAIL the gate rejected an identical pair; it would reject legitimate no-op reformats\n' >&2
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
[[ $failures -eq 0 ]]
