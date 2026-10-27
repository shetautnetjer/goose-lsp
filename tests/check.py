"""Run the Goose consumer, checking both answers and wire messages."""
import json
import os
from pathlib import Path
import signal
from urllib.parse import quote
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
mock = Path(__file__).with_name("mock_server.py").resolve()
# A repo path and a file name with characters a URI must encode.
fixture = Path(tempfile.mkdtemp(prefix="fixture #% ", dir=binary.parent)).resolve()
(fixture / "sample.ts").write_text("broken\n")
(fixture / "a#b c%.ts").write_text("fine\n")


def records(mode):
    path = fixture / (mode + ".jsonl")
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def running(pid):
    # Linux: a killed child may await collection by the container's PID 1.
    # A zombie has exited and cannot execute; portable fallback checks kill(0).
    status = Path(f"/proc/{pid}/stat")
    if status.exists():
        return status.read_text().rsplit(")", 1)[1].split()[0] != "Z"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


try:
    began = time.monotonic()
    result = subprocess.run([str(binary), str(fixture), sys.executable, str(mock)],
                            capture_output=True, text=True, timeout=25)
    took = time.monotonic() - began
    (fixture / "client.stdout").write_text(result.stdout)
    (fixture / "client.stderr").write_text(result.stderr)
    require(result.returncode == 0, f"consumer exit {result.returncode}: {result.stderr}")
    # Without the fixes the quiet server costs 180 s (indexing wait) and 120 s (spinning after death).
    require(took < 15, f"the run took {took:.1f} s: something waited on a silent or dead server")
    answers = {}
    for line in result.stdout.splitlines():
        name, body = line.split("\t", 1)
        require(name not in answers, f"duplicate answer: {name}")
        answers[name] = json.loads(body)
    expected = {"malformed", "unknown", "missing-file", "missing-position", "first", "changed",
                "implementations", "stopped", "death-request", "dead", "failed-start", "quiet-error", "quiet-dies",
                "special-name", "init-rejected", "late-first", "late-second", "late-diagnostics"}
    require(set(answers) == expected, f"missing or extra answers: {set(answers) ^ expected}")
    for name in ("malformed", "unknown", "missing-file", "missing-position"):
        require(answers[name].get("ok") is False and answers[name].get("error"), f"{name} must fail")
    require(answers["first"] == {"ok": True, "diagnostics": [{"line": 1, "col": 2, "end_line": 1,
            "end_col": 5, "severity": "warning", "source": "mock", "code": "7", "message": 'fixture "warning"'}]},
            f"diagnostics conversion: {answers['first']}")
    require(answers["changed"] == {"ok": True, "diagnostics": []}, "changed file must clear old diagnostics")
    require(answers["implementations"] == {"ok": True, "locations": [
        {"file": "impl.ts", "line": 7, "col": 3}, {"file": "linked.ts", "line": 9, "col": 4},
        {"file": "a#b c.ts", "line": 2, "col": 1}]},
        "Location/LocationLink conversion, external and sibling URI filtering, URI decoding")
    require(answers["quiet-error"] == {"ok": False, "error": "fixture failure"}, f"error response: {answers['quiet-error']}")
    require(answers["quiet-dies"].get("ok") is False and answers["quiet-dies"].get("gone") is True,
            f"server death during diagnostics: {answers['quiet-dies']}")
    require(answers["special-name"] == {"ok": True, "diagnostics": []}, f"special file name: {answers['special-name']}")
    require(answers["init-rejected"].get("ok") is False and answers["init-rejected"].get("gone") is True,
            f"a rejected initialize must not start the session: {answers['init-rejected']}")
    require(answers["late-first"] == {"ok": True, "locations": []}, f"late-first: {answers['late-first']}")
    require(answers["late-second"] == {"ok": True, "locations": [{"file": "impl.ts", "line": 1, "col": 1}]},
            f"a lookup after indexing began must wait for it to end: {answers['late-second']}")
    require(answers["late-diagnostics"] == {"ok": True, "diagnostics": []},
            f"a set for older text must not be the answer: {answers['late-diagnostics']}")
    require(answers["death-request"].get("ok") is False, "request interrupted by EOF must fail")
    for name in ("stopped", "dead", "failed-start"):
        require(answers[name].get("ok") is False and answers[name].get("gone") is True, f"{name} must report gone")

    normal = records("normal")
    received = [row["value"] for row in normal if row["kind"] == "received"]
    def messages(method):
        return [row for row in received if row.get("method") == method]
    process = next(row["value"] for row in normal if row["kind"] == "process")
    require(process["cwd"] == str(fixture) and process["env"] == "from-client", "cwd/environment forwarding")
    init = messages("initialize")[0]["params"]
    root_uri = "file://" + quote(str(fixture))
    require(init["rootUri"] == root_uri, f"initialize rootUri: {init['rootUri']}")
    require(init["initializationOptions"] == {"mock": {"enabled": True}}, "initialize options")
    config = [row for row in received if row.get("id") == "config-fixture"]
    require(len(config) == 1 and config[0].get("result") == [{"enabled": True}], "server configuration request")
    special = [row for row in messages("textDocument/didOpen")
               if row["params"]["textDocument"]["uri"] == root_uri + "/a%23b%20c%25.ts"]
    require(len(special) == 1, "the special file's didOpen URI must be percent-encoded")
    opens = [row for row in messages("textDocument/didOpen") if row["params"]["textDocument"]["uri"].endswith("/sample.ts")]
    changes = messages("textDocument/didChange")
    require(len(opens) == 1 and opens[0]["params"]["textDocument"]["text"] == "broken\n", "initial didOpen text")
    require(opens[0]["params"]["textDocument"]["languageId"] == "typescript", "didOpen language")
    require(opens[0]["params"]["textDocument"]["version"] == 1, "didOpen version")
    require([row["params"]["textDocument"]["version"] for row in changes] == [2, 3], "didChange versions")
    require(all(row["params"]["contentChanges"] == [{"text": "fixed\n"}] for row in changes), "resync text")
    require(len(messages("textDocument/didSave")) == 4, "didSave per question")
    require(messages("textDocument/implementation")[0]["params"]["position"] == {"line": 2, "character": 4},
            "request position must be zero-based")
    require(len(messages("shutdown")) == 1 and len(messages("exit")) == 1, "graceful shutdown and exit")
    require(any(row == {"kind": "exit", "value": {"reason": "graceful"}} for row in normal), "server saw exit")
    child = next(row["value"]["pid"] for row in normal if row["kind"] == "child")
    deadline = time.monotonic() + 2
    while running(child) and time.monotonic() < deadline:
        time.sleep(0.02)
    require(not running(process["pid"]) and not running(child), "stop must terminate server and child group")
    died = records("die")
    require(any(row == {"kind": "exit", "value": {"reason": "deliberate EOF"}} for row in died), "death fixture ran")
    print("PASS goose-lsp standalone: 18 answers; initialization, configuration, framing, synchronization,")
    print("diagnostics, implementations, graceful stop/group cleanup, EOF and failed executable,")
    print("error answers, a server that never reports indexing, death during diagnostics, encoded URIs,")
    print("a rejected initialize, late indexing signals, a set for older text.")
    print(f"Evidence: {fixture}")
finally:
    # Only fixture-owned process groups, including when a consumer assertion fails.
    for mode in ("normal", "die", "quiet", "initfail", "late"):
        for row in records(mode):
            if row["kind"] == "process":
                try:
                    os.killpg(row["value"]["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
