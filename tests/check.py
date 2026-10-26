"""Run the Goose consumer, checking both answers and wire messages."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
mock = Path(__file__).with_name("mock_server.py").resolve()
fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=binary.parent)).resolve()
(fixture / "sample.ts").write_text("broken\n")


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
    result = subprocess.run([str(binary), str(fixture), sys.executable, str(mock)],
                            capture_output=True, text=True, timeout=25)
    (fixture / "client.stdout").write_text(result.stdout)
    (fixture / "client.stderr").write_text(result.stderr)
    require(result.returncode == 0, f"consumer exit {result.returncode}: {result.stderr}")
    answers = {}
    for line in result.stdout.splitlines():
        name, body = line.split("\t", 1)
        require(name not in answers, f"duplicate answer: {name}")
        answers[name] = json.loads(body)
    expected = {"malformed", "unknown", "missing-file", "missing-position", "first", "changed",
                "implementations", "stopped", "death-request", "dead", "failed-start"}
    require(set(answers) == expected, f"missing or extra answers: {set(answers) ^ expected}")
    for name in ("malformed", "unknown", "missing-file", "missing-position"):
        require(answers[name].get("ok") is False and answers[name].get("error"), f"{name} must fail")
    require(answers["first"] == {"ok": True, "diagnostics": [{"line": 1, "col": 2, "end_line": 1,
            "end_col": 5, "severity": "warning", "source": "mock", "code": "7", "message": 'fixture "warning"'}]},
            f"diagnostics conversion: {answers['first']}")
    require(answers["changed"] == {"ok": True, "diagnostics": []}, "changed file must clear old diagnostics")
    require(answers["implementations"] == {"ok": True, "locations": [
        {"file": "impl.ts", "line": 7, "col": 3}, {"file": "linked.ts", "line": 9, "col": 4}]},
        "Location/LocationLink conversion or external URI filtering")
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
    require(init["rootUri"] == "file://" + str(fixture), "initialize rootUri")
    require(init["initializationOptions"] == {"mock": {"enabled": True}}, "initialize options")
    config = [row for row in received if row.get("id") == "config-fixture"]
    require(len(config) == 1 and config[0].get("result") == [{"enabled": True}], "server configuration request")
    opens = messages("textDocument/didOpen")
    changes = messages("textDocument/didChange")
    require(len(opens) == 1 and opens[0]["params"]["textDocument"]["text"] == "broken\n", "initial didOpen text")
    require(opens[0]["params"]["textDocument"]["languageId"] == "typescript", "didOpen language")
    require(opens[0]["params"]["textDocument"]["version"] == 1, "didOpen version")
    require([row["params"]["textDocument"]["version"] for row in changes] == [2, 3], "didChange versions")
    require(all(row["params"]["contentChanges"] == [{"text": "fixed\n"}] for row in changes), "resync text")
    require(len(messages("textDocument/didSave")) == 3, "didSave per question")
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
    print("PASS goose-lsp standalone: 11 answers; initialization, configuration, framing, synchronization,")
    print("diagnostics, implementations, graceful stop/group cleanup, EOF and failed executable.")
    print(f"Evidence: {fixture}")
finally:
    # Only fixture-owned process groups, including when a consumer assertion fails.
    for mode in ("normal", "die"):
        for row in records(mode):
            if row["kind"] == "process":
                try:
                    os.killpg(row["value"]["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
