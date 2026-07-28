#!/usr/bin/env python3
"""Emit one frozen style candidate through Prompt 02's independent structural oracle protocol."""

import hashlib
import json
import os
import pathlib
import sys

source = sys.stdin.read().replace("\r\n", "\n")
formatted = pathlib.Path(sys.argv[1]).read_text().replace("\r\n", "\n")
response = {
    "formatted": formatted,
    "sourceMap": [
        {
            "source": {"start": 0, "stop": len(source.encode())},
            "output": {"start": 0, "stop": len(formatted.encode())},
        }
    ],
    "sourceDigest": os.environ.get(
        "LEAN_FMT_EXPECTED_SOURCE_DIGEST", hashlib.sha256(source.encode()).hexdigest()
    ),
    "setupDigest": os.environ.get("LEAN_FMT_EXPECTED_SETUP_DIGEST", ""),
    "cancelled": False,
    "unsupported": [],
}
json.dump(response, sys.stdout, sort_keys=True, separators=(",", ":"))
sys.stdout.write("\n")
