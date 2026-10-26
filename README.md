# goose-lsp

A language-server client for [Goose](https://aardappel.github.io/goose/)
programs: it keeps one language server running over stdio (rust-analyzer,
pyright, typescript-language-server, JetBrains' Kotlin server, or any LSP
server) and answers JSON questions about the code through it.

It is a Goose library compiled **on its own** to C with `goose --standalone`
and linked into your program through a small C glue, so it never adds to
your program's own Goose build. It has its own Goose runtime; only slices
cross between the two.

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
process groups. One server per process.

## License

MIT. Swan (https://github.com/shetautnetjer/Swan) is its first user.
