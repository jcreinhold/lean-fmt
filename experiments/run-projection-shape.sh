#!/usr/bin/env bash
set -euo pipefail

# What shape is the projection, really? — `RLF-COMMANDS` characterization.
#
# `notes/01-command-printing.md` decides where the printer reads its tree from, and that decision rests
# on four properties of `LosslessSource` that are claims about real parser output, not about the
# structure definition. This script measures them rather than arguing them.
#
#   1. Is each node's subtree a contiguous index range?  (If not, no tree view is reconstructable.)
#   2. Among a parent's node-children that carry tokens, does index order agree with byte order?
#   3. How many nodes carry no token at all?  (Empty optional slots — they have no position.)
#   4. Of those, how many sit under a parent that also has direct token children?  (Their arg position
#      is then unrecoverable from ranges: the printer cannot place them by position, and must know the
#      grammar. This is the number that decides the interface.)
#
# 1 and 2 are read off `collect`'s code; measuring them checks the reading. 3 and 4 cannot be read off
# the code at all — they are facts about how much of real Lean syntax is absence.
#
# 2 is deliberately *not* "are children in arg order". Index order is the only order the projection
# retains, so that question compares index order against itself and is vacuous — the first draft asked
# it and reported 0 for every possible input. Arg order is guaranteed by `collect`'s code and is not
# observable in its output; byte order is observable, and disagreeing with it is the failure a fold
# over args in the wrong order would actually produce.
#
# This repository's own modules are the corpus: the question is structural, so code nobody wrote for
# the rule buys nothing here, and `RLS-FINAL` already profiled the frozen mathlib sample for the
# properties where corpus independence *does* matter. Full mathlib is forbidden and is not run.
#
# usage: run-projection-shape.sh [OUT]

repo_root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$repo_root/docs/projects/ruff-03-language-formatting/evidence/01-projection-shape.txt"}

application="$repo_root/.lake/build/bin/lean-fmt"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cd "$repo_root"
mkdir -p "$(dirname "$out")"

modules=$(git ls-files 'LeanFmt/*.lean' 'LeanFmt.lean' 'Main.lean' | sort)

envelopes="$scratch/envelopes"
mkdir -p "$envelopes"
analyzed=0
skipped=0

for source in $modules; do
  setup="$scratch/setup.json"
  envelope="$envelopes/$(echo "$source" | tr '/' '_').json"

  if ! LEAN_NUM_THREADS=1 lake setup-file "$source" >"$setup" 2>"$scratch/setup.err"; then
    skipped=$((skipped + 1))
    continue
  fi
  if ! LEAN_NUM_THREADS=1 lake env "$application" __analyze-exact \
      "$setup" "$source" "$source" 8589934592 >"$envelope" 2>"$scratch/analyze.err"; then
    skipped=$((skipped + 1))
    rm -f "$envelope"
    continue
  fi
  analyzed=$((analyzed + 1))
done

python3 - "$envelopes" "$analyzed" "$skipped" <<'PY' | tee "$out"
import json, os, sys
from collections import defaultdict

envelopes, analyzed, skipped = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

modules = 0
total_nodes = 0
contiguity_violations = 0
argorder_violations = 0
empty_nodes = 0
empty_ambiguous = 0
kind_census = defaultdict(int)

for name in sorted(os.listdir(envelopes)):
    envelope = json.load(open(os.path.join(envelopes, name)))
    artifact = envelope.get("artifact")
    if not artifact or envelope.get("diagnostics"):
        continue
    source = artifact["source"]
    nodes, tokens, kinds = source["nodes"], source["tokens"], source["kinds"]
    modules += 1
    total_nodes += len(nodes)

    # `LosslessSource.lean:156` encodes Node as [kind, parent, range.start, range.stop] and Token as
    # [node, start, stop, info, leading, trailing]. Read the encoding, do not guess it.
    def parent_of(n):
        return n[1]

    children = defaultdict(list)
    for i, n in enumerate(nodes):
        p = parent_of(n)
        if p is not None:
            children[p].append(i)

    token_children = defaultdict(list)
    for t in tokens:
        token_children[t[0]].append(t)

    # Does any token live under this node? Walk each token up to the root, stopping at the first node
    # already marked, so the whole pass is linear.
    has_token_pre = [False] * len(nodes)
    for t in tokens:
        j = t[0]
        while j is not None and not has_token_pre[j]:
            has_token_pre[j] = True
            j = parent_of(nodes[j])

    # (1) contiguity: the subtree of j is exactly [j, j+size(j)). Computed bottom-up over a pre-order
    # array: a node's subtree ends where its last descendant does.
    end = list(range(1, len(nodes) + 1))
    for i in range(len(nodes) - 1, -1, -1):
        for c in children[i]:
            end[i] = max(end[i], end[c])
    for i, n in enumerate(nodes):
        for c in children[i]:
            if not (i < c < end[i]):
                contiguity_violations += 1
        # every index strictly inside [i, end[i]) must have i as an ancestor
        for j in range(i + 1, end[i]):
            a, ok = parent_of(nodes[j]), False
            while a is not None:
                if a == i:
                    ok = True
                    break
                a = parent_of(nodes[a])
            if not ok:
                contiguity_violations += 1
                break

    # (2) index order agrees with source order, for the children where source order is observable.
    #
    # NOTE: "children appear in arg order" is NOT checkable from the projection. The projection stores
    # only `parent`, so index order is the single order it retains — comparing it against itself is
    # vacuous, and an earlier draft of this script did exactly that and always reported 0. Arg order is
    # a property of `collect`, which pushes a node's placeholder at `build.nodes.size` before folding
    # its args left to right; that is read off the code, not measured here.
    #
    # What IS observable: among a parent's node-children that carry tokens, index order must agree with
    # byte order. That can fail, and it is the check that would catch `collect` folding args out of
    # order.
    for i in children:
        spans = [(nodes[c][2], nodes[c][3]) for c in children[i] if has_token_pre[c]]
        starts = [s for s, _ in spans]
        if starts != sorted(starts):
            argorder_violations += 1

    # (3)/(4) empty nodes, and whether their placement among siblings is recoverable
    has_token = has_token_pre
    for i, n in enumerate(nodes):
        if not has_token[i]:
            empty_nodes += 1
            kind_census[kinds[n[0]]] += 1
            p = parent_of(n)
            if p is not None and token_children[p]:
                empty_ambiguous += 1

print(f"modules_analyzed={modules} skipped={skipped} nodes={total_nodes}")
print(f"pre_order_contiguity_violations={contiguity_violations}")
print(f"nonempty_node_children_out_of_source_order={argorder_violations}")
pct = (100.0 * empty_nodes / total_nodes) if total_nodes else 0.0
print(f"empty_nodes={empty_nodes} ({pct:.1f}% of all nodes)")
apct = (100.0 * empty_ambiguous / total_nodes) if total_nodes else 0.0
print(f"empty_nodes_with_ambiguous_placement={empty_ambiguous} ({apct:.1f}% of all nodes)")
print()
print("# most common empty (absent-syntax) kinds")
for kind, count in sorted(kind_census.items(), key=lambda kv: -kv[1])[:10]:
    print(f"{count}\t{kind}")

# The two properties the tree view depends on are hard failures.
if contiguity_violations or argorder_violations:
    sys.exit(1)
PY
