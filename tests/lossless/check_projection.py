#!/usr/bin/env python3
"""Independently verify that a lean-fmt projection reconstructs its source byte-for-byte.

This shares no code with the product. It re-derives every claim from the artifact JSON and the
source file alone, so it can contradict `LosslessSource.structurallyValid` rather than restate it.
Offsets are UTF-8 byte offsets into the normalized source, never character indices, and never the
bytes on disk.

usage: check_projection.py ARTIFACT_JSON SOURCE_FILE
       check_projection.py --envelope ENVELOPE_JSON SOURCE_FILE
"""

import hashlib
import json
import sys

WHITESPACE, LINE_COMMENT, BLOCK_COMMENT = 0, 1, 2
ORIGINAL = 0

LOSSLESS_SCHEMA = "lean-fmt.lossless-source.v1"


class Failure(Exception):
    pass


def check(source: dict, raw: bytes) -> dict:
    """Return measurements, or raise Failure. `raw` is the file exactly as it sits on disk."""
    normalized = raw.replace(b"\r\n", b"\n")

    if source["schema"] != LOSSLESS_SCHEMA:
        raise Failure(f"unexpected schema {source['schema']!r}")

    # Identity. A consumer holds the file; the projection describes the string the parser saw.
    if source["normalizedBytes"] != len(normalized):
        raise Failure(
            f"normalizedBytes {source['normalizedBytes']} != {len(normalized)} actual bytes"
        )
    actual_digest = hashlib.sha256(normalized).hexdigest()
    if source["normalizedDigest"] != actual_digest:
        raise Failure("normalizedDigest does not match the normalized source")

    kinds, nodes, tokens = source["kinds"], source["nodes"], source["tokens"]
    header_stop, terminal_stop = source["headerStop"], source["terminalStop"]

    if not 0 <= header_stop <= terminal_stop <= len(normalized):
        raise Failure(
            f"boundaries out of order: 0 <= {header_stop} <= {terminal_stop} <= {len(normalized)}"
        )

    for index, (kind, parent, start, stop) in enumerate(nodes):
        if not 0 <= kind < len(kinds):
            raise Failure(f"node {index} names kind {kind} of {len(kinds)}")
        if parent is not None and not 0 <= parent < len(nodes):
            raise Failure(f"node {index} names parent {parent} of {len(nodes)}")
        if not start <= stop <= len(normalized):
            raise Failure(f"node {index} has range {start}..{stop}")

    def check_trivia(runs, start, limit, where):
        cursor = start
        for kind, stop in runs:
            if not cursor < stop <= limit:
                raise Failure(f"{where}: trivia run {cursor}..{stop} escapes {start}..{limit}")
            text = normalized[cursor:stop]
            if kind == WHITESPACE:
                if text.split() != []:
                    raise Failure(f"{where}: whitespace run is not whitespace: {text!r}")
            elif kind == LINE_COMMENT:
                if not text.startswith(b"--") or b"\n" in text:
                    raise Failure(f"{where}: line-comment run is not one: {text!r}")
            elif kind == BLOCK_COMMENT:
                if not text.startswith(b"/-") or not text.endswith(b"-/"):
                    raise Failure(f"{where}: block-comment run is not one: {text!r}")
                # Doc comments are tokens, not trivia: `/--` and `/-!` must never appear here.
                if text[:3] in (b"/--", b"/-!"):
                    raise Failure(f"{where}: a doc comment was classified as trivia: {text[:8]!r}")
            else:
                raise Failure(f"{where}: unknown trivia kind {kind}")
            cursor = stop
        if cursor != limit:
            raise Failure(f"{where}: trivia stops at {cursor}, not {limit}")
        return cursor

    # Reconstruct: header, then every token with its trivia, then the unparsed tail.
    rebuilt = bytearray(normalized[:header_stop])
    cursor = header_stop
    trivia_runs = 0
    for index, (node, start, stop, info, leading, trailing) in enumerate(tokens):
        where = f"token {index}"
        if info != ORIGINAL:
            raise Failure(f"{where}: leaf is not `original`, so its position is fabricated")
        if not 0 <= node < len(nodes):
            raise Failure(f"{where}: names node {node} of {len(nodes)}")
        check_trivia(leading, cursor, start, where + " leading")
        if not start <= stop:
            raise Failure(f"{where}: span {start}..{stop} is inverted")
        trailing_stop = trailing[-1][1] if trailing else stop
        check_trivia(trailing, stop, trailing_stop, where + " trailing")
        rebuilt += normalized[cursor:trailing_stop]
        cursor = trailing_stop
        trivia_runs += len(leading) + len(trailing)

    if cursor != terminal_stop:
        raise Failure(f"the token stream stops at {cursor}, not at the terminal {terminal_stop}")
    rebuilt += normalized[terminal_stop:]

    if bytes(rebuilt) != normalized:
        raise Failure("reconstruction is not byte-identical to the source")

    return {
        "raw_bytes": len(raw),
        "normalized_bytes": len(normalized),
        "tokens": len(tokens),
        "nodes": len(nodes),
        "kinds": len(kinds),
        "trivia_runs": trivia_runs,
        "header_stop": header_stop,
        "terminal_stop": terminal_stop,
        "tail_bytes": len(normalized) - terminal_stop,
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

    with open(source_path, "rb") as handle:
        raw = handle.read()

    measured = check(artifact["source"], raw)
    # `findings` share the projection's coordinate system; nothing may point outside it.
    for finding in artifact["findings"]:
        span = finding["range"]
        if not span["start"] <= span["stop"] <= measured["normalized_bytes"]:
            raise Failure(f"finding {finding['code']} has range {span} outside the source")
    print(" ".join(f"{key}={value}" for key, value in measured.items()))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Failure as failure:
        print(f"FAIL {failure}", file=sys.stderr)
        sys.exit(1)
