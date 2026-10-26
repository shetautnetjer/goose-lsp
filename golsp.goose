// goose-lsp: a Goose library that keeps one language server running
// (rust-analyzer, pyright, typescript-language-server, JetBrains' Kotlin
// server) and answers questions about the code through it. It is compiled on
// its own to C (goose --standalone, scripts/build.sh) and linked into the
// program that uses it, through native/glue.c, so the client never adds to
// that program's own Goose build: Goose compiles whole programs, and this is
// a separate one with its own runtime, entered through the exports below.
// Swan (github.com/shetautnetjer/Swan) is its first user.
//
// Questions and answers are JSON. Positions are 1-based:
//   {"op":"diagnostics","file":"src/lib.rs","settle":"check"|"publish"}
//     -> {"ok":true,"diagnostics":[{"line":..,"col":..,"end_line":..,"end_col":..,
//         "severity":"error","source":"rustc","code":"E0061","message":".."}]}
//   {"op":"implementations","file":"src/lib.rs","line":12,"col":11}
//     -> {"ok":true,"locations":[{"file":"src/lib.rs","line":23,"col":1}]}
// Each question re-reads its file from disk and tells the server, so edits
// made since the last question are seen. A server that dies is reported
// ("gone":true), never fatal: this code runs inside the host program. One server per
// process for now.

import std;
import os;
import json;
import dictionary;

extern fn proc_open(argv: const u8[:], cwd: const u8[:], env: const u8[:], log: const u8[:]) -> i64;
extern fn proc_write(h: i64, data: const u8[:]) -> bool;
// Fills buf from the start; a plain slice rather than a builder, because this
// library's builders belong to its own runtime and native/proc.c is built
// with the core's.
extern fn proc_read(h: i64, timeout_ms: i64, buf: u8[:]) -> i64;
extern fn proc_close(h: i64, grace_ms: i64);

var server: i64 = 0;
var inbox: u8[>..];             // bytes from the server not yet taken as messages
var chunk: u8[65536];
var next_id: i64 = 1;
var root_uri: u8[..4096];
var repo_dir: u8[..4096];
var log_path: u8[..4096];
var init_options: u8[>..];
var indexing_done = false;
var checking = 0;               // flycheck runs begun and not yet ended
var language_id: u8[>..];       // what didOpen says the files are: rust, python, typescript
var checks_ended = 0;
var importing = false;          // the Kotlin server is importing the build (Gradle) and has not finished
var import_failed: u8[>..];     // why the last import failed, if it did           // flycheck runs finished, ever: a question waits for the next one
var gone = false;               // the server has died; this runs inside the host, so never exit
var trace = false;              // GOLSP_TRACE=1: every message from the server goes to the log
// The latest diagnostics the server published for each file, as our JSON:
// a file's set lives at diag_text[diag_at[uri]..][..diag_len[uri]]. The
// server publishes only when a set changes, so an unchanged file is answered
// from here. Older sets stay in diag_text until the session restarts.
var diag_text: u8[>..];
var diag_at = dictionary<u8[..1024], i64> {};
var diag_len = dictionary<u8[..1024], i64> {};
var diag_seq = dictionary<u8[..1024], i64> {};  // which publish, counting from the session's start
var publishes = 0;

fn note(s: const u8[:]) { append_file(log_path, str(s, "\n")); }

fn send(body: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, "Content-Length: ", body.len, "\r\n\r\n");
    msg.append(body);
    if gone || !proc_write(server, msg) { note("server gone"); gone = true; }
}

