/* A program kept running with pipes to its stdin and stdout, for talking to
   it while it lives: goose-lsp to a language server. A process is an i64
   handle to a small struct; text crosses as Goose slices. It is linked into
   the host program but called by the goose-lsp library, whose runtime is separate,
   so it touches no Goose runtime state. */
#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct { const uint8_t *data; int64_t len; } proc_slice;

typedef struct { pid_t pid; int in_fd; int out_fd; } proc_t;

extern char **environ;

static char **nul_list(const char *buf, int64_t len, char **append) {
    int64_t n = 0, extra = 0;
    for (int64_t i = 0; i < len; i++) if (buf[i] == 0) n++;
    while (append && append[extra]) extra++;
    char **v = calloc((size_t)(n + extra + 1), sizeof *v);
    int64_t k = 0;
    for (int64_t i = 0, start = 0; i < len; i++)
        if (buf[i] == 0) { v[k++] = strdup(buf + start); start = i + 1; }
    for (int64_t i = 0; i < extra; i++) v[k++] = append[i];
    v[k] = NULL;
    return v;
}

/* Starts argv (NUL-separated; argv[0] a path or found on PATH) in cwd with env
   entries ("K=V\0") ahead of the inherited environment; stderr goes to
   log_path. Returns a handle, or 0. */
int64_t proc_open(proc_slice argv_nul, proc_slice cwd, proc_slice env_nul, proc_slice log_path) {
    char cwdbuf[4096], logbuf[4096];
    if (cwd.len >= (int64_t)sizeof cwdbuf || log_path.len >= (int64_t)sizeof logbuf) return 0;
    memcpy(cwdbuf, cwd.data, (size_t)cwd.len); cwdbuf[cwd.len] = 0;
    memcpy(logbuf, log_path.data, (size_t)log_path.len); logbuf[log_path.len] = 0;
    char **argv = nul_list((const char *)argv_nul.data, argv_nul.len, NULL);
    char **envp = nul_list((const char *)env_nul.data, env_nul.len, environ);
    int to_child[2], from_child[2];
    if (!argv[0] || pipe(to_child) != 0 || pipe(from_child) != 0) return 0;
    const char *path_env = NULL;
    for (char **e = envp; *e; e++) if (strncmp(*e, "PATH=", 5) == 0) { path_env = *e + 5; break; }
    pid_t pid = fork();
    if (pid == 0) {
        /* A group of its own, so closing it also ends what it started: the
           Kotlin server's launcher runs the JVM as a child. */
        setpgid(0, 0);
        dup2(to_child[0], 0); dup2(from_child[1], 1);
        int log = logbuf[0] ? open(logbuf, O_WRONLY | O_CREAT | O_APPEND, 0644) : -1;
        if (log >= 0) { dup2(log, 2); close(log); }
        close(to_child[0]); close(to_child[1]); close(from_child[0]); close(from_child[1]);
        if (cwdbuf[0] && chdir(cwdbuf) != 0) _exit(127);
        if (strchr(argv[0], '/')) execve(argv[0], argv, envp);
        else if (path_env) {
            char cand[4096];
            const char *p = path_env;
            while (*p) {
                const char *colon = strchr(p, ':');
                size_t dl = colon ? (size_t)(colon - p) : strlen(p);
                if (dl + strlen(argv[0]) + 2 < sizeof cand) {
                    memcpy(cand, p, dl); cand[dl] = '/'; strcpy(cand + dl + 1, argv[0]);
                    execve(cand, argv, envp);
                }
                if (!colon) break;
                p = colon + 1;
            }
        }
        _exit(127);
    }
    close(to_child[0]); close(from_child[1]);
    signal(SIGPIPE, SIG_IGN);
    if (pid < 0) return 0;
    proc_t *p = calloc(1, sizeof *p);
    p->pid = pid; p->in_fd = to_child[1]; p->out_fd = from_child[0];
    return (int64_t)(intptr_t)p;
}

/* Writes all of data to the program's stdin. False if it has gone. */
bool proc_write(int64_t h, proc_slice data) {
    proc_t *p = (proc_t *)(intptr_t)h;
    int64_t off = 0;
    while (off < data.len) {
        ssize_t n = write(p->in_fd, data.data + off, (size_t)(data.len - off));
        if (n < 0) { if (errno == EINTR) continue; return false; }
        off += n;
    }
    return true;
}

/* Reads what the program has written into buf, waiting up to timeout_ms for
   the first byte. Returns the bytes read, 0 on timeout, -1 once it has
   closed. */
int64_t proc_read(int64_t h, int64_t timeout_ms, proc_slice buf) {
    proc_t *p = (proc_t *)(intptr_t)h;
    struct pollfd fd = {p->out_fd, POLLIN, 0};
    int r;
    do { r = poll(&fd, 1, (int)timeout_ms); } while (r < 0 && errno == EINTR);
    if (r <= 0) return 0;
    ssize_t n = read(p->out_fd, (uint8_t *)buf.data, (size_t)buf.len);
    return n <= 0 ? -1 : n;
}

/* Closes stdin, gives it grace_ms to exit, then kills it and anything left
   in its process group. */
void proc_close(int64_t h, int64_t grace_ms) {
    proc_t *p = (proc_t *)(intptr_t)h;
    close(p->in_fd);
    int status;
    for (int64_t waited = 0; waited < grace_ms; waited += 20) {
        if (waitpid(p->pid, &status, WNOHANG) == p->pid) { kill(-p->pid, SIGKILL); close(p->out_fd); free(p); return; }
        struct timespec ts = {0, 20 * 1000000};
        nanosleep(&ts, NULL);
    }
    kill(-p->pid, SIGKILL);
    kill(p->pid, SIGKILL);
    waitpid(p->pid, &status, 0);
    close(p->out_fd);
    free(p);
}
