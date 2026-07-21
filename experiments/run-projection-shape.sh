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

python3 - "$envelopes" "$analyzed" "$skipped" "$repo_root" <<'PY' | tee "$out"
import json, os, sys
from collections import defaultdict

envelopes, analyzed, skipped = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
repo_root = sys.argv[4]

modules = 0
total_nodes = 0
contiguity_violations = 0
argorder_violations = 0
empty_nodes = 0
empty_ambiguous = 0
kind_census = defaultdict(int)
command_census = defaultdict(int)
decl_census = defaultdict(int)
unread_shapes = defaultdict(int)
instance_shape = defaultdict(int)
member_census = defaultdict(int)
member_flat = defaultdict(int)
member_break = defaultdict(int)
member_singleton = defaultdict(int)
member_skipped = defaultdict(int)

for name in sorted(os.listdir(envelopes)):
    envelope = json.load(open(os.path.join(envelopes, name)))
    artifact = envelope.get("artifact")
    if not artifact or envelope.get("diagnostics"):
        continue
    source = artifact["source"]
    nodes, tokens, kinds = source["nodes"], source["tokens"], source["kinds"]
    modules += 1
    total_nodes += len(nodes)

    # The bytes the offsets index. Every range in the projection is a byte offset into the *normalized*
    # source (`raw.crlfToLf`), so read the file as bytes and normalize the same way — decoding to str
    # first would make the offsets index codepoints and silently skew every gap on a non-ASCII line.
    # `mainModule` is what names the file; the envelope filename would work too, but it is a `tr`ed
    # path and would lie about any module whose name contains an underscore.
    normalized = open(
        os.path.join(repo_root, source["mainModule"].replace(".", "/") + ".lean"), "rb"
    ).read().replace(b"\r\n", b"\n")
    assert len(normalized) == source["normalizedBytes"], source["mainModule"]

    # `LosslessSource.lean:156` encodes Node as [kind, parent, range.start, range.stop] and Token as
    # [node, start, stop, info, leading, trailing]. Read the encoding, do not guess it.
    def parent_of(n):
        return n[1]

    children = defaultdict(list)
    for i, n in enumerate(nodes):
        p = parent_of(n)
        if p is not None:
            children[p].append(i)
        else:
            # A command: `collect` is called per command, so a parentless node is one. This is the
            # inventory `RLF-COMMANDS`'s ownership table is built from — which kinds actually occur,
            # rather than which ones I remember Lean having.
            command_census[kinds[n[0]]] += 1

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

    # (5) Which declarations is the shell layout structurally able to claim, and why not the rest?
    #
    # This is the *structural* half of `Printer.lean`'s `declarationShell?` — the part that depends on
    # the shape of the tree — re-implemented against the same projection. It deliberately does NOT
    # model the runtime guards (clean trivia, newline-free tokens in the flat run, column 0), which
    # need the source bytes and the trivia runs. So this over-counts, and the honest figure for what
    # the printer actually lays out is `canonical=` from `tests/printer/run.sh`, which is the printer
    # counting itself. What this adds is the breakdown: *why* the rest are refused, which is what says
    # where the next layout should go.
    SHELL_SHAPES = {
        "Lean.Parser.Command.abbrev", "Lean.Parser.Command.definition",
        "Lean.Parser.Command.theorem", "Lean.Parser.Command.opaque",
        "Lean.Parser.Command.inductive", "Lean.Parser.Command.structure",
    }
    for i, n in enumerate(nodes):
        if parent_of(n) is not None or kinds[n[0]] != "Lean.Parser.Command.declaration":
            continue
        ch = children[i]
        if len(ch) != 2 or kinds[nodes[ch[0]][0]] != "Lean.Parser.Command.declModifiers":
            decl_census["rejected: not modifiers + shape"] += 1
        elif len(children[ch[0]]) != 7:
            decl_census["rejected: declModifiers is not 7 slots"] += 1
        elif kinds[nodes[ch[1]][0]] not in SHELL_SHAPES:
            decl_census["rejected: shape not read yet"] += 1
            unread_shapes[kinds[nodes[ch[1]][0]]] += 1
            # `instance` is the only unread shape this corpus has, and the one question that decides
            # whether reading it would buy anything: its `declId` is `optional (ppSpace >> declId)`
            # (`Lean/Parser/Command.lean:202-204`), so an anonymous instance's shell is the keyword
            # alone — a one-token shell, with no gap for any layout to collapse. Named ones would have
            # `instance` and the name to re-space. Counting them is what turns "excluded on grammar
            # grounds" into a claim about how much that exclusion costs.
            if kinds[nodes[ch[1]][0]] == "Lean.Parser.Command.instance":
                named = any(
                    kinds[nodes[g][0]] == "Lean.Parser.Command.declId"
                    for c in children[ch[1]]
                    for g in ([c] if kinds[nodes[c][0]] != "null" else children[c])
                )
                instance_shape["named (shell would re-space)" if named
                               else "anonymous (one-token shell)"] += 1
        elif not any(
            kinds[nodes[g][0]] == "Lean.Parser.Command.declId"
            for c in children[ch[1]]
            for g in ([c] if kinds[nodes[c][0]] != "null" else children[c])
        ):
            decl_census["rejected: no declId at the shape's head"] += 1
        else:
            decl_census["structurally claimed: shell laid out"] += 1

    # (6) Would a ctor/field shell layout decide anything?
    #
    # `RLF-COMMANDS`'s task names structures and inductives, and the declaration shell stops at the
    # name, so their members are outstanding. But their grammar leaves this prompt very little: a
    # `ctor` is `"\n| " >> declModifiers true >> rawIdent >> optDeclSig` and a `structSimpleBinder` is
    # `declModifiers true >> ident >> optDeclSig >> ...`, and `optDeclSig` is a *term*, which
    # `RLF-EXPRESSIONS` owns. Their vertical layout is not available either: `structFields` is
    # `manyIndent`, i.e. `withPosition((colGe p)*)`, so a field indented less than the first does not
    # parse — indentation there is semantic, not cosmetic.
    #
    # What is left is the shell: the opener, the modifiers, and the name. This measures whether laying
    # that run out would ever *change* anything — is any gap inside it wider than one byte? Byte
    # offsets answer it without the source text. A layout that provably changes nothing on real code
    # is a conclusion to record, not coverage to add.
    #
    # The shell is identified structurally, not by counting from the front. Every one of these shapes
    # puts its signature in a *child node* (`optDeclSig`, `declSig`, a bracketed binder), so the
    # shell's tokens are exactly the member's **direct** token children plus its `declModifiers`
    # subtree — and everything a term owns is excluded automatically, with no list of term kinds to
    # keep in sync. An earlier draft measured "the gap between the first two tokens" instead, which
    # for `field : Nat` is the gap between `field` and the `:` that *opens* `optDeclSig` — a term's
    # spacing, which this prompt does not own and must not report on.
    #
    # A gap counts only when both its tokens are shell tokens and they are adjacent in the member's
    # full token stream. That matters for `structCtor` (`ident >> many bracketedBinder >> " :: "`),
    # where `ident` and `::` are both shell tokens but the binders sit between them: the span from one
    # to the other is not a gap the shell chooses.
    # (label, index of the name among the shape's direct token children, how many it must have)
    MEMBER_SHELLS = {
        "Lean.Parser.Command.ctor": ("inductive constructors", 1, 2),
        "Lean.Parser.Command.structSimpleBinder": ("structure fields (simple)", 0, 1),
        "Lean.Parser.Command.structCtor": ("structure constructors", 0, 2),
    }
    for i, n in enumerate(nodes):
        shape = MEMBER_SHELLS.get(kinds[n[0]])
        if shape is None:
            continue
        label, name_index, token_count = shape
        member_census[label] += 1
        direct = sorted(token_children[i], key=lambda t: t[1])
        if len(direct) != token_count:
            # The shape does not have the direct tokens its grammar says it has, so the name cannot be
            # indexed and the printer refuses it too. Counted rather than skipped: the buckets below
            # are a partition, and a silent `continue` would land here in whichever one is computed as
            # the remainder and report a refusal as a success.
            member_skipped[label] += 1
            continue
        name = direct[name_index]
        modifiers = [
            t for c in children[i] if kinds[nodes[c][0]] == "Lean.Parser.Command.declModifiers"
            for t in tokens if t[0] is not None and c <= t[0] < end[c]
        ]
        first = min([direct[0][1]] + [t[1] for t in modifiers])
        # The run the printer claims: the shell's first token through the *name*, and no further.
        # Everything past the name is `optDeclSig` or a `bracketedBinder` — a term, and not this
        # prompt's. Stopping there is also what keeps the run contiguous: `structCtor`'s `" :: "` is
        # separated from its name by `many (ppSpace >> Term.bracketedBinder)`.
        toks = sorted(
            (t for t in tokens if t[0] is not None and t[3] == 0 and first <= t[1] <= name[1]),
            key=lambda t: t[1],
        )
        if len(toks) < 2:
            # A one-token shell — an unmodified field is just its name — has no gap to collapse, so
            # no layout could change it whatever the source says.
            member_singleton[label] += 1
            continue
        gaps = [
            normalized[a[2]:b[1]] for a, b in zip(toks, toks[1:]) if b[1] - a[2] > 1
        ]
        if not gaps:
            continue
        # A gap wider than one byte is not automatically something a layout may close. A shell that
        # carries a doc comment is separated from its name by a *line break*, and no layout of this
        # prompt's may delete that: the modifier run has to stay on its own line. Only a gap that is
        # horizontal whitespace is one the shell could collapse to a single space, so that is the only
        # count that argues for building the layout. Splitting the two is the whole measurement — the
        # undivided "gap > 1 byte" figure counts a doc comment's newline as if it were slack.
        if any(b"\n" in gap for gap in gaps):
            member_break[label] += 1
        else:
            member_flat[label] += 1

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
print()
print(f"# command kinds in the corpus ({sum(command_census.values())} commands, "
      f"{len(command_census)} distinct kinds)")