// The next whole message from the server into `out`, waiting up to
// timeout_ms. False on timeout.
fn take_message(timeout_ms: i64, out: u8[>..]&) -> bool {
    let deadline = clock() + timeout_ms / 1000.0;
    loop {
        let sep = find(inbox, "\r\n\r\n");
        if sep >= 0 {
            var len = -1;
            each_split(inbox[..sep], '\n') { h =>
                let line = trim(h);
                if starts_with(line, "Content-Length:") {
                    let n, ok = parse_int(trim(line[15..]));
                    if ok { len = n; }
                }
            };
            if len >= 0 && inbox.len >= sep + 4 + len {
                out.append(inbox[sep + 4..sep + 4 + len]);
                var rest: u8[>..] = [];
                rest.append(inbox[sep + 4 + len..]);
                inbox.clear();
                inbox.append(rest);
                return true;
            }
        }
        let left = ((deadline - clock()) * 1000.0) as i64;
        if left <= 0 || gone { return false; }
        let n = proc_read(server, min(left, 1000), chunk[..]);
        if n > 0 { inbox.append(chunk[..n]); }
        if n < 0 { note("server closed its output"); gone = true; return false; }
    }
}

// Answers a request the server makes of us, so it never waits on one.
// A parsed JSON value written back out.
recursive fn write_json(n: json::Node&, out: u8[>..]&) {
    match n.val {
        Null => out.append("null"),
        Bool b => json::format_bool(out, b.v),
        Int i => json::format_int(out, i.v),
        Num x => json::format_number(out, x.v),
        Str t => json::format_string(out, t.s),
        Arr => {
            out.push('[');
            var k = 0;
            var c = n.first;
            while c { if k > 0 { out.push(','); } k++; write_json(c, out); c .= c.next; }
            out.push(']');
        },
        Obj => {
            out.push('{');
            var k = 0;
            var c = n.first;
            while c {
                if k > 0 { out.push(','); }
                k++;
                json::format_string(out, c.key);
                out.push(':');
                write_json(c, out);
                c .= c.next;
            }
            out.push('}');
        },
    }
}

// A configuration section from our settings: the member named exactly that
// ("python.analysis"), else the path its dots spell (python, analysis).
fn section_of(settings: json::Node?, section: const u8[:]) -> json::Node? {
    let whole = json::member(settings, section);
    if whole { return whole; }
    var at = settings;
    each_split(section, '.') { part => at .= json::member(at, part); };
    return at;
}

fn answer_server(doc_root: json::Node&, id_text: const u8[:]) {
    let method, ok = json::as_string(json::member(doc_root, "method"));
    var body: u8[>..] = [];
    format(body, "{\"jsonrpc\":\"2.0\",\"id\":", id_text, ",\"result\":");
    if ok && method == "workspace/configuration" {
        // One answer per item: the section asked for, from our settings
        // (initialization options); the whole of them when the section is
        // not there by name, which is how rust-analyzer asks for its own.
        var sdoc: json::Node[>..] = [];
        var sdec: u8[>..] = [];
        let settings, serr = json::parse(init_options, sdoc, sdec);
        let items = json::member(json::member(doc_root, "params"), "items");
        body.push('[');
        var n = 0;
        if items {
            json::each(items) { it =>
                if n > 0 { body.push(','); }
                n++;
                let sec, s_ok = json::as_string(json::member(it, "section"));
                let found = if s_ok { section_of(settings, sec) } else { settings };
                if found { write_json(found, body); } else { body.append(init_options); }
            };
        }
        body.push(']');
        assert(serr.len >= 0);
    } else {
        body.append("null");
    }
    body.push('}');
    send(body);
}

// The raw text of a JSON id (a number or a string), to echo back.
fn id_text_of(n: json::Node?, out: u8[>..]&) {
    guard n else { return; }
    match n.val {
        Int i => json::format_int(out, i.v),
        Str s => json::format_string(out, s.s),
        _ => {},
    }
}

