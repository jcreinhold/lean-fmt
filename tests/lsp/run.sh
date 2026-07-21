#!/usr/bin/env bash
set -euo pipefail

# `ruff-17` RLP-DOCUMENTS: the Language Server Protocol transport and document lifecycle, exercised
# against the real binary over a real pipe. The unit tests in `LeanFmtTest.lean` cover the position
# layer and frame reader in isolation; this suite covers what only a process can show — lifecycle
# ordering, recovery that leaves the session usable, refusal of a document with no project location,
# cancellation delivered while the server is busy, and a bounded store that refuses rather than grows.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

python3 - "$application" "$repo_root" <<'PY'
import json
import os
import subprocess
import sys

application, root = sys.argv[1:]

failures = []

def check(label, actual, expected):
    if actual == expected:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label}\n  expected: {expected!r}\n  actual:   {actual!r}")
        failures.append(label)

def check_that(label, condition, detail=""):
    if condition:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label} {detail}")
        failures.append(label)

def frame(obj):
    body = json.dumps(obj, separators=(",", ":")).encode()
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)

def run(payload, timeout=300):
    env = os.environ.copy()
    env["LEAN_NUM_THREADS"] = "1"
    proc = subprocess.run(
        [application, "lsp", "--root", root],
        cwd=root, env=env, input=payload, capture_output=True, timeout=timeout)
    return proc.returncode, parse(proc.stdout), proc.stderr.decode()

def parse(raw):
    """Split a response stream into messages, framing errors included."""
    messages = []
    index = 0
    while index < len(raw):
        header_end = raw.find(b"\r\n\r\n", index)
        if header_end < 0:
            raise AssertionError(f"unterminated header at {index}: {raw[index:index+80]!r}")
        headers = raw[index:header_end].decode()
        length = None
        for line in headers.split("\r\n"):
            name, _, value = line.partition(": ")
            if name.lower() == "content-length":
                length = int(value)
        assert length is not None, f"no Content-Length in {headers!r}"
        body = raw[header_end + 4:header_end + 4 + length]
        assert len(body) == length, "declared Content-Length does not match the bytes sent"
        messages.append(json.loads(body))
        index = header_end + 4 + length
    return messages

def responses(messages):
    return {m["id"]: m for m in messages if "id" in m and m["id"] is not None}

def notifications(messages, method):
    return [m for m in messages if m.get("method") == method]

lean_uri = "file://" + os.path.join(root, "tests/check/Findings.lean")
outside_uri = "file:///etc/hosts"
lake_uri = "file://" + os.path.join(root, ".lake/packages/x/X.lean")

def open_document(uri, text, version=1):
    return frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri, "languageId": "lean", "version": version, "text": text}}})

source = open(os.path.join(root, "tests/check/Findings.lean")).read()

# --- lifecycle ------------------------------------------------------------------------------
code, messages, stderr = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
check("a clean session exits zero", code, 0)
capabilities = answers[1]["result"]["capabilities"]
check("formatting is advertised", capabilities["documentFormattingProvider"], True)
check("range formatting is advertised", capabilities["documentRangeFormattingProvider"], True)
check("sync is incremental", capabilities["textDocumentSync"]["change"], 2)
check("code action kinds", capabilities["codeActionProvider"]["codeActionKinds"],
      ["quickfix", "source.fixAll", "source.organizeImports"])
check("the server names itself", answers[1]["result"]["serverInfo"]["name"], "lean-fmt")
check("health reports a ready server", answers[2]["result"]["ready"], True)
check("shutdown answers null", answers[3]["result"], None)

# A request before `initialize` is answered `ServerNotInitialized` (-32002), not ignored.
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
check("a request before initialize is refused", answers[1]["error"]["code"], -32002)
check("initialize still works afterwards", "result" in answers[2], True)

# `exit` without `shutdown` is a protocol violation and exits non-zero.
code, _, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
check("exit without shutdown exits non-zero", code, 1)

# End of input ends the session cleanly, with no `exit` at all.
code, _, _ = run(frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}))
check("end of input ends the session", code, 0)

# --- malformed-message recovery -------------------------------------------------------------
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    b"Content-Length: nope\r\n\r\n",
    b"Content-Length: 4\r\n\r\n{,,,",
    b"X-Only-Header: 1\r\n\r\n",
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
parse_errors = [m for m in messages if m.get("error", {}).get("code") == -32700]
check("three malformed messages produce three parse errors", len(parse_errors), 3)
check("a malformed message has a null id", parse_errors[0]["id"], None)
check_that("the session survives them", 2 in responses(messages),
           f"health was not answered: {messages}")
check("and still exits cleanly", code, 0)

