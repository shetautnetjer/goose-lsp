// A standalone consumer of goose-lsp's public host interface. The Python
// runner checks each JSON answer and the mock server's received messages.
import std;
import os;

extern fn golsp_start(repo: const u8[:], log: const u8[:], init_json: const u8[:], argv: const u8[:],
                     env: const u8[:], lang_id: const u8[:]) -> bool;
extern fn golsp_ask(question: const u8[:], out: u8[>..]&);
extern fn golsp_stop();

fn ask(label: const u8[:], question: const u8[:]) {
    var out: u8[>..] = [];
    golsp_ask(question, out);
    print(label, "\t", out);
}

fn server_args(python: const u8[:], mock: const u8[:], mode: const u8[:], repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(python); out.push(0);
    out.append(mock); out.push(0);
    out.append(mode); out.push(0);
    out.append(repo); out.push(0);
    return out;
}

fn main() {
    let a = args();
    assert(a.len == 4); // fixture directory, Python executable, mock source
    let repo = a[1];
    var extra_env: u8[>..] = [];
    extra_env.append("GOLSP_TEST_VALUE=from-client"); extra_env.push(0);
    let cmd = server_args(a[2], a[3], "normal", repo);
    assert(golsp_start(repo, str(repo, "/server.log"), "{\"mock\":{\"enabled\":true}}", cmd, extra_env, "typescript"));
    ask("malformed", "{");
    ask("unknown", "{\"op\":\"unknown\"}");
    ask("missing-file", "{\"op\":\"diagnostics\",\"file\":\"absent.ts\",\"settle\":\"publish\"}");
    ask("missing-position", "{\"op\":\"implementations\",\"file\":\"sample.ts\"}");
    ask("first", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"publish\"}");
    assert(write_file(str(repo, "/sample.ts"), "fixed\n"));
    ask("changed", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"check\"}");
    ask("implementations", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":3,\"col\":5}");
    ask("special-name", "{\"op\":\"diagnostics\",\"file\":\"a#b c%.ts\",\"settle\":\"publish\"}");
    golsp_stop();
    ask("stopped", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\"}");

    let dying = server_args(a[2], a[3], "die", repo);
    assert(golsp_start(repo, str(repo, "/dying.log"), "{}", dying, "", "typescript"));
    ask("death-request", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":1,\"col\":1}");
    ask("dead", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":1,\"col\":1}");
    golsp_stop();

    // A server that never reports indexing is not waited on; its error
    // answer is an error; its death mid-question ends the question.
    let quiet = server_args(a[2], a[3], "quiet", repo);
    assert(golsp_start(repo, str(repo, "/quiet.log"), "{}", quiet, "", "typescript"));
    ask("quiet-error", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":1,\"col\":1}");
    ask("quiet-dies", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"publish\"}");
    golsp_stop();

    // A server that publishes nothing for a clean file answers after quiet_ms
    // of silence, not after the two-minute deadline.
    let silent = server_args(a[2], a[3], "silent", repo);
    assert(golsp_start(repo, str(repo, "/silent.log"), "{}", silent, "", "lua"));
    ask("silent-clean", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"publish\",\"quiet_ms\":500}");
    golsp_stop();

    // A server that speaks partway through the silence restarts it; its set,
    // published after the first 500 ms, is the answer.
    let trickle = server_args(a[2], a[3], "trickle", repo);
    assert(golsp_start(repo, str(repo, "/trickle.log"), "{}", trickle, "", "lua"));
    ask("trickle-late", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"publish\",\"quiet_ms\":500}");
    golsp_stop();

    // A server that rejects initialization, even with an empty message, is not started.
    let failing = server_args(a[2], a[3], "initfail", repo);
    assert(!golsp_start(repo, str(repo, "/initfail.log"), "{}", failing, "", "typescript"));
    ask("init-rejected", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\"}");
    golsp_stop();

    // Indexing reported only after the first question still holds later
    // lookups; a set published for older text is not the answer.
    let late = server_args(a[2], a[3], "late", repo);
    assert(golsp_start(repo, str(repo, "/late.log"), "{}", late, "", "typescript"));
    ask("late-first", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":1,\"col\":1}");
    ask("late-second", "{\"op\":\"implementations\",\"file\":\"sample.ts\",\"line\":1,\"col\":1}");
    ask("late-diagnostics", "{\"op\":\"diagnostics\",\"file\":\"sample.ts\",\"settle\":\"publish\"}");
    golsp_stop();

    var absent: u8[>..] = [];
    absent.append(str(repo, "/no-such-server")); absent.push(0);
    assert(!golsp_start(repo, str(repo, "/absent.log"), "{}", absent, "", "typescript"));
    golsp_stop();
    ask("failed-start", "{}");
}