// Reads messages for up to timeout_ms, answering the server's requests and
// keeping track of indexing and flycheck. Calls F(message, method, id) for
// the rest. F returns true to stop waiting.
fn pump<F>(timeout_ms: i64) -> bool {
    let deadline = clock() + timeout_ms / 1000.0;
    loop {
        let left = ((deadline - clock()) * 1000.0) as i64;
        if left <= 0 { return false; }
        var msg: u8[>..] = [];
        if !take_message(left, msg) { return false; }
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, perr = json::parse(msg, doc, decoded);
        if !root { note(str("bad message: ", perr)); continue; }
        let method_in, has_method = json::as_string(json::member(root, "method"));
        var method: u8[>..] = [];     // owned, so keeping diagnostics below cannot move it
        method.append(method_in);
        let idn = json::member(root, "id");
        var idt: u8[>..] = [];
        id_text_of(idn, idt);
        if trace { note(str("<- ", method, " ", idt, " ", msg[..min(msg.len, 300)])); }
        if has_method && idt.len > 0 { answer_server(root, idt); continue; }
        if has_method && method == "$/progress" {
            let p = json::member(root, "params");
            let token, t_ok = json::as_string(json::member(p, "token"));
            let kind, k_ok = json::as_string(json::member(json::member(p, "value"), "kind"));
            if t_ok && k_ok {
                if (find(token, "ndexing") >= 0 || find(token, "cachePriming") >= 0) && kind == "end" { indexing_done = true; }
                if find(token, "flycheck") >= 0 || find(token, "cargo check") >= 0 {
                    if kind == "begin" { checking++; }
                    if kind == "end" { if checking > 0 { checking--; } checks_ended++; }
                }
            }
        }
        // rust-analyzer says when it has nothing left to load or index.
        if has_method && method == "experimental/serverStatus" {
            let q, q_ok = json::as_bool(json::member(json::member(root, "params"), "quiescent"));
            if q_ok && q { indexing_done = true; }
        }
        // JetBrains' Kotlin server imports the Gradle build before it can
        // analyse anything, and says when it starts and ends.
        if has_method && method == "intellij/importLog" {
            let p = json::member(root, "params");
            let st, st_ok = json::as_bool(json::member(p, "started"));
            let ok, ok_ok = json::as_bool(json::member(p, "succeeded"));
            let bad, bad_ok = json::as_bool(json::member(p, "failed"));
            if st_ok && st { importing = true; import_failed.clear(); }
            if (ok_ok && ok) || (bad_ok && bad) { importing = false; }
            if bad_ok && bad {
                let m, m_ok = json::as_string(json::member(p, "message"));
                var why: u8[>..] = [];
                why.append(if m_ok { m } else { "the build import failed" });
                import_failed.clear();
                import_failed.append(why);
            }
        }
        if has_method && method == "textDocument/publishDiagnostics" { keep_diagnostics(json::member(root, "params")); }
        if F(root, if has_method { method } else { "" }, idt[..]) { return true; }
    }
}

fn request(method: const u8[:], params: const u8[:]) -> i64 {
    let id = next_id;
    next_id++;
    send(str("{\"jsonrpc\":\"2.0\",\"id\":", id, ",\"method\":\"", method, "\",\"params\":", params, "}"));
    return id;
}

fn notify(method: const u8[:], params: const u8[:]) {
    send(str("{\"jsonrpc\":\"2.0\",\"method\":\"", method, "\",\"params\":", params, "}"));
}

fn uri_of(file: const u8[:]) -> u8[>..] {
    var u: u8[>..] = [];
    format(u, root_uri, "/", file);
    return u;
}

// Documents the server has, by path, with their version.
var opened = dictionary<u8[..1024], i64> {};

// Tells the server the file's current text: opened, or changed and saved,
// so rust-analyzer's own diagnostics and its cargo check both run.
// The languageId for a file: the server's, except that the TypeScript
// server also reads JavaScript and JSX, which it is told apart.
fn language_of(file: const u8[:]) -> const u8[:] {
    guard language_id == "typescript" else { return language_id; }
    if ends_with(file, ".tsx") { return "typescriptreact"; }
    if ends_with(file, ".jsx") { return "javascriptreact"; }
    if ends_with(file, ".js") || ends_with(file, ".mjs") || ends_with(file, ".cjs") { return "javascript"; }
    return "typescript";
}

