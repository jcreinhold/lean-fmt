#!/usr/bin/env bash
set -euo pipefail

# Does the printer survive code nobody wrote for it? — `RLF-COMMANDS` independence.
#
# `tests/printer/run.sh` runs the printer over this repository's own modules, and that corpus has a
# structural weakness no amount of care removes: I wrote it, so it is already formatted the way the
# layouts format it. `evidence/01-projection-shape.txt` measures the consequence — 0 of its 260
# constructor and field shells hold collapsible slack — which means the corpus can show that the
# layouts *run* but never that they *decide*. Its fixtures fill that gap with source written to be
# wrong, and a fixture is still something I thought of.
#
# The frozen mathlib sample is not. It is foreign Lean pinned at v4.32.0 by `RLS-FINAL`, and it is
# where a guard that wrongly *accepts* corrupts real bytes. Complete mathlib is forbidden
# (`RLF-COMMANDS` stop rules); this is the frozen sample only.
#
# **What is checked here, and why it is not byte identity.** The obvious check — format and diff
# against the input — is the one `printer-roundtrip` makes, and it is wrong for this corpus. It
# asserts the printer is the *identity*, which holds only for source already in canonical form. This
# repository's is; mathlib's is not, and must not be expected to be. The first draft of this script
# made that mistake and reported 7 of 29 modules "failing" when what they were doing was being
# formatted: `@[simp] theorem foo` becoming two lines is the declaration layout working, not a defect.
#
# The two properties that *are* true of a formatter on arbitrary input:
#
#   1. **Idempotence.** `format(format(x)) = format(x)`. A rule that adds a line every pass, or
#      oscillates, fails here and cannot fail a golden.
#   2. **Information preservation.** The formatted text must parse back to the same tokens, in the
#      same order, with the same text — and to the same comments. This is the real losslessness claim,
#      and it is the one that catches a guard which wrongly accepts: a dropped comment or a swallowed
#      token shows up here and nowhere else.
#
# That second check is what found the header layout deleting a blank line between mathlib's
# `public import`s and its plain `import`s — a shape no header in this repository has.
#
# usage: run-printer-sample.sh [MATHLIB_ROOT] [SOURCES] [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
out=${3:-"$repo_root/docs/projects/ruff-03-language-formatting/evidence/01-printer-sample.txt"}

application="$repo_root/.lake/build/bin/lean-fmt"
tests="$repo_root/.lake/build/bin/lean-fmt-tests"
compare="$repo_root/experiments/compare_tokens.py"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

for binary in "$application" "$tests"; do
  if [[ ! -x "$binary" ]]; then
    printf 'missing %s; run `LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests` first\n' \
      "$binary" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$out")"
report="$scratch/report"
: >"$report"
: >"$scratch/unclaimed"

analyzed=0
skipped=0
failures=0
changed=0
total_commands=0
total_canonical=0
total_members=0
total_headers=0
total_app_slack=0
total_binder_slack=0
total_match_slack=0
total_tactic_blocks=0
total_tactic_ownable=0
total_tactic_ownable_own_line=0
total_tactic_ownable_at_two=0
total_tactic_blank_gaps=0

field() {
  printf '%s' "$2" | tr ' ' '\n' | sed -n "s/^$1=\([0-9]*\)$/\1/p"
}

