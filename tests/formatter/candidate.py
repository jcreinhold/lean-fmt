#!/usr/bin/env python3
"""Injected formatter candidates for the contract harness.

Protocol: read normalized Lean source on stdin and emit one JSON object containing `formatted`, a
source map, exact input/setup identities, cancellation state, and unsupported syntax. Prompt 03 can
replace this executable with its prototype without changing the oracle.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys


def byte_size(text: str) -> int:
    return len(text.encode("utf-8"))


def full_map(source: str, formatted: str) -> list[dict[str, dict[str, int]]]:
    return [
        {
            "source": {"start": 0, "stop": byte_size(source)},
            "output": {"start": 0, "stop": byte_size(formatted)},
        }
    ]


def transform(mode: str, source: str) -> str:
    if mode in {"identity", "stale-artifact", "wrong-environment", "cancelled", "unsupported", "overlap-map"}:
        return source
    if mode == "drop-block-comment":
        return source.replace("/- block payload -/ ", "", 1)
    if mode == "move-trailing-comment":
        return source.replace(
            "def value : Nat := 1 -- trailing payload",
            "-- trailing payload\ndef value : Nat := 1",
            1,
        )
    if mode == "duplicate-doc-comment":
        return source.replace(
            "def blockValue : Nat :=",
            "/-- doc payload -/\ndef blockValue : Nat :=",
            1,
        )
    if mode == "change-imports":
        return source.replace(
            "import Lean.Data.Json\nimport Lean.Data.Name",
            "import Lean.Data.Name\nimport Lean.Data.Json",
            1,
        )
    if mode == "move-terminal":
        return source.replace(
            "#exit\ndef tailValue : Nat := 2",
            "def tailValue : Nat := 2\n#exit",
            1,
        )
    if mode == "term-reassociate":
        return source.replace(
            "  if true then\n    pure ()\n  pure ()",
            "  if true then\n    pure ()\n    pure ()",
            1,
        )
    if mode == "tactic-reassociate":
        return source.replace(
            "  try\n    trivial\n  trivial",
            "  try\n    trivial\n    trivial",
            1,
        )
    if mode == "second-pass-drift":
        return re.sub(r"def( +)value", lambda match: "def" + match.group(1) + " value", source, count=1)
    raise SystemExit(f"unknown injected candidate mode: {mode}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: candidate.py MODE")
    mode = sys.argv[1]
    source = sys.stdin.read().replace("\r\n", "\n")
    formatted = transform(mode, source)
    source_digest = os.environ.get("LEAN_FMT_EXPECTED_SOURCE_DIGEST", hashlib.sha256(source.encode()).hexdigest())
    setup_digest = os.environ.get("LEAN_FMT_EXPECTED_SETUP_DIGEST", "")
    source_map = full_map(source, formatted)
    if mode == "overlap-map":
        size = byte_size(source)
        source_map = [
            {"source": {"start": 0, "stop": size}, "output": {"start": 0, "stop": size}},
            {"source": {"start": 0, "stop": size}, "output": {"start": 0, "stop": size}},
        ]
    response = {
        "formatted": formatted,
        "sourceMap": source_map,
        "sourceDigest": "0" * 64 if mode == "stale-artifact" else source_digest,
        "setupDigest": "0" * 64 if mode == "wrong-environment" else setup_digest,
        "cancelled": mode == "cancelled",
        "unsupported": ([{"kind": "Audit.Unsupported", "start": 0, "stop": 6}] if mode == "unsupported" else []),
    }
    json.dump(response, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