fn sync_file(file: const u8[:]) -> bool {
    var text: u8[>..] = [];
    guard read_file(str(repo_dir, "/", file), text) else { return false; }
    var key: u8[..1024] = [];
    format(key, file);
    var params: u8[>..] = [];
    let uri = uri_of(file);
    let v = opened.get(key);
    if !v {
        opened.insert(key, 1);
        params.append("{\"textDocument\":{\"uri\":");
        json::format_string(params, uri);
        params.append(",\"languageId\":");
        json::format_string(params, language_of(file));
        params.append(",\"version\":1,\"text\":");
        json::format_string(params, text);
        params.append("}}");
        notify("textDocument/didOpen", params);
    } else {
        let version = v + 1;
        opened.insert(key, version);
        params.append("{\"textDocument\":{\"uri\":");
        json::format_string(params, uri);
        format(params, ",\"version\":", version, "},\"contentChanges\":[{\"text\":");
        json::format_string(params, text);
        params.append("}]}");
        notify("textDocument/didChange", params);
    }
    params.clear();
    params.append("{\"textDocument\":{\"uri\":");
    json::format_string(params, uri);
    params.append("}}");
    notify("textDocument/didSave", params);
    return true;
}

fn wait_indexed() {
    if indexing_done { return; }
    pump(180000) { m, method, id => indexing_done };
}

fn sev_word(n: i64) -> const u8[:] {
    return match n { 1 => "error", 2 => "warning", 3 => "info", _ => "hint" };
}

// Keeps a published set in our shape (1-based positions).
fn keep_diagnostics(p: json::Node?) {
    let u, u_ok = json::as_string(json::member(p, "uri"));
    guard u_ok && u.len < 1024;
    var key: u8[..1024] = [];
    format(key, u);
    let start = diag_text.len;
    diag_text.push('[');
    var n = 0;
    let ds = json::member(p, "diagnostics");
    if ds {
        json::each(ds) { d =>
            if n > 0 { diag_text.push(','); }
            n++;
            let r = json::member(d, "range");
            let sl, a1 = json::as_i64(json::member(json::member(r, "start"), "line"));
            let sc, a2 = json::as_i64(json::member(json::member(r, "start"), "character"));
            let el, a3 = json::as_i64(json::member(json::member(r, "end"), "line"));
            let ec, a4 = json::as_i64(json::member(json::member(r, "end"), "character"));
            let sv, s_ok = json::as_i64(json::member(d, "severity"));
            let msg, m_ok = json::as_string(json::member(d, "message"));
            let src, r_ok = json::as_string(json::member(d, "source"));
            var code: u8[>..] = [];
            let cn = json::member(d, "code");
            if cn {
                let cs, c_ok = json::as_string(cn);
                if c_ok { code.append(cs); } else { let ci, i_ok = json::as_i64(cn); if i_ok { format(code, ci); } }
            }
            format(diag_text, "{\"line\":", sl + 1, ",\"col\":", sc + 1, ",\"end_line\":", el + 1, ",\"end_col\":", ec + 1,
                   ",\"severity\":\"", sev_word(if s_ok { sv } else { 1 }), "\",\"source\":");
            json::format_string(diag_text, if r_ok { src } else { "" });
            diag_text.append(",\"code\":");
            json::format_string(diag_text, code);
            diag_text.append(",\"message\":");
            json::format_string(diag_text, if m_ok { msg } else { "" });
            diag_text.push('}');
            assert(a1 || a2 || a3 || a4 || true);
        };
    }
    diag_text.push(']');
    publishes++;
    diag_seq.insert(key, publishes);
    diag_at.insert(key, start);
    diag_len.insert(key, diag_text.len - start);
}

