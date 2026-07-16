#!/usr/bin/env bash
set -euo pipefail

# Where does real Lean put a blank line? — `RLF-TACTICS` design B, checked without this repository's code.
#
# `notes/03-tactics.md` §8 designs one change a formatter can make to a tactic block without moving a
# column: rewrite the newline run inside a separator gap to a single newline. `tactic_blank_gaps`
# (`evidence/01-printer-sample.txt`) measures what that would rewrite and reports **0** across 62
# modules and 1,966 blocks.
#
# A 0 wants two independent kinds of support, because a broken counter reports it just as readily:
#
#   1. **That the counter can count.** `tests/printer/run.sh` hand-counts a written fixture (3) through
#      the same code path, and two mutations of the counter both move that 3.
#   2. **That the 0 is a fact about Lean rather than about this project's code.** That is this script.
#      It never loads the projection, the printer, or Lean — it reads the sample's bytes as lines and
#      asks where blank lines sit. If the two paths disagree, one of them is wrong and the counter is
#      the likelier suspect.
#
# The shape it looks for is the one design B needs: a blank line whose neighbours are both indented.
# A blank line between two tactics has one — both tactics sit at the block's column, which is > 0
# inside any `by`. The histogram below is the whole answer and it is sharper than the counter's: every
# blank line in the sample is followed by a **column-0** line. Blank lines in real Lean *end* an
# indented block; none sits inside one. So there is nothing for design B to rewrite, and the reason is
# structural rather than a scarcity that a bigger sample might turn up.
#
# usage: run-blank-column-census.sh [MATHLIB_ROOT] [SOURCES] [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
mathlib_root=${1:-"$HOME/Code/mathlib4"}
sources=${2:-"$repo_root/experiments/workloads/mathlib-v4.32.0-sample.txt"}
out=${3:-"$repo_root/docs/projects/ruff-03-language-formatting/evidence/03-blank-line-columns.txt"}

mkdir -p "$(dirname "$out")"

MATHLIB_ROOT="$mathlib_root" SOURCES="$sources" python3 - <<'CENSUS' | tee "$out"
import os
from collections import Counter

root = os.environ["MATHLIB_ROOT"]
srcs = [l.strip() for l in open(os.environ["SOURCES"]) if l.strip()]

hist, examples = Counter(), {}
blank_total = modules = 0
for s in srcs:
    modules += 1
    lines = open(os.path.join(root, s)).read().split("\n")
    for i in range(1, len(lines) - 1):
        if lines[i].strip() != "":
            continue
        blank_total += 1
        # The nearest non-blank line on each side: a run of two blank lines is one gap, not two.
        p = i - 1
        while p >= 0 and lines[p].strip() == "":
            p -= 1
        n = i + 1
        while n < len(lines) and lines[n].strip() == "":
            n += 1
        if p < 0 or n >= len(lines):
            continue
        cols = (len(lines[p]) - len(lines[p].lstrip()), len(lines[n]) - len(lines[n].lstrip()))
        hist[cols] += 1
        examples.setdefault(cols, f"{s}:{i + 1}")

inside = sum(v for (pc, nc), v in hist.items() if pc > 0 and nc > 0)
print(f"modules={modules} blank_lines={blank_total} blank_gaps={sum(hist.values())} "
      f"gaps_between_two_indented_lines={inside}")
print()
print("# every blank gap, by the indentation of the non-blank line above and below it")
for (pc, nc), v in sorted(hist.items(), key=lambda kv: -kv[1]):
    print(f"prev_col={pc:>3} next_col={nc:>3}  count={v:>6}  eg {examples[(pc, nc)]}")
print()
print("# `next_col` is 0 in every row. A blank line in this sample always precedes a top-level line --")
print("# it ends an indented block rather than sitting inside one -- so `gaps_between_two_indented_lines`")
print("# is 0 and no blank line in the sample falls between two tactics. The `prev_col` spread is the")
print("# other half of the same fact: those are the blank lines *after* a proof, and the column is how")
print("# deep the proof's last line was.")
CENSUS