cd "$mathlib_root"
while read -r source; do
  [[ -n "$source" ]] || continue
  setup="$scratch/setup.json"

  if ! LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\tsetup-file failed\n' "$source" >>"$report"
    continue
  fi
  if ! LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$setup" "$source" "$source" 8589934592 >"$scratch/env1.json" 2>"$scratch/err"; then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\tanalyze failed\n' "$source" >>"$report"
    continue
  fi
  # A module that did not analyze is not a printer result either way. It is reported as skipped and
  # excluded from every total below, because counting it as a pass would be worse than counting it as
  # a failure.
  if ! line=$("$tests" printer-report "$scratch/env1.json" "$source" 2>"$scratch/err"); then
    skipped=$((skipped + 1))
    printf 'skipped\t%s\t%s\n' "$source" "$(tail -1 "$scratch/err")" >>"$report"
    continue
  fi

  "$tests" printer-format "$scratch/env1.json" "$source" 80 >"$scratch/out1.lean"

  # Pass two, on the output of pass one, with the same setup borrowed.
  if ! LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$setup" "$scratch/out1.lean" "$source" 8589934592 >"$scratch/env2.json" 2>"$scratch/err"; then
    failures=$((failures + 1))
    printf 'FAIL\t%s\tformatted output does not analyze\n' "$source" >>"$report"
    continue
  fi
  "$tests" printer-format "$scratch/env2.json" "$scratch/out1.lean" 80 >"$scratch/out2.lean"

  verdict=ok
  if ! cmp -s "$scratch/out1.lean" "$scratch/out2.lean"; then
    failures=$((failures + 1))
    printf 'FAIL\t%s\tnot idempotent\n' "$source" >>"$report"
    verdict=bad
  fi
  if ! loss=$(python3 "$compare" "$scratch/env1.json" "$scratch/env2.json" "$source" "$scratch/out1.lean" 2>&1); then
    failures=$((failures + 1))
    printf 'FAIL\t%s\t%s\n' "$source" "$loss" >>"$report"
    verdict=bad
  fi
  [[ "$verdict" == ok ]] || continue

  analyzed=$((analyzed + 1))
  # Which kinds the layouts refused. `canonical` counts the claims; on this sample it is about half of
  # `commands` against 95% on this repository, and the percentage alone cannot say whether that is
  # grammar nobody has read yet or a guard refusing what it was built to claim.
  "$tests" printer-unclaimed "$scratch/env1.json" "$source" >>"$scratch/unclaimed"
  cmp -s "$source" "$scratch/out1.lean" || changed=$((changed + 1))
  total_commands=$((total_commands + $(field commands "$line")))
  total_canonical=$((total_canonical + $(field canonical "$line")))
  total_members=$((total_members + $(field members "$line")))
  total_headers=$((total_headers + $(field header_canonical "$line")))
  total_app_slack=$((total_app_slack + $(field app_slack "$line")))
  total_binder_slack=$((total_binder_slack + $(field binder_slack "$line")))
  total_match_slack=$((total_match_slack + $(field match_slack "$line")))
  total_tactic_blocks=$((total_tactic_blocks + $(field tactic_blocks "$line")))
  total_tactic_ownable=$((total_tactic_ownable + $(field tactic_ownable "$line")))
  total_tactic_ownable_own_line=$((total_tactic_ownable_own_line + $(field tactic_ownable_own_line "$line")))
  total_tactic_ownable_at_two=$((total_tactic_ownable_at_two + $(field tactic_ownable_at_two "$line")))
  total_tactic_blank_gaps=$((total_tactic_blank_gaps + $(field tactic_blank_gaps "$line")))
  printf 'ok\t%s\t%s\n' "$source" "$line" >>"$report"
done <"$sources"

{
  printf 'modules_analyzed=%s skipped=%s failures=%s reformatted=%s\n' \
    "$analyzed" "$skipped" "$failures" "$changed"
  printf 'commands=%s canonical=%s members=%s headers_canonical=%s app_slack=%s binder_slack=%s match_slack=%s\n' \
    "$total_commands" "$total_canonical" "$total_members" "$total_headers" "$total_app_slack" \
    "$total_binder_slack" "$total_match_slack"
  printf 'tactic_blocks=%s tactic_ownable=%s tactic_ownable_own_line=%s tactic_ownable_at_two=%s ' \
    "$total_tactic_blocks" "$total_tactic_ownable" "$total_tactic_ownable_own_line" \
    "$total_tactic_ownable_at_two"
  printf 'tactic_blank_gaps=%s\n' "$total_tactic_blank_gaps"
  printf '\n# `reformatted` is how many modules the printer changed at all. It is the number this\n'
  printf '# repository cannot produce: its own corpus is already canonical, so the layouts run there\n'
  printf '# and decide nothing. These are foreign modules, and every one of them still parses back to\n'
  printf '# the same tokens and the same comments.\n'
  printf '\n# The three slack counters count the gaps where a term layout has something to do:\n'
  printf '# application gaps holding more than one space, and binder or match-alternative gaps whose\n'
  printf '# bytes are not the spacing the grammar declares (too tight counts too). All three are 0\n'
  printf '# here, across 11,679 applications, 3,851 binders and 121 alternatives\n'
  printf '# (`evidence/02-term-census.txt`) -- real Lean writes `f a`, `(x : Nat)` and `| 0 => 1`\n'
  printf '# already. So `reformatted` does not move when a term layout lands,\n'
  printf '# and that is the finding rather than a disappointment: the part of term formatting that is\n'
  printf '# citable today is the part that changes nothing on code people actually wrote. The part\n'
  printf '# that would change something is vertical, and needs a margin and `nest` first.\n'
  printf '#\n'
  printf '# A broken counter reports 0 just as readily, so no number here is believed on this\n'
  printf '# evidence alone: `tests/printer/run.sh` hand-counts all three against a written fixture\n'
  printf '# (7, 15 and 22) through this same code path.\n'
  printf '\n# The four tactic counters are `RLF-TACTICS`, and they are why it ships no tactic layout.\n'
  printf '# A re-indenting layout would rewrite a block as `nest 2` over `hard`-separated tactics\n'
  printf '# beginning a fresh line at column 2. `tactic_blank_gaps=0` says every separator is already\n'
  printf '# exactly one newline -- real Lean never blank-lines between two tactics -- so such a layout\n'
  printf '# emits the input on exactly the blocks that already begin their line at column 2, and\n'
  printf '# changes bytes on every other. Splitting `ownable` says which:\n'
  printf '#\n'
  printf '#   at_two                324  begins its line at column 2   -> the layout is the identity\n'
  printf '#   own_line - at_two     234  begins deeper, so NESTED      -> it would de-indent it out of\n'
  printf '#                                                               its parent: a broken parse\n'
  printf '#   ownable - own_line    864  begins inline (`:= by simp`)  -> it would wrap it, which needs\n'
  printf '#                                                               a margin nobody has set\n'
  printf '#\n'
  printf '# So its whole licensed reach is 324 of 1966 blocks, and on all 324 it produces the input.\n'
  printf '# The 1098 where it would *do* something are the 1098 where it has no right to. That also\n'
  printf '# sizes `ownable` as an upper bound: it overstates the licensed reach by 4.4x.\n'
  printf '#\n'
  printf '# `tactic_blank_gaps=0` has a second support that no mutation of this code could rescue:\n'
  printf '# `run-blank-column-census.sh` reads the sample as lines, never loading the projection or\n'
  printf '# the printer, and finds every one of its 3,041 blank lines followed by a column-0 line --\n'
  printf '# a blank line ends an indented block and never sits inside one.\n'
  printf '\n# what the layouts refused, by syntax kind (every command not counted in `canonical`).\n'
  printf '# A kind lands here for one of three unlike reasons -- a layout claims it and a runtime guard\n'
  printf '# said no, the pinned compiler declares it and no layout claims it, or the corpus being\n'
  printf '# formatted declared it and this printer cannot read its grammar at all. This report cannot\n'
  printf '# tell them apart; `experiments/kind-inventory.txt` is where each kind is assigned one and\n'
  printf '# given its citation, and `RLF-FINAL` gates this run against it, so a kind absent from it\n'
  printf '# fails here rather than appearing as one more line in a report nobody has to read.\n'
  sort "$scratch/unclaimed" | uniq -c | sort -rn
  printf '\n# every module that lost information or failed to converge\n'
  if grep -q '^FAIL' "$report"; then grep '^FAIL' "$report"; else printf 'none\n'; fi
  printf '\n# every module excluded, and why (excluded from the totals, not counted as a pass)\n'
  if grep -q '^skipped' "$report"; then grep '^skipped' "$report"; else printf 'none\n'; fi
  printf '\n# per module\n'
  grep '^ok' "$report" | cut -f2,3
} | tee "$out"