// The diagnostics for a file as it is on disk now. The file is synced and
// saved, and the answer comes once the server has had its say and been quiet
// for a moment: with after_check (rust-analyzer), when the cargo check the
// save started has finished, since it publishes only sets that changed;
// otherwise (pyright, typescript) when it has published for this file.
fn diagnostics(file: const u8[:], after_check: bool, out: u8[>..]&) {
    let before = checks_ended;
    let before_pub = publishes;
    let uri = uri_of(file);
    var key: u8[..1024] = [];
    format(key, uri);
    guard sync_file(file) else { out.append("{\"ok\":false,\"error\":\"cannot read the file\"}"); return; }
    if after_check { wait_indexed(); }     // servers that publish wait for nothing else
    // A first build import (Gradle fetching itself and the dependencies) can
    // take minutes; anything else gets two.
    var deadline = clock() + 120.0;
    var long_wait = false;
    var settled = false;
    loop {
        if importing && !long_wait { deadline = clock() + 900.0; long_wait = true; }
        let left = ((deadline - clock()) * 1000.0) as i64;
        if left <= 0 { break; }
        let seq = diag_seq.get(key);
        let done = !importing && (if after_check { checks_ended > before && checking == 0 } else { seq && seq > before_pub });
        // Once the check is over, 300 ms with no message means the last set is in.
        let more = pump(if done { 300 } else { min(left, 1000) }) { m, method, id => true };
        if done && !more { settled = true; break; }
    }
    let at = diag_at.get(key);
    out.append("{\"ok\":true,");
    if !settled { out.append("\"settled\":false,"); }
    if import_failed.len > 0 { out.append("\"import_failed\":"); json::format_string(out, import_failed); out.push(','); }
    out.append("\"diagnostics\":");
    let len = diag_len.get(key);
    if at && len { out.append(diag_text[at..at + len]); } else { out.append("[]"); }
    out.push('}');
}

// textDocument/implementation at a position.
fn implementations(file: const u8[:], line: i64, col: i64, out: u8[>..]&) {
    guard sync_file(file) else { out.append("{\"ok\":false,\"error\":\"cannot read the file\"}"); return; }
    wait_indexed();
    var params: u8[>..] = [];
    params.append("{\"textDocument\":{\"uri\":");
    json::format_string(params, uri_of(file));
    format(params, "},\"position\":{\"line\":", line - 1, ",\"character\":", col - 1, "}}");
    let id = request("textDocument/implementation", params);
    let want = str(id);
    var answer: u8[>..] = [];
    pump(120000) { m, method, idt =>
        let mine = method.len == 0 && idt == want;
        if mine {
            out.append("{\"ok\":true,\"locations\":[");
            let res = json::member(m, "result");
            var n = 0;
            if res {
                json::each(res) { loc =>
                    // Location {uri, range} or LocationLink {targetUri, targetSelectionRange}
                    var u, u_ok = json::as_string(json::member(loc, "uri"));
                    var r = json::member(loc, "range");
                    if !u_ok { u, u_ok = json::as_string(json::member(loc, "targetUri")); r .= json::member(loc, "targetSelectionRange"); }
                    let ln, l_ok = json::as_i64(json::member(json::member(r, "start"), "line"));
                    let cn, c_ok = json::as_i64(json::member(json::member(r, "start"), "character"));
                    if u_ok && l_ok && c_ok && starts_with(u, root_uri) {
                        if n > 0 { out.push(','); }
                        n++;
                        out.append("{\"file\":");
                        json::format_string(out, u[root_uri.len + 1..]);
                        format(out, ",\"line\":", ln + 1, ",\"col\":", cn + 1, "}");
                    }
                };
            }
            out.append("]}");
            answer.push(1);
        }
        mine
    };
    if answer.len == 0 { out.append("{\"ok\":false,\"error\":\"no answer from the server\"}"); }
}

