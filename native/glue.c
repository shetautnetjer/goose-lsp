/* The host program's door into the goose-lsp library (golsp.c, made by
   scripts/build.sh), which is Goose compiled on its own with --standalone so
   the host's build never recompiles it. The library has its own Goose
   runtime, started once here. Its exports are declared by hand rather than
   through golsp.h, whose types would clash with the host's goose.h; slices
   have the same layout either way. The host declares:
     extern fn golsp_start(repo, log, init_json, argv, env, lang_id: const u8[:]) -> bool;
     extern fn golsp_ask(question: const u8[:], out: u8[>..]&);
     extern fn golsp_stop(); */
#include "goose.h"
#include <stdbool.h>
#include <stdint.h>

typedef struct { const uint8_t *data; int64_t len; } lsp_slice;

void goose_init(int argc, char **argv);
uint8_t golsp_lib_start(lsp_slice repo, lsp_slice log, lsp_slice init_json, lsp_slice argv, lsp_slice env,
                      lsp_slice lang_id);
const uint8_t *golsp_lib_ask(lsp_slice question, int64_t *len);
void golsp_lib_stop(void);

static bool started;

bool golsp_start(lsp_slice repo, lsp_slice log, lsp_slice init_json, lsp_slice argv, lsp_slice env,
                    lsp_slice lang_id) {
    if (!started) { static char *args[] = {"goose-lsp", 0}; goose_init(1, args); started = true; }
    return golsp_lib_start(repo, log, init_json, argv, env, lang_id) != 0;
}

void golsp_ask(lsp_slice question, gs_rref out) {
    int64_t len = 0;
    const uint8_t *a = golsp_lib_ask(question, &len);
    gs_bld_append(out, a, (size_t)len);
}

void golsp_stop(void) { if (started) golsp_lib_stop(); }
