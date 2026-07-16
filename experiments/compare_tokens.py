#!/usr/bin/env python3
"""Did formatting preserve everything that is not whitespace?

Two `__analyze-exact` envelopes and the two sources they describe: the original module, and the same
module after one formatting pass. A formatter is allowed to change whitespace and nothing else, so the
two projections must agree on:

  * the token stream — same count, same order, same text;
  * the comments — same count, same order, same kind, same text.

This is the losslessness claim, and it is the one byte identity cannot make on foreign code. Identity
only holds for source already in canonical form, which is true of this repository and false of the
frozen mathlib sample. This holds for *any* input, which is why it is what the sample is checked
against.

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
    envelope = json.load(open(envelope_path))
    artifact = envelope.get("artifact")
    if not artifact:
        raise SystemExit(f"{envelope_path}: no artifact: {envelope.get('diagnostics')}")
    source = artifact["source"]
    raw = open(source_path, "rb").read().replace(b"\r\n", b"\n")
    if len(raw) != source["normalizedBytes"]:
        raise SystemExit(
            f"{source_path}: {len(raw)} bytes on disk, projection says "
            f"{source['normalizedBytes']}"
        )
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


if __name__ == "__main__":
    main()
