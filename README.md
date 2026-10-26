# goose-lsp

A language-server client for [Goose](https://aardappel.github.io/goose/)
programs: it keeps one language server running over stdio (rust-analyzer,
pyright, typescript-language-server, JetBrains' Kotlin server, or another
compatible LSP server) and answers JSON questions about the code through it.
Server support depends on the server's protocol and project setup; this client is not a
replacement implementation of those servers.

It is a Goose library compiled **on its own** to C with `goose --standalone`
and linked into your program through small C glue. This keeps its Goose
compilation separate from the host's: the generated C still needs to be
compiled and linked, with reuse governed by the host's build cache. It has
its own Goose runtime; only slices cross between the two.

The protocol, document synchronization and answer conversion are Goose;
`native/proc.c` supplies POSIX process and pipe operations, and
`native/glue.c` bridges the two Goose runtimes. rust-analyzer, pyright,
typescript-language-server and JetBrains' Kotlin server are separate
executables installed and run by the consumer. They are not embedded,
compiled or downloaded by this repository.

This library can be used without Swan, SQLite or tree-sitter. Today its
integration is the standalone C workflow below, not an `import ... from`
Goose package. Making it a regular package while retaining the separate
compilation boundary would require a build/API decision; no registry or
new package manager is needed to use the current library.

## Use

```bash
GOOSE=/path/to/goose scripts/build.sh build      # -> build/golsp.c, build/golsp.h
```

In your program's sidecar (`yourprog.build`):

```goose
c_sources = ["path/to/goose-lsp/native/proc.c", "path/to/goose-lsp/native/glue.c", "build/golsp.c"];
```

In your program:

```goose
extern fn golsp_start(repo: const u8[:], log: const u8[:], init_json: const u8[:], argv: const u8[:],
                      env: const u8[:], lang_id: const u8[:]) -> bool;
extern fn golsp_ask(question: const u8[:], out: u8[>..]&);
extern fn golsp_stop();
```

`argv` and `env` are NUL-separated (each entry ends in a 0 byte). `init_json`
is sent as `initializationOptions` and answers `workspace/configuration` by
section. Questions:

```
{"op":"diagnostics","file":"src/lib.rs","settle":"check"}     // or "publish"
  -> {"ok":true,"diagnostics":[{"line":12,"col":5,"end_line":12,"end_col":9,
      "severity":"error","source":"rustc","code":"E0061","message":"..."}]}
{"op":"implementations","file":"src/lib.rs","line":12,"col":11}
  -> {"ok":true,"locations":[{"file":"src/lib.rs","line":23,"col":1}]}
```

Positions are 1-based. Each question re-reads its file from disk and syncs it
(didOpen, or didChange and didSave). `settle: "check"` waits for the check a
save starts (rust-analyzer's cargo check); `"publish"` waits for the file's
next published set (pyright, the TypeScript and Kotlin servers). A Kotlin
build import (Gradle) is waited for. A server that dies is reported as
`"gone":true`, never fatal. Servers run in their own process group and are
killed whole on stop. `GOLSP_TRACE=1` logs every message from the server.

Linux (and other POSIX) only, for now: native/proc.c uses fork, pipes and
process groups. One server per process, with global session state: serialize
calls and call `golsp_stop()` before starting a replacement server, including
after a failed start. The API is not a pool of independent client instances.

## Standalone validation and demo

With an installed Goose compiler, C compiler and Python 3, run from this
checkout:

```bash
GOOSE=/path/to/goose scripts/test.sh
```

This builds `tests/client.goose` against the public C/glue interface and
launches `tests/mock_server.py` over stdio. The mock is a deterministic
protocol fixture, not a compiler or real language server; it needs no network
or server installation. `tests/client.build` is also a minimal consumer
sidecar that can be adapted for another program. Build products, a private
Goose cache and per-run evidence remain under `build/tests/` (ignored by Git);
set `GOOSE_HOME` to reuse an existing cache and `PYTHON` to choose Python.

The runner checks both returned JSON and the messages the server actually
received: fragmented framing, initialize/options, a server configuration
request, open/change/save and versioning, diagnostic clearing, 1-based
position conversion, Location and LocationLink results, invalid requests,
shutdown/exit, process-group cleanup, server EOF and a missing executable.
It keeps logs and fixture files for inspection and returns nonzero on failed
assertions or a timeout. These checks do not qualify real server semantics,
Kotlin/Gradle import behavior, Unicode position conventions, or performance.

## License

MIT. Swan (https://github.com/shetautnetjer/Swan) is its first user.
