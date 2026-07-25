#!/usr/bin/env python3
"""Did formatting preserve everything that is not whitespace — *and* the parse it stands for?

Two `__analyze-exact` envelopes and the two sources they describe: the original module, and the same
module after one formatting pass. A formatter is allowed to change whitespace and nothing else, so the
two projections must agree on:

  * the token stream — same count, same order, same text;
  * the comments — same count, same order, same kind, same text;
  * the parse tree — same node kinds in the same parent structure.

The first two are the losslessness claim, and it is the one byte identity cannot make on foreign code.
Identity only holds for source already in canonical form, which is true of this repository and false of
the frozen mathlib sample. These hold for *any* input, which is why they are what the sample is checked
against.

The third is the parse-*preservation* claim, and it is strictly stronger than the token stream on
offside-sensitive Lean. A re-indentation that pulls a tactic from an inner `by` block into the outer one
(`RLF-BLOCKS`' re-association hazard, `results/10` §non-vacuity) emits the *same tokens in the same
order* — token comparison cannot see it — but reparses to a *different tree*: the moved tactic acquires
a different parent. So the node `(kind, parent)` sequence is compared. It is sound to compare because a
whitespace-only reformat that preserves the parse produces the identical tree by definition — the node
positions (byte `start`/`stop`) move with the whitespace and are deliberately *not* compared, only the
kind and the parent index, which are structural. Empirically: a six-line β-break of an application
changes the digest and leaves the `(kind, parent)` sequence identical; a one-tactic re-association
leaves the tokens identical and changes it. This is the check that makes the differential a
parse-preservation gate rather than a token-stream proxy.

Comments are compared because they are trivia rather than tokens, and a layout that re-spaces a token
run emits only the tokens — everything between them that is not whitespace is dropped unless a guard
refuses the layout. `Tree.triviaClean` is that guard, and this is the check that would notice if it
were wrong on a shape no fixture covers.

usage: compare_tokens.py BEFORE.json AFTER.json BEFORE.lean AFTER.lean    (exit 0 = nothing lost)
"""

import json
import sys

# `LosslessSource.lean:39-43`. Read the encoding, do not guess it.
KINDS = {0: "whitespace", 1: "line comment", 2: "block comment"}


def load(envelope_path, source_path):
    with open(envelope_path) as f:
        envelope = json.load(f)
    artifact = envelope.get("artifact")
    if not artifact:
        raise SystemExit(f"{envelope_path}: no artifact: {envelope.get('diagnostics')}")
    source = artifact["source"]
    with open(source_path, "rb") as f:
        raw = f.read().replace(b"\r\n", b"\n")
    if len(raw) != source["normalizedBytes"]:
        raise SystemExit(f"{source_path}: {len(raw)} bytes on disk, projection says {source['normalizedBytes']}")
    return source, raw


def split(source, raw):
    """The token texts and the comment (kind, text) pairs, in source order.

    `LosslessSource.lean:156` encodes Token as [node, start, stop, info, leading, trailing] and
    `:46-49` encodes Trivia as [kind, stop] — a stop and no start, because "runs tile their enclosing
    trivia span in order". So a run's spans are reconstructed by carrying a cursor through it rather
    than read off each element.
    """
    tokens, comments = [], []
    cursor = 0
    for token in source["tokens"]:
        _node, start, stop, _info, leading, trailing = token
        for kind, end in leading:
            if kind != 0:
                comments.append((KINDS.get(kind, kind), raw[cursor:end]))
            cursor = end
        tokens.append(raw[start:stop])
        cursor = stop
        for kind, end in trailing:
            if kind != 0:
                comments.append((KINDS.get(kind, kind), raw[cursor:end]))
            cursor = end
    return tokens, comments


def tree(source):
    """The parse tree's shape: each node's kind name and its parent index, in node order.

    `LosslessSource.lean` encodes a node as `[kindIndex, parent, start, stop]` with `kinds` a dedup
    table of kind-name strings. The kind index is resolved to its *name* so two projections whose dedup
    tables happen to enumerate kinds in a different order still compare equal on structure; `start`/`stop`
    are byte offsets that move with whitespace and are excluded on purpose — only `kind` and `parent`
    carry the parse, and both are invariant under a parse-preserving reformat.
    """
    kinds, nodes = source["kinds"], source["nodes"]
    return [(kinds[node[0]], node[1]) for node in nodes]


def main():
    before, before_raw = load(sys.argv[1], sys.argv[3])
    after, after_raw = load(sys.argv[2], sys.argv[4])

    before_tokens, before_comments = split(before, before_raw)
    after_tokens, after_comments = split(after, after_raw)

    if len(before_tokens) != len(after_tokens):
        raise SystemExit(f"token count changed: {len(before_tokens)} -> {len(after_tokens)}")
    for index, (a, b) in enumerate(zip(before_tokens, after_tokens)):
        if a != b:
            raise SystemExit(f"token {index} changed: {a!r} -> {b!r}")

    if len(before_comments) != len(after_comments):
        after_texts = [text for _kind, text in after_comments]
        lost = [text for _kind, text in before_comments if text not in after_texts]
        raise SystemExit(
            f"comment count changed: {len(before_comments)} -> {len(after_comments)}"
            + (f"; first lost: {lost[0][:60]!r}" if lost else "")
        )
    for index, (a, b) in enumerate(zip(before_comments, after_comments)):
        if a != b:
            raise SystemExit(f"comment {index} changed: {a!r} -> {b!r}")

    before_tree, after_tree = tree(before), tree(after)
    if len(before_tree) != len(after_tree):
        raise SystemExit(f"node count changed: {len(before_tree)} -> {len(after_tree)}")
    for index, (a, b) in enumerate(zip(before_tree, after_tree)):
        if a != b:
            raise SystemExit(
                f"parse tree changed at node {index}: (kind, parent) {a!r} -> {b!r}"
                " — a re-association or offside break the tokens alone did not show"
            )


if __name__ == "__main__":
    main()
