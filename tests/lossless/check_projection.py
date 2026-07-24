#!/usr/bin/env python3
"""Independently verify that a lean-fmt syntax projection reconstructs its source byte-for-byte.

This shares no code with the product. It re-derives every claim from the artifact JSON and the file
on disk alone, so it can *contradict* `ModuleSyntax.structurallyValid` rather than restate it.

The claim it checks and the product does not is **tiling**: that the leaves form a gapless,
non-overlapping linear cover of the source between the header and the unparsed tail.
`structurallyValid` checks that command roots are contiguous *in the entry array*, that each root's
range lies within the file, that command ranges do not overlap, and that the terminal tree ends
exactly at the array boundary. It never compares one leaf's `trailingStop` to the next leaf's
`leadingStart`, so a projection that silently drops a token's bytes, or claims the same bytes twice,
passes it. That is the failure this oracle exists to catch, and the mutation section of `run.sh` is
what keeps the catching non-vacuous.

Offsets are UTF-8 byte offsets into the *normalized* source (`raw.crlfToLf`), because
`Parser.mkInputContext` normalizes before it assigns any position. They are never character indices
and never offsets into the bytes on disk.

Layout of the projection, as `ModuleSyntax` emits it:

- `entries` is a flat pre-order array. `[0]` is missing, `[1, info, kind, children]` a node,
  `[2, info, value?]` an atom, `[3, info, raw?, value, preresolved]` an ident.
- `info` is `0` for none, `[1, leadingStart, position, endPosition, trailingStop]` for original, and
  `[2, position, endPosition, canonical]` for synthetic. A leaf owns
  `normalized[leadingStart:trailingStop]` -- its leading trivia, its spelling, and its trailing
  trivia -- so concatenating leaf spans in pre-order is the reconstruction.
- `commands` holds the ordinary command roots in source order; `terminal` is the entry index of the
  terminal command (`eoi`, or `#exit`), which is **not** in `commands` and sits after every command
  in the array. Its leaves continue the same tile; whatever follows them is the verbatim tail Lean
  never parsed.

`choice` is the one place a pre-order walk is not a linear cover: its alternatives are several parses
of one byte range, so only one may contribute. `Lean.Syntax.reprint` reprints every alternative and
checks they agree; the product's `terminalsFrom` takes `children[0]?` and assumes it. This oracle
checks it, which is the point of having an oracle.

usage: check_projection.py ARTIFACT_JSON SOURCE_FILE
       check_projection.py --envelope ENVELOPE_JSON SOURCE_FILE
"""

import hashlib
import json
import sys

INFO_NONE, INFO_ORIGINAL, INFO_SYNTHETIC = 0, 1, 2
ENTRY_MISSING, ENTRY_NODE, ENTRY_ATOM, ENTRY_IDENT = 0, 1, 2, 3

# Pinned exactly, not by prefix. This file decodes one wire encoding: the entry tags, the source-info
# tags, and the meaning of `terminal` are all properties of v9. A later schema that reorders any of
# them would be mis-decoded rather than rejected, so bumping it here has to be a deliberate edit that
# re-reads the encoding.
ARTIFACT_SCHEMA = "lean-fmt.module-artifact.v9"
CHOICE_KIND = "choice"


class Failure(Exception):
    pass


def _info(raw):
    """Return ('original', leadingStart, trailingStop), ('synthetic',) or ('none',)."""
    if raw == INFO_NONE:
        return ("none",)
    if not isinstance(raw, list) or not raw:
        raise Failure(f"malformed source info {raw!r}")
    if raw[0] == INFO_ORIGINAL:
        if len(raw) != 5:
            raise Failure(f"original info has {len(raw)} fields, expected 5")
        _, leading_start, position, end_position, trailing_stop = raw
        if not leading_start <= position <= end_position <= trailing_stop:
            raise Failure(
                f"original info out of order: {leading_start} <= {position} <= "
                f"{end_position} <= {trailing_stop}"
            )
        return ("original", leading_start, trailing_stop)
    if raw[0] == INFO_SYNTHETIC:
        return ("synthetic",)
    raise Failure(f"unknown source-info tag {raw[0]}")


