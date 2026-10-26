"""A deliberately small stdio LSP fixture, not a real language server."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

if sys.argv[1] == "child":
    while True:
        signal.pause()

mode, fixture = sys.argv[1], Path(sys.argv[2])
transcript = (fixture / (mode + ".jsonl")).open("a", buffering=1)


def record(kind, value):
    transcript.write(json.dumps({"kind": kind, "value": value}) + "\n")


def send(value, fragment=False):
    body = json.dumps(value, separators=(",", ":")).encode()
    packet = b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    if fragment:
        # Exercise a header and body received over several reads.
        for start, end in [(0, 9), (9, 30), (30, len(packet))]:
            sys.stdout.buffer.write(packet[start:end])
            sys.stdout.buffer.flush()
            time.sleep(0.01)
    else:
        sys.stdout.buffer.write(packet)
        sys.stdout.buffer.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def response(ident, result):
    send({"jsonrpc": "2.0", "id": ident, "result": result})


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        name, value = line.decode().split(":", 1)
        headers[name.lower()] = value.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))


record("process", {"pid": os.getpid(), "cwd": os.getcwd(), "env": os.getenv("GOLSP_TEST_VALUE")})
documents = {}
while (message := read_message()) is not None:
    record("received", message)
    method, params = message.get("method"), message.get("params", {})
    if method == "initialize":
        root = params["rootUri"]
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {
            "textDocumentSync": 1, "implementationProvider": True}}}, fragment=True)
    elif method == "initialized":
        # "quiet" is a server that never reports its indexing (pyright, typescript).
        if mode != "quiet":
            notify("experimental/serverStatus", {"quiescent": True})
        if mode == "normal":
            child = subprocess.Popen([sys.executable, __file__, "child"])
            record("child", {"pid": child.pid})
            send({"jsonrpc": "2.0", "id": "config-fixture", "method": "workspace/configuration",
                  "params": {"items": [{"section": "mock"}]}})
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        documents[doc["uri"]] = doc["text"]
    elif method == "textDocument/didChange":
        documents[params["textDocument"]["uri"]] = params["contentChanges"][0]["text"]
    elif method == "textDocument/didSave" and mode == "quiet":
        # The second save is the diagnostics question's: die while it waits.
        saves = globals().get("saves", 0) + 1
        if saves == 2:
            record("exit", {"reason": "died during diagnostics"})
            sys.exit(0)
    elif method == "textDocument/didSave":
        uri = params["textDocument"]["uri"]
        notify("$/progress", {"token": "flycheck-fixture", "value": {"kind": "begin"}})
        diagnostics = []
        if documents[uri] == "broken\n":
            diagnostics = [{"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 4}},
                            "severity": 2, "source": "mock", "code": 7, "message": 'fixture "warning"'}]
        notify("textDocument/publishDiagnostics", {"uri": uri, "diagnostics": diagnostics})
        notify("$/progress", {"token": "flycheck-fixture", "value": {"kind": "end"}})
    elif method == "textDocument/implementation":
        if mode == "die":
            record("exit", {"reason": "deliberate EOF"})
            sys.exit(0)
        if mode == "quiet":
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "fixture failure"}})
            continue
        response(message["id"], [
            {"uri": root + "/impl.ts", "range": {"start": {"line": 6, "character": 2}}},
            {"targetUri": root + "/linked.ts", "targetSelectionRange": {"start": {"line": 8, "character": 3}}},
            {"uri": "file:///outside/ignored.ts", "range": {"start": {"line": 0, "character": 0}}},
            # A sibling folder whose name starts with the repo's: outside too.
            {"uri": root + "-extra/ignored.ts", "range": {"start": {"line": 0, "character": 0}}},
            # A name with a '#' and a space, percent-encoded as servers send it.
            {"uri": root + "/a%23b%20c.ts", "range": {"start": {"line": 1, "character": 0}}},
        ])
    elif method == "shutdown":
        response(message["id"], None)
    elif method == "exit":
        record("exit", {"reason": "graceful"})
        # The child deliberately stays alive so proc_close must close the group.
        break