# --- the ownership gate ---------------------------------------------------------------------------
#
# `RLF-FINAL`: "zero silently unowned accepted syntax kinds in the frozen corpus". The refusals above
# were never *unsafe* -- an unclaimed command keeps its own bytes, which is the conservative path
# `tests/printer/run.sh` pins. They were silent: this script counted them and nothing compared the
# count to anything, so a kind arriving in the corpus produced one more line in a report with no
# reader. `experiments/kind-inventory.txt` gives every kind a disposition and a citation; this makes
# the report a check.
#
# **Both directions are fatal, and the second one is the point.** A kind in the corpus but not the
# inventory is the stop rule directly. A kind in the inventory but not the corpus is a sentence about
# this sample that is no longer true -- the exact rot that `notes/04-extensions.md` §5 refused a table
# for -- and catching it is what earns this file the right to exist. The inventory describes the
# *frozen* corpus; running this script over a different one is expected to fire.
inventory="$repo_root/experiments/kind-inventory.txt"
# `-E`: BSD sed's basic regex has no `\|` alternation, so a BRE here silently matches nothing, reports
# every kind as unowned, and reads like a real failure. Extended regex is portable across both seds.
sed -nE 's/^(guard|core|corpus)[[:space:]]+//p' "$inventory" | sort -u >"$scratch/owned"
sort -u "$scratch/unclaimed" >"$scratch/present"

if ! unowned=$(comm -23 "$scratch/present" "$scratch/owned") || [[ -n "$unowned" ]]; then
  printf '\nFAIL unowned syntax kind in the frozen corpus (RLF-FINAL stop rule).\n' >&2
  printf 'These kinds are refused by the printer and named nowhere in %s:\n' "$inventory" >&2
  printf '%s\n' "$unowned" | sed 's/^/  /' >&2
  printf 'Read the grammar, give each a disposition (guard/core/corpus) and a citation, and add it.\n' >&2
  failures=$((failures + 1))
fi

if ! dead=$(comm -13 "$scratch/present" "$scratch/owned") || [[ -n "$dead" ]]; then
  printf '\nFAIL %s claims a kind the frozen corpus does not contain:\n' "$inventory" >&2
  printf '%s\n' "$dead" | sed 's/^/  /' >&2
  printf 'The inventory is a claim about this sample. Remove the entry or explain the drift.\n' >&2
  failures=$((failures + 1))
fi

[[ "$failures" -eq 0 ]]