class Walk:
    """Pre-order walk over the flat `entries` array, collecting the byte span each leaf owns."""

    def __init__(self, entries, kinds):
        self.entries = entries
        self.kinds = kinds

    def subtree(self, index):
        """Return (next_index, [(leadingStart, trailingStop), ...]) for the subtree at `index`."""
        if not 0 <= index < len(self.entries):
            raise Failure(f"entry index {index} of {len(self.entries)}")
        entry = self.entries[index]
        if not isinstance(entry, list) or not entry:
            raise Failure(f"entry {index} is malformed: {entry!r}")
        tag = entry[0]

        if tag == ENTRY_MISSING:
            return index + 1, []

        if tag in (ENTRY_ATOM, ENTRY_IDENT):
            info = _info(entry[1])
            if info[0] != "original":
                raise Failure(
                    f"entry {index} is a {info[0]} leaf, so its position is fabricated rather "
                    f"than a projection of the source"
                )
            return index + 1, [(info[1], info[2])]

        if tag != ENTRY_NODE:
            raise Failure(f"unknown entry tag {tag} at {index}")

        if len(entry) != 4:
            raise Failure(f"entry {index} is a node with {len(entry)} fields, expected 4")
        _, _, kind, child_count = entry
        if not isinstance(kind, int) or not 0 <= kind < len(self.kinds):
            raise Failure(f"entry {index} names kind {kind} of {len(self.kinds)}")

        cursor = index + 1
        children = []
        for _ in range(child_count):
            cursor, spans = self.subtree(cursor)
            children.append(spans)

        if self.kinds[kind] == CHOICE_KIND:
            # Every alternative parses the same bytes, so only the first may contribute. This is what
            # `terminalsFrom` assumes and `Syntax.reprint` verifies; here it is verified.
            if not children:
                raise Failure(f"entry {index} is a choice node with no alternatives")
            first = children[0]
            for position, other in enumerate(children[1:], start=1):
                if other != first:
                    raise Failure(
                        f"entry {index}: choice alternative {position} spells "
                        f"{other} where alternative 0 spells {first}"
                    )
            return cursor, first

        return cursor, [span for spans in children for span in spans]


