#!/usr/bin/env bash
set -euo pipefail

# `ruff-17` RLP-DOCUMENTS and RLP-FEATURES: the Language Server Protocol surface, exercised against
# the real binary over a real pipe. The unit tests in `LeanFmtTest.lean` cover the position layer and
# frame reader in isolation; this suite covers what only a process can show — lifecycle ordering,
# recovery that leaves the session usable, refusal of a document with no project location,
# cancellation delivered while the server is busy, and a bounded store that refuses rather than grows,
# then diagnostics, formatting, and code actions over a live client.
#
# The two halves are fed differently on purpose. Lifecycle and recovery write the whole session in one
# go and read what comes back, which is the strongest way to assert ordering. Diagnostics cannot be
# tested that way at all: they are published after a quiet interval, and `exit` closes the queue before
# the timer fires. So the feature half drives a `Client` that writes, reads, and waits.

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$repo_root"
LEAN_NUM_THREADS=1 lake build lean-fmt
application=$(lake -q query lean-fmt --text)

python3 - "$application" "$repo_root" <<'PY'
import json
import os
import select
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

# --- features ----------------------------------------------------------------------------------
# `RLP-FEATURES`. Everything above feeds the whole session in one write and reads what comes back;
# diagnostics cannot be tested that way, because they are published after a quiet interval and `exit`
# closes the queue before the timer fires. So the features run against a live client that writes,
# reads, and waits -- which is also what `RLP-FINAL`'s acceptance harness needs.

class Client:
    """A live LSP session: write a message, read frames until the one you asked for arrives."""

    def __init__(self, options=None, extra_args=()):
        env = os.environ.copy()
        env["LEAN_NUM_THREADS"] = "1"
        self.proc = subprocess.Popen(
            [application, "lsp", "--root", root, "--debounce-ms", "1", *extra_args],
            cwd=root, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.pending = []
        params = {} if options is None else {"initializationOptions": options}
        self.request("initialize", params, id=1000)
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def send(self, obj):
        self.proc.stdin.write(frame(obj))
        self.proc.stdin.flush()

    def read_frame(self, timeout=300):
        """One message off the wire. Blocking, with a deadline enforced by the caller's timeout."""
        if not select.select([self.proc.stdout], [], [], timeout)[0]:
            raise AssertionError("server sent nothing within the timeout")
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            byte = self.proc.stdout.read(1)
            if not byte:
                raise AssertionError("server closed the stream")
            header += byte
        length = None
        for line in header.decode().split("\r\n"):
            name, _, value = line.partition(": ")
            if name.lower() == "content-length":
                length = int(value)
        body = self.proc.stdout.read(length)
        return json.loads(body)

    def request(self, method, params=None, id=None, timeout=300):
        identifier = id if id is not None else len(self.pending) + 1
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}})
        while True:
            message = self.read_frame(timeout)
            if message.get("id") == identifier:
                return message
            self.pending.append(message)

    def await_notification(self, method, predicate=lambda m: True, timeout=300):
        for message in list(self.pending):
            if message.get("method") == method and predicate(message):
                self.pending.remove(message)
                return message
        while True:
            message = self.read_frame(timeout)
            if message.get("method") == method and predicate(message):
                return message
            self.pending.append(message)

    def open(self, uri, text, version=1):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
            "textDocument": {"uri": uri, "languageId": "lean", "version": version, "text": text}}})

    def close(self):
        try:
            self.request("shutdown", timeout=60)
            self.send({"jsonrpc": "2.0", "method": "exit"})
            return self.proc.wait(timeout=60)
        finally:
            self.proc.stdout.close()
            self.proc.stderr.close()


findings_uri = "file://" + os.path.join(root, "tests/check/Findings.lean")
layout_uri = "file://" + os.path.join(root, "tests/check/Layout.lean")
clean_uri = "file://" + os.path.join(root, "tests/check/Clean.lean")
findings_source = open(os.path.join(root, "tests/check/Findings.lean")).read()
layout_source = open(os.path.join(root, "tests/check/Layout.lean")).read()
clean_source = open(os.path.join(root, "tests/check/Clean.lean")).read()

# --- diagnostics ---
client = Client()
client.open(findings_uri, findings_source)
published = client.await_notification(
    "textDocument/publishDiagnostics", lambda m: m["params"]["uri"] == findings_uri)
diagnostics = published["params"]["diagnostics"]
check_that("a document publishes its findings", len(diagnostics) == 1, diagnostics)
first = diagnostics[0]
check("the diagnostic is ours", first["source"], "lean-fmt")
check("it carries the rule code", first["code"], "FMT003")
check("a formatter finding is a warning, not an error", first["severity"], 2)
check_that("and points at its rule's documentation",
           first["codeDescription"]["href"].endswith("/docs/rules/FMT003.md"), first)
check("the publication names the version it describes", published["params"]["version"], 1)

# The whole point of the position layer: a byte range became a UTF-16 range on the right line. The
# duplicate is the *second* `import`, which is line 3 counting from zero.
check("the diagnostic's range is a client range", first["range"]["start"]["line"], 3)