var answer: u8[>..];

// Starts the server and the LSP session. argv is NUL-separated.
export "golsp_lib_start" fn start(repo: const u8[:], log: const u8[:], init_json: const u8[:], argv: const u8[:],
                               env_vars: const u8[:], lang_id: const u8[:]) -> bool {
    // A fresh session, also after a server died.
    repo_dir.clear(); root_uri.clear(); log_path.clear(); init_options.clear(); inbox.clear(); opened.clear();
    language_id.clear(); language_id.append(lang_id);
    gone = false; indexing_done = false; checking = 0; checks_ended = 0; importing = false; import_failed.clear();
    diag_text.clear(); diag_at.clear(); diag_len.clear(); diag_seq.clear(); publishes = 0;
    var tv: u8[>..] = [];
    trace = env("GOLSP_TRACE", tv) && tv == "1";
    format(repo_dir, repo);
    format(root_uri, "file://", repo);
    format(log_path, log);
    init_options.append(init_json);
    server = proc_open(argv, repo, env_vars, log);
    if server == 0 { return false; }
    var init: u8[>..] = [];
    init.append("{\"processId\":null,\"rootUri\":");
    json::format_string(init, root_uri);
    init.append(",\"initializationOptions\":");
    init.append(init_options);
    init.append(",\"capabilities\":{\"experimental\":{\"serverStatusNotification\":true},\"window\":{\"workDoneProgress\":true},\"workspace\":{\"configuration\":true},");
    init.append("\"textDocument\":{\"publishDiagnostics\":{},\"implementation\":{\"linkSupport\":false},");
    init.append("\"synchronization\":{\"didSave\":true}}},\"workspaceFolders\":[{\"uri\":");
    json::format_string(init, root_uri);
    init.append(",\"name\":\"repo\"}]}");
    let iid = request("initialize", init);
    let want = str(iid);
    let started = pump(120000) { m, method, idt => method.len == 0 && idt == want };
    if !started { note("no answer to initialize"); return false; }
    notify("initialized", "{}");
    note("initialized");
    return true;
}

// One question, one JSON answer, valid until the next call.
export "golsp_lib_ask" fn ask(question: const u8[:]) -> const u8[:] {
    answer.clear();
    if server == 0 || gone {
        answer.append("{\"ok\":false,\"gone\":true,\"error\":\"the language server is not running\"}");
        return answer;
    }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let q, perr = json::parse(question, doc, decoded);
    if !q {
        answer.append("{\"ok\":false,\"error\":");
        json::format_string(answer, perr);
        answer.push('}');
        return answer;
    }
    let op, o_ok = json::as_string(json::member(q, "op"));
    let file_in, f_ok = json::as_string(json::member(q, "file"));
    // A copy of its own, so syncing the file can't pull it out from under us.
    var file: u8[>..] = [];
    file.append(file_in);
    let settle, s_ok = json::as_string(json::member(q, "settle"));
    if o_ok && op == "diagnostics" && f_ok { diagnostics(file, s_ok && settle == "check", answer); }
    else if o_ok && op == "implementations" && f_ok {
        let ln, l_ok = json::as_i64(json::member(q, "line"));
        let cn, c_ok = json::as_i64(json::member(q, "col"));
        if l_ok && c_ok { implementations(file, ln, cn, answer); }
        else { answer.append("{\"ok\":false,\"error\":\"line and col are required\"}"); }
    } else {
        answer.append("{\"ok\":false,\"error\":\"unknown question\"}");
    }
    return answer;
}

export "golsp_lib_stop" fn stop() {
    guard server != 0;
    if gone { proc_close(server, 0); server = 0; return; }
    let sid = request("shutdown", "null");
    let swant = str(sid);
    pump(5000) { m, method, idt => method.len == 0 && idt == swant };
    notify("exit", "null");
    proc_close(server, 3000);
    server = 0;
}