def check(syntax_data: dict, artifact: dict, raw: bytes) -> dict:
    """Return measurements, or raise Failure. `raw` is the file exactly as it sits on disk."""
    normalized = raw.replace(b"\r\n", b"\n")

    # Identity. A consumer holds a file; the projection describes the string the parser saw. Digesting
    # the raw bytes here would compare two different strings.
    if artifact["normalizedBytes"] != len(normalized):
        raise Failure(
            f"normalizedBytes {artifact['normalizedBytes']} != {len(normalized)} actual bytes"
        )
    actual_digest = hashlib.sha256(normalized).hexdigest()
    if artifact["normalizedDigest"] != actual_digest:
        raise Failure("normalizedDigest does not match the normalized source")

    kinds = syntax_data["kinds"]
    entries = syntax_data["entries"]
    commands = syntax_data["commands"]
    terminal = syntax_data["terminal"]
    options = syntax_data["options"]

    walk = Walk(entries, kinds)
    spans = []
    cursor = 0
    previous_stop = 0

    # Ordinary commands, in source order. A command root begins where the previous root's subtree
    # ended, so the array is a concatenation of whole trees with nothing between them.
    for position, root in enumerate(commands):
        if root["entry"] != cursor:
            raise Failure(
                f"command {position} claims entry {root['entry']} but the previous subtree "
                f"ended at {cursor}"
            )
        if not 0 <= root["options"] < len(options):
            raise Failure(
                f"command {position} names option set {root['options']} of {len(options)}"
            )
        start, stop = root["range"]["start"], root["range"]["stop"]
        if not 0 <= start <= stop <= len(normalized):
            raise Failure(f"command {position} has range {start}..{stop} of {len(normalized)}")
        if start < previous_stop:
            raise Failure(f"command {position} starts at {start}, inside the previous command")
        previous_stop = stop
        cursor, root_spans = walk.subtree(cursor)
        spans.extend(root_spans)

    # The terminal command closes the modelled region. It is not in `commands`, and its subtree must
    # be the last thing in the array -- otherwise entries exist that no root reaches.
    if terminal != cursor:
        raise Failure(f"terminal is entry {terminal} but the commands ended at {cursor}")
    cursor, terminal_spans = walk.subtree(terminal)
    if cursor != len(entries):
        raise Failure(
            f"the terminal subtree ends at {cursor}, not the array boundary {len(entries)}"
        )
    terminal_start = terminal_spans[0][0] if terminal_spans else len(normalized)
    spans.extend(terminal_spans)

    if not spans:
        raise Failure("the projection reconstructs no leaves at all")

    # Reconstruction. Everything before the first leaf is header the parser consumed as the module
    # preamble; everything after the last is tail it never parsed. Between them the leaves must tile.
    header_stop = spans[0][0]
    if header_stop > len(normalized):
        raise Failure(f"the first leaf starts at {header_stop}, past {len(normalized)} bytes")
    rebuilt = bytearray(normalized[:header_stop])
    cursor = header_stop
    for index, (leading_start, trailing_stop) in enumerate(spans):
        if leading_start != cursor:
            shape = "a hole" if leading_start > cursor else "an overlap"
            raise Failure(
                f"leaf {index} owns {leading_start}..{trailing_stop} but the previous leaf "
                f"stopped at {cursor}: {shape} of {abs(leading_start - cursor)} byte(s), so the "
                f"projection is not a linear cover"
            )
        if trailing_stop > len(normalized):
            raise Failure(f"leaf {index} stops at {trailing_stop}, past {len(normalized)} bytes")
        rebuilt += normalized[cursor:trailing_stop]
        cursor = trailing_stop
    tail_start = cursor
    rebuilt += normalized[cursor:]

    if bytes(rebuilt) != normalized:
        raise Failure("reconstruction is not byte-identical to the source")

    return {
        "raw_bytes": len(raw),
        "normalized_bytes": len(normalized),
        "leaves": len(spans),
        "entries": len(entries),
        "kinds": len(kinds),
        "commands": len(commands),
        "header_stop": header_stop,
        "terminal_start": terminal_start,
        "tail_bytes": len(normalized) - tail_start,
    }


def main(argv):
    if len(argv) == 4 and argv[1] == "--envelope":
        envelope = json.load(open(argv[2]))
        artifact = envelope.get("artifact")
        if artifact is None:
            raise Failure(f"envelope has no artifact: {envelope.get('diagnostics')}")
        source_path = argv[3]
    elif len(argv) == 3:
        artifact = json.load(open(argv[1]))
        source_path = argv[2]
    else:
        print(__doc__, file=sys.stderr)
        return 2

    schema = artifact.get("schema", "")
    if schema != ARTIFACT_SCHEMA:
        raise Failure(f"schema {schema!r} is not the {ARTIFACT_SCHEMA!r} encoding this decodes")
    syntax_data = artifact.get("syntaxData")
    if syntax_data is None:
        raise Failure("artifact carries no syntaxData")
    # An artifact carries facts, never findings: a rule's conclusions are computed by the process that
    # reports them, from bytes already in hand, so a range is in range by construction not by audit.
    if "findings" in artifact:
        raise Failure("artifact carries findings; it must carry only facts")

    with open(source_path, "rb") as handle:
        raw = handle.read()

    measured = check(syntax_data, artifact, raw)
    print(" ".join(f"{key}={value}" for key, value in measured.items()))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Failure as failure:
        print(f"FAIL {failure}", file=sys.stderr)
        sys.exit(1)