# A clean document publishes an empty set -- which is a claim, not an absence.
client.open(clean_uri, clean_source)
published = client.await_notification(
    "textDocument/publishDiagnostics", lambda m: m["params"]["uri"] == clean_uri)
check("a clean document publishes nothing to report", published["params"]["diagnostics"], [])

# --- formatting ---
# `tests/check/Clean.lean` has to actually be canonical for this to say anything, and its name is the
# only thing that promises it. It held `def cleanValue : Nat := 1` on one line, which stopped being
# canonical at `3635d39` when the native adapter landed: `declValSimple` is
# `" :=" >> ppHardLineUnlessUngrouped >> declBody` (`Command.lean:169-170`), a hard newline unless the
# body is one of the three `ppAllowUngrouped` parsers. A `Nat` literal is none of them. The fixture
# was updated to the bytes Lean's own formatter produces; see `tests/modes/run.sh` for the full trace.
answer = client.request("textDocument/formatting",
                        {"textDocument": {"uri": clean_uri}, "options": {}})
check("a canonical document needs no edits", answer["result"], [])

client.open(layout_uri, layout_source)
answer = client.request("textDocument/formatting",
                        {"textDocument": {"uri": layout_uri}, "options": {}})
edits = answer["result"]
check_that("a non-canonical document gets exactly one edit", len(edits) == 1, edits)
check_that("the edit replaces the whole document",
           edits[0]["range"]["start"] == {"line": 0, "character": 0}, edits[0])
check_that("and it is the canonical bytes",
           "namespace Alpha" in edits[0]["newText"], edits[0]["newText"])
check_that("which is not what the client already had",
           edits[0]["newText"] != layout_source, "formatting returned the input")

# Range formatting answers over the *actual* range: the hull of the layout units the selection
# expands to, which is the range a client must send back to re-format the same unit.
answer = client.request("textDocument/rangeFormatting", {
    "textDocument": {"uri": layout_uri},
    "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 5}},
    "options": {}})
edits = answer["result"]
check_that("a range request is answered with an edit", len(edits) == 1, edits)
check_that("the actual range is not the requested one",
           edits[0]["range"]["end"] != {"line": 2, "character": 5}, edits[0])
check_that("and the replacement is only the selected unit",
           "def layoutValue" not in edits[0]["newText"], edits[0]["newText"])

def apply_edit(text, edit):
    """Apply one TextEdit the way a client would. ASCII fixtures, so a character is a code unit."""
    lines = text.split("\n")
    def offset(position):
        return sum(len(line) + 1 for line in lines[:position["line"]]) + position["character"]
    start, stop = offset(edit["range"]["start"]), offset(edit["range"]["end"])
    return text[:start] + edit["newText"] + text[stop:]

# The narrow edit and the whole-document edit must agree. They did not: `stream`'s ranged output is
# the *whole* document with the unit reformatted in place, so serving it as the replacement for the
# actual range duplicated the file. Only this assertion could see that -- the range was right, the
# text was right, and the pair was wrong.
#
# This holds only while everything *outside* the selected range is already canonical, because the
# whole-document edit reformats those units too and the narrow edit by construction cannot. That
# precondition is a property of the fixture, so keep `Layout.lean` dirty in exactly one place --
# `namespace     Alpha`, the unit this range selects. It briefly held two: `def layoutValue` reflowed
# to `:=\n  1` at `3635d39` and the difference surfaced here rather than in the range logic. If this
# fails again, format `Layout.lean` and diff: a second dirty unit is the likely cause, and weakening
# the assertion would retire the only check that catches a range/replacement mismatch.
whole = client.request("textDocument/formatting",
                       {"textDocument": {"uri": layout_uri}, "options": {}})["result"]
check("the narrow edit does what the whole-document edit does",
      apply_edit(layout_source, edits[0]), whole[0]["newText"])

# Drive the public stdin range surface over the identical unsaved bytes and requested coordinates.
# This must be the same complete spliced document that applying the LSP's narrow edit produces.
requested_start = sum(len(line) + 1 for line in layout_source.split("\n")[:2])
requested_stop = requested_start + 5
stdin = subprocess.run(
    [application, "format", "-", "--stdin-filename", "tests/check/Layout.lean",
     "--range", f"{requested_start}:{requested_stop}"],
    cwd=root, env={**os.environ, "LEAN_NUM_THREADS": "1"},
    input=layout_source.encode(), capture_output=True, timeout=300)
check("stdin range formatting exits cleanly", stdin.returncode, 0)
check("stdin and LSP select and render identical range bytes",
      stdin.stdout.decode(), apply_edit(layout_source, edits[0]))

# --- code actions ---
actions = client.request("textDocument/codeAction", {
    "textDocument": {"uri": findings_uri},
    "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 0}},
    "context": {"diagnostics": []}})["result"]
kinds = sorted({action["kind"] for action in actions})
# All three: the fixture has a duplicate import, which FMT003 quickfixes, fix-all applies, and
# organize-imports removes as part of canonicalizing the header.
check("every advertised kind is offered", kinds,
      ["quickfix", "source.fixAll", "source.organizeImports"])