# An unknown method is `MethodNotFound`; an unknown notification is ignored in silence, as the
# specification requires of `$/` notifications a server does not implement.
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "$/setTrace", "params": {"value": "verbose"}}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
check("an unknown request is MethodNotFound", answers[2]["error"]["code"], -32601)
check("an unknown notification is not answered", code, 0)

# --- document admission ---------------------------------------------------------------------
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    open_document(lean_uri, source),
    open_document("untitled:Untitled-1", "def x := 1\n"),
    open_document(outside_uri, "def x := 1\n"),
    open_document(lake_uri, "def x := 1\n"),
    open_document("file://" + os.path.join(root, "README.md"), "# not lean\n"),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
shown = [m["params"]["message"] for m in notifications(messages, "window/showMessage")]
check("one document is served", answers[2]["result"]["openDocuments"], 1)
check("four are refused", answers[2]["result"]["refusedDocuments"], 4)
check("the served bytes are the document's", answers[2]["result"]["openDocumentBytes"],
      len(source.encode()))
check_that("an untitled buffer is refused for having no location",
           any("no file location" in m and "untitled:Untitled-1" in m for m in shown), shown)
check_that("a document outside the root is refused",
           any("outside the project root" in m for m in shown), shown)
check_that("a document inside .lake is refused",
           any("Lake build directory" in m for m in shown), shown)
check_that("a document that is not Lean source is refused",
           any("not a Lean source" in m for m in shown), shown)
check_that("every refusal names the URI the client sent",
           all(("file://" in m or "untitled:" in m) for m in shown), shown)

# A request against a refused document says why it was refused, not "unknown document"; a request
# against a document that was never opened says the latter. The two are different bugs.
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    open_document("untitled:Untitled-1", "def x := 1\n"),
    frame({"jsonrpc": "2.0", "id": 2, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
check("the refusal is announced once", len(notifications(messages, "window/showMessage")), 1)

# --- versions and synchronization -------------------------------------------------------------
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    open_document(lean_uri, "def a := 1\n"),
    # An incremental change: replace `1` with `2`.
    frame({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
        "textDocument": {"uri": lean_uri, "version": 2},
        "contentChanges": [{"range": {"start": {"line": 0, "character": 9},
                                      "end": {"line": 0, "character": 10}},
                            "text": "22"}]}}),
    # A stale version, which must be ignored rather than applied.
    frame({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
        "textDocument": {"uri": lean_uri, "version": 2},
        "contentChanges": [{"text": "wiped\n"}]}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
logs = [m["params"]["message"] for m in notifications(messages, "window/logMessage")]
check("the incremental change applied", answers[2]["result"]["openDocumentBytes"],
      len("def a := 22\n".encode()))
check_that("a non-increasing version is refused and said so",
           any("not newer than" in m for m in logs), logs)

# Closing clears the client's diagnostics for that URI. A client keeps the last published set until
# told otherwise, so an omitted clear leaves diagnostics on a file nobody holds.
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    open_document(lean_uri, source),
    frame({"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {
        "textDocument": {"uri": lean_uri}}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
published = notifications(messages, "textDocument/publishDiagnostics")
check("closing publishes an empty diagnostic set", len(published), 1)
check("for the document that closed", published[0]["params"]["uri"], lean_uri)
check("and it is empty", published[0]["params"]["diagnostics"], [])
check("the document is gone", responses(messages)[2]["result"]["openDocuments"], 0)

# --- cancellation ------------------------------------------------------------------------------
# The cancellation arrives before the request it names, which is the case a queue can actually
# demonstrate deterministically: the reader applies it immediately, so the worker sees it when the
# request comes up for service and answers -32800 instead of running it.
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": 2}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 4, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
check("a cancelled request is answered RequestCancelled", answers[2]["error"]["code"], -32800)
check_that("and it is answered exactly once",
           len([m for m in messages if m.get("id") == 2]) == 1, messages)
check_that("an uncancelled request is unaffected", "result" in answers[3], answers[3])

# --- bounds ------------------------------------------------------------------------------------
# The document bound refuses; it does not truncate, and it does not stop the session.
big = "-- " + ("x" * (16 * 1024 * 1024)) + "\n"
code, messages, _ = run(b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    open_document(lean_uri, big),
    frame({"jsonrpc": "2.0", "id": 2, "method": "$/lean-fmt/health"}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown"}),
    frame({"jsonrpc": "2.0", "method": "exit"}),
]))
answers = responses(messages)
shown = [m["params"]["message"] for m in notifications(messages, "window/showMessage")]
check("an oversized document is refused", answers[2]["result"]["openDocuments"], 0)
check_that("and the refusal says so", any("exceeds" in m for m in shown), shown)
check("the session continues", code, 0)

if failures:
    print(f"\n{len(failures)} check(s) failed: {failures}")
    sys.exit(1)
PY

printf 'lean-fmt language server transport and document lifecycle passed\n'
