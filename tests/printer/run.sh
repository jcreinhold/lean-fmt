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