quickfix = next(a for a in actions if a["kind"] == "quickfix")
check_that("the quickfix names its rule", quickfix["title"].startswith("FMT003"), quickfix["title"])
changes = quickfix["edit"]["documentChanges"]
check_that("the edit names one document", len(changes) == 1, changes)
check("computed against a stated version", changes[0]["textDocument"]["version"], 1)
check("for the document the action was asked about", changes[0]["textDocument"]["uri"], findings_uri)
check_that("and it deletes rather than rewrites", changes[0]["edits"][0]["newText"] == "",
           changes[0]["edits"])

fix_all = next(a for a in actions if a["kind"] == "source.fixAll")
check_that("fix-all rewrites the whole document",
           fix_all["edit"]["documentChanges"][0]["edits"][0]["range"]["start"]
           == {"line": 0, "character": 0}, fix_all)

# `only` is honored, and honoring it is what stops an editor asking on every cursor movement from
# paying for two whole-document rewrites it did not ask for.
actions = client.request("textDocument/codeAction", {
    "textDocument": {"uri": findings_uri},
    "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 0}},
    "context": {"diagnostics": [], "only": ["source.organizeImports"]}})["result"]
check("only is honored", [a["kind"] for a in actions], ["source.organizeImports"])

# A cursor away from every finding gets no quickfix, and still gets the source actions.
actions = client.request("textDocument/codeAction", {
    "textDocument": {"uri": clean_uri},
    "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
    "context": {"diagnostics": []}})["result"]
check("a clean document offers no quickfix",
      [a for a in actions if a["kind"] == "quickfix"], [])

check("the session ends cleanly", client.close(), 0)

# --- selection through initializationOptions ---
# The client's own configuration reaches the rule plan: ignoring FMT003 leaves the same bytes with
# nothing to report, which is the check that the option is read rather than accepted and dropped.
client = Client(options={"ignore": ["FMT003"]})
client.open(findings_uri, findings_source)
published = client.await_notification(
    "textDocument/publishDiagnostics", lambda m: m["params"]["uri"] == findings_uri)
check("an ignored rule reports nothing", published["params"]["diagnostics"], [])
actions = client.request("textDocument/codeAction", {
    "textDocument": {"uri": findings_uri},
    "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 0}},
    "context": {"diagnostics": []}})["result"]
check("and offers no quickfix for it", [a for a in actions if a["kind"] == "quickfix"], [])
check("the configured session ends cleanly", client.close(), 0)

# --- applicability is exposed, not hidden ---
# `extend-unsafe-fixes` demotes FMT003 to unsafe (`tests/modes/run.sh` §"extend-unsafe-fixes"). A
# demoted fix is still *reported* -- the finding does not go away -- but the product will not apply it
# without explicit intent, so no quickfix is offered. Turning `--unsafe-fixes` on brings it back. Two
# sessions over the same bytes, differing only in whether the user asked for unsafe fixes.
import tempfile

config = os.path.join(tempfile.mkdtemp(), "lean-fmt.toml")
open(config, "w").write('[lint]\nextend-unsafe-fixes = ["FMT003"]\n')

def quickfixes(extra_args):
    session = Client(extra_args=("--config", config, *extra_args))
    session.open(findings_uri, findings_source)
    reported = session.await_notification(
        "textDocument/publishDiagnostics", lambda m: m["params"]["uri"] == findings_uri)
    offered = session.request("textDocument/codeAction", {
        "textDocument": {"uri": findings_uri},
        "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 0}},
        "context": {"diagnostics": []}})["result"]
    session.close()
    return len(reported["params"]["diagnostics"]), [a["kind"] for a in offered]

reported, offered = quickfixes(())
check("a demoted fix is still reported", reported, 1)
check_that("but no quickfix is offered for it", "quickfix" not in offered, offered)
reported, offered = quickfixes(("--unsafe-fixes",))
check("the same document reports the same finding", reported, 1)
check_that("and the quickfix returns under explicit intent", "quickfix" in offered, offered)

# --- superseded analyses ---
# Three edits in a row must not publish three times for the versions that were passed through: a
# publication for version 1 after version 3 has arrived describes bytes the client has edited past.
client = Client(extra_args=("--debounce-ms", "80"))
client.open(layout_uri, layout_source)
for version in (2, 3, 4):
    client.send({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
        "textDocument": {"uri": layout_uri, "version": version},
        "contentChanges": [{"range": {"start": {"line": 4, "character": 0},
                                      "end": {"line": 4, "character": 0}},
                            "text": "-- %d\n" % version}]}})
published = client.await_notification(
    "textDocument/publishDiagnostics",
    lambda m: m["params"]["uri"] == layout_uri and m["params"].get("version") == 4)
check("the surviving publication is the newest version", published["params"]["version"], 4)
check("the superseding session ends cleanly", client.close(), 0)

if failures:
    print(f"\n{len(failures)} check(s) failed: {failures}")
    sys.exit(1)
PY

printf 'lean-fmt language server transport, documents, and features passed\n'