for kind, count in sorted(command_census.items(), key=lambda kv: -kv[1]):
    print(f"{count}\t{kind}")
print()
declarations = sum(decl_census.values())
claimed = decl_census["structurally claimed: shell laid out"]
cpct = (100.0 * claimed / declarations) if declarations else 0.0
print(f"# what the declaration shell layout can structurally claim "
      f"({claimed}/{declarations} declarations, {cpct:.1f}%); runtime guards may still refuse")
for reason, count in sorted(decl_census.items(), key=lambda kv: -kv[1]):
    print(f"{count}\t{reason}")
print()
print("# would a ctor/field shell layout decide anything? a member's shell is its opener, modifiers and")
print("# name; 'collapsible' counts shells holding horizontal slack a layout could close, which is the")
print("# only figure that argues for building one. See the script for why the other three cannot.")
for label, count in sorted(member_census.items(), key=lambda kv: -kv[1]):
    tight = (count - member_singleton[label] - member_break[label] - member_flat[label]
             - member_skipped[label])
    print(f"{count}\t{label}: {member_flat[label]} collapsible, {member_singleton[label]} one-token, "
          f"{member_break[label]} broken by a doc comment, {tight} already tight, "
          f"{member_skipped[label]} unexpected shape")
print()
print("# of those, how the `instance` shells break down")
for label, count in sorted(instance_shape.items(), key=lambda kv: -kv[1]):
    print(f"{count}\t{label}")
print()
print("# shapes rejected only because their grammar has not been read yet")
for kind, count in sorted(unread_shapes.items(), key=lambda kv: -kv[1]):
    print(f"{count}\t{kind}")


# The two properties the tree view depends on are hard failures.
if contiguity_violations or argorder_violations:
    sys.exit(1)
PY
