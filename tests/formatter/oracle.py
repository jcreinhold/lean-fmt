#!/usr/bin/env python3
"""Independent admission oracle for a frontend-native Lean formatter candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


MAX_BYTES = "8589934592"


class GateFailure(Exception):
    def __init__(self, gate: str, detail: str):
        super().__init__(detail)
        self.gate = gate
        self.detail = detail


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_bytes(path: Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n")


def invoke_candidate(command: list[str], source: bytes, setup_digest: str, pass_index: int) -> dict[str, Any]:
    env = os.environ.copy()
    env.update(
        LEAN_FMT_EXPECTED_SOURCE_DIGEST=digest(source),
        LEAN_FMT_EXPECTED_SETUP_DIGEST=setup_digest,
        LEAN_FMT_FORMAT_PASS=str(pass_index),
    )
    done = subprocess.run(command, input=source, capture_output=True, env=env)
    if done.returncode != 0:
        raise GateFailure("candidate", done.stderr.decode("utf-8", "replace").strip())
    try:
        response = json.loads(done.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateFailure("candidate", f"candidate did not emit one JSON response: {error}") from error
    if not isinstance(response, dict) or not isinstance(response.get("formatted"), str):
        raise GateFailure("candidate", "response has no string `formatted` field")
    return response


def validate_identity(response: dict[str, Any], source: bytes, setup_digest: str) -> None:
    if response.get("sourceDigest") != digest(source):
        raise GateFailure("stale-artifact", "candidate identity does not match the input bytes")
    if response.get("setupDigest") != setup_digest:
        raise GateFailure("environment", "candidate identity does not match the exact module setup")
    if response.get("cancelled") is not False:
        raise GateFailure("cancellation", "a cancelled candidate reached admission")
    unsupported = response.get("unsupported")
    if not isinstance(unsupported, list):
        raise GateFailure("candidate", "`unsupported` is not an array")
    if unsupported:
        raise GateFailure("unsupported", json.dumps(unsupported[0], sort_keys=True))


def range_pair(value: Any, label: str) -> tuple[int, int]:
    if not isinstance(value, dict) or set(value) != {"start", "stop"}:
        raise GateFailure("source-map", f"{label} is not an exact start/stop range")
    start, stop = value["start"], value["stop"]
    if type(start) is not int or type(stop) is not int or start < 0 or stop < start:
        raise GateFailure("source-map", f"invalid {label}: {value!r}")
    return start, stop


def validate_source_map(response: dict[str, Any], source: bytes, output: bytes) -> list[tuple[int, int, int, int]]:
    raw = response.get("sourceMap")
    if not isinstance(raw, list) or not raw:
        raise GateFailure("source-map", "source map is absent or empty")
    units: list[tuple[int, int, int, int]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict) or set(item) != {"source", "output"}:
            raise GateFailure("source-map", f"unit {index} has unknown or missing fields")
        ss, se = range_pair(item["source"], f"unit {index} source")
        os_, oe = range_pair(item["output"], f"unit {index} output")
        units.append((ss, se, os_, oe))
    source_cursor = output_cursor = 0
    for index, (ss, se, os_, oe) in enumerate(units):
        if ss != source_cursor or os_ != output_cursor:
            raise GateFailure("source-map", f"unit {index} overlaps or leaves a gap")
        source_cursor, output_cursor = se, oe
    if source_cursor != len(source) or output_cursor != len(output):
        raise GateFailure("source-map", "units do not tile the complete source and output")
    return units


def analyze(application: str, tests: str, setup: Path, source: bytes, label: str) -> tuple[dict[str, Any], Path]:
    handle = tempfile.NamedTemporaryFile(prefix="lean-fmt-contract-", suffix=".lean", delete=False)
    path = Path(handle.name)
    try:
        handle.write(source)
        handle.close()
        done = subprocess.run(
            [application, "__analyze-exact", str(setup), str(path), label, MAX_BYTES],
            capture_output=True,
            text=True,
        )
        if done.returncode != 0:
            raise GateFailure("frontend", done.stderr.strip() or f"exact analysis exited {done.returncode}")
        envelope = json.loads(done.stdout)
        artifact = envelope.get("artifact")
        if not artifact or envelope.get("diagnostics"):
            raise GateFailure("frontend", json.dumps(envelope.get("diagnostics"), ensure_ascii=False))
        with tempfile.NamedTemporaryFile(prefix="lean-fmt-artifact-", suffix=".json") as artifact_file:
            artifact_file.write(json.dumps(artifact).encode("utf-8"))
            artifact_file.flush()
            projected = subprocess.run(
                [tests, "artifact-projection", artifact_file.name, str(path)],
                capture_output=True,
                text=True,
            )
        if projected.returncode != 0:
            raise GateFailure("frontend", projected.stderr.strip() or "artifact reconstruction failed")
        artifact["source"] = json.loads(projected.stdout)
        return artifact, path
    except Exception:
        path.unlink(missing_ok=True)
        raise


def header_signature(tests: str, path: Path) -> Any:
    done = subprocess.run([tests, "formatter-header", str(path)], capture_output=True, text=True)
    if done.returncode != 0:
        raise GateFailure("imports", done.stderr.strip() or "header parser refused the candidate")
    return json.loads(done.stdout)


def tree_signature(source: dict[str, Any]) -> list[tuple[str, int]]:
    kinds = source["kinds"]
    return [(kinds[node[0]], node[1]) for node in source["nodes"]]


def split_projection(source: dict[str, Any], raw: bytes) -> tuple[list[tuple[int, bytes]], list[tuple[int, bytes]], list[tuple[int, str, int, int, bytes]]]:
    tokens: list[tuple[int, bytes]] = []
    comments: list[tuple[int, bytes]] = []
    ownership: list[tuple[int, str, int, int, bytes]] = []
    cursor = 0
    for token_index, token in enumerate(source["tokens"]):
        node, start, stop, _info, leading, trailing = token
        for side, runs in (("leading", leading), ("trailing", trailing)):
            for run_index, (kind, end) in enumerate(runs):
                payload = raw[cursor:end]
                if kind != 0:
                    comments.append((kind, payload))
                    ownership.append((token_index, side, run_index, kind, payload))
                cursor = end
            if side == "leading":
                tokens.append((node, raw[start:stop]))
                cursor = stop
    return tokens, comments, ownership


def compare_artifacts(before: dict[str, Any], after: dict[str, Any], before_raw: bytes, after_raw: bytes) -> None:
    before_source, after_source = before["source"], after["source"]
    before_tail = before_raw[before_source["terminalStop"] :]
    after_tail = after_raw[after_source["terminalStop"] :]
    if before_tail != after_tail:
        raise GateFailure("terminal", f"terminal/tail bytes changed: {before_tail!r} -> {after_tail!r}")
    before_tokens, before_comments, before_owners = split_projection(before_source, before_raw)
    after_tokens, after_comments, after_owners = split_projection(after_source, after_raw)
    before_spellings = [token for _node, token in before_tokens]
    after_spellings = [token for _node, token in after_tokens]
    before_payloads = before_comments + [(3, token) for token in before_spellings if token.startswith(b"/--")]
    after_payloads = after_comments + [(3, token) for token in after_spellings if token.startswith(b"/--")]
    if before_payloads != after_payloads:
        raise GateFailure("comments-payload", "comment kind, order, count, or payload changed")
    if before_owners != after_owners:
        raise GateFailure("comments-ownership", "a comment moved between leading/trailing token owners")
    if before_spellings != after_spellings:
        raise GateFailure("tokens", "token count, order, or spelling changed")
    before_tree = tree_signature(before_source)
    after_tree = tree_signature(after_source)
    before_token_nodes = [node for node, _token in before_tokens]
    after_token_nodes = [node for node, _token in after_tokens]
    if before_tree != after_tree or before_token_nodes != after_token_nodes:
        raise GateFailure("structure", "normalized node kind/parent/child order or token ownership changed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", required=True)
    parser.add_argument("--tests", required=True)
    parser.add_argument("--setup", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("candidate", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.candidate[1:] if args.candidate[:1] == ["--"] else args.candidate
    if not command:
        parser.error("candidate command is required after --")

    original = normalized_bytes(args.source)
    setup_digest = digest(args.setup.read_bytes())
    first = invoke_candidate(command, original, setup_digest, 1)
    validate_identity(first, original, setup_digest)
    formatted = first["formatted"].encode("utf-8")
    units = validate_source_map(first, original, formatted)
    second = invoke_candidate(command, formatted, setup_digest, 2)
    validate_identity(second, formatted, setup_digest)
    validate_source_map(second, formatted, second["formatted"].encode("utf-8"))

    before_path: Path | None = None
    after_path: Path | None = None
    try:
        before, before_path = analyze(args.application, args.tests, args.setup, original, args.source.name)
        after, after_path = analyze(args.application, args.tests, args.setup, formatted, args.source.name)
        if header_signature(args.tests, before_path) != header_signature(args.tests, after_path):
            raise GateFailure("imports", "ordered parsed import signature changed")
        compare_artifacts(before, after, original, formatted)
    finally:
        if before_path is not None:
            before_path.unlink(missing_ok=True)
        if after_path is not None:
            after_path.unlink(missing_ok=True)

    if second["formatted"].encode("utf-8") != formatted:
        raise GateFailure("idempotence", "the second pass changed bytes")

    reflowed_units = sum(
        original[ss:se] != formatted[os_:oe] for ss, se, os_, oe in units
    )
    source_model = before["source"]
    projection_tokens, projection_comments, _projection_owners = split_projection(source_model, original)
    summary = {
        "status": "ok",
        "sourceBytes": len(original),
        "outputBytes": len(formatted),
        "changed": int(original != formatted),
        "reflowedUnits": reflowed_units,
        "nodes": len(source_model["nodes"]),
        "tokens": len(source_model["tokens"]),
        "comments": len(projection_comments) +
        sum(token.startswith(b"/--") for _node, token in projection_tokens),
        "unsupported": 0,
    }
    stable = json.dumps(summary, sort_keys=True, separators=(",", ":")).encode() + b"\0" + formatted
    summary["digest"] = digest(stable)
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateFailure as failure:
        print(json.dumps({"status": "failed", "gate": failure.gate, "detail": failure.detail}, sort_keys=True))
        raise SystemExit(1)
