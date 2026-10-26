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
#include <pthread.h>

typedef struct { const uint8_t *data; int64_t len; } proc_slice;

/* Unread output kept for the host at most, and how long a write may wait
   for a server that has stopped reading its input. */
#define PROC_MAX_PENDING ((int64_t)256 << 20)
#define PROC_WRITE_WAIT_MS 60000

/* What the program writes is read as it comes by a thread of our own into
   a buffer that grows, so a talkative server (progress notifications while
   it indexes) never blocks on a full pipe while nobody is asking it
   anything. proc_read takes from that buffer. */
typedef struct {
    pid_t pid; int in_fd; int out_fd;
    pthread_t reader; pthread_mutex_t mu; pthread_cond_t cv;
    uint8_t *buf; int64_t len, cap; bool closed, stop;
} proc_t;

static void *reader_main(void *arg) {
    proc_t *p = arg;
    uint8_t chunk[65536];
    for (;;) {
        /* Polls, so that closing can stop it even when a process outside the
           group (a build daemon the server started) still holds the pipe. */
        struct pollfd fd = {p->out_fd, POLLIN, 0};
        int r = poll(&fd, 1, 200);
        pthread_mutex_lock(&p->mu);
        bool stop = p->stop;
        pthread_mutex_unlock(&p->mu);
        if (stop) return NULL;
        if (r == 0 || (r < 0 && errno == EINTR)) continue;
        ssize_t n = read(p->out_fd, chunk, sizeof chunk);
        if (n < 0 && errno == EINTR) continue;
        pthread_mutex_lock(&p->mu);
        if (n <= 0) { p->closed = true; pthread_cond_broadcast(&p->cv); pthread_mutex_unlock(&p->mu); return NULL; }
        if (p->len + n > p->cap) {
            /* A server that writes this much with nobody reading is not
               going to be caught up with: the session ends as if it had
               closed, rather than the host running out of memory. */
            int64_t cap = p->cap ? p->cap : 65536;
            while (cap < p->len + n) cap *= 2;
            uint8_t *grown = cap <= PROC_MAX_PENDING ? realloc(p->buf, (size_t)cap) : NULL;
            if (!grown) { p->closed = true; pthread_cond_broadcast(&p->cv); pthread_mutex_unlock(&p->mu); return NULL; }
            p->buf = grown;
            p->cap = cap;
        }
        memcpy(p->buf + p->len, chunk, (size_t)n);
        p->len += n;
        pthread_cond_broadcast(&p->cv);
        pthread_mutex_unlock(&p->mu);
    }
}

extern char **environ;

/* The NUL-separated strings in buf (copied; *own of them), then append's. */
static char **nul_list(const char *buf, int64_t len, char **append, int64_t *own) {
    int64_t n = 0, extra = 0;
    for (int64_t i = 0; i < len; i++) if (buf[i] == 0) n++;
    while (append && append[extra]) extra++;
    char **v = calloc((size_t)(n + extra + 1), sizeof *v);
    int64_t k = 0;
    for (int64_t i = 0, start = 0; i < len; i++)
        if (buf[i] == 0) { v[k++] = strdup(buf + start); start = i + 1; }
    *own = k;
    for (int64_t i = 0; i < extra; i++) v[k++] = append[i];
    v[k] = NULL;
    return v;
}

static void free_list(char **v, int64_t own) {
    for (int64_t i = 0; i < own; i++) free(v[i]);
    free(v);
}

/* Starts argv (NUL-separated; argv[0] a path or found on PATH) in cwd with env
   entries ("K=V\0") ahead of the inherited environment; stderr goes to
   log_path. Returns a handle, or 0. */
int64_t proc_open(proc_slice argv_nul, proc_slice cwd, proc_slice env_nul, proc_slice log_path) {
    char cwdbuf[4096], logbuf[4096];
    if (cwd.len >= (int64_t)sizeof cwdbuf || log_path.len >= (int64_t)sizeof logbuf) return 0;
    memcpy(cwdbuf, cwd.data, (size_t)cwd.len); cwdbuf[cwd.len] = 0;
    memcpy(logbuf, log_path.data, (size_t)log_path.len); logbuf[log_path.len] = 0;
    int64_t argv_own, envp_own;
    char **argv = nul_list((const char *)argv_nul.data, argv_nul.len, NULL, &argv_own);
    char **envp = nul_list((const char *)env_nul.data, env_nul.len, environ, &envp_own);
    int to_child[2] = {-1, -1}, from_child[2] = {-1, -1};
    if (!argv[0] || pipe(to_child) != 0 || pipe(from_child) != 0) {
        for (int i = 0; i < 2; i++) { if (to_child[i] >= 0) close(to_child[i]); if (from_child[i] >= 0) close(from_child[i]); }
        free_list(argv, argv_own); free_list(envp, envp_own);
        return 0;
    }
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
    free_list(argv, argv_own); free_list(envp, envp_own);
    signal(SIGPIPE, SIG_IGN);
    if (pid < 0) { close(to_child[1]); close(from_child[0]); return 0; }
    /* Writes wait with a deadline (proc_write), not forever. */
    fcntl(to_child[1], F_SETFL, fcntl(to_child[1], F_GETFL) | O_NONBLOCK);
    proc_t *p = calloc(1, sizeof *p);
    p->pid = pid; p->in_fd = to_child[1]; p->out_fd = from_child[0];
    pthread_mutex_init(&p->mu, NULL);
    pthread_cond_init(&p->cv, NULL);
    pthread_create(&p->reader, NULL, reader_main, p);
    return (int64_t)(intptr_t)p;
}

/* Writes all of data to the program's stdin. False if it has gone, or has
   taken nothing for PROC_WRITE_WAIT_MS (a hung server must not hang the host). */
bool proc_write(int64_t h, proc_slice data) {
    proc_t *p = (proc_t *)(intptr_t)h;
    int64_t off = 0;
    while (off < data.len) {
        ssize_t n = write(p->in_fd, data.data + off, (size_t)(data.len - off));
        if (n >= 0) { off += n; continue; }
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return false;
        struct pollfd fd = {p->in_fd, POLLOUT, 0};
        int r;
        do r = poll(&fd, 1, PROC_WRITE_WAIT_MS); while (r < 0 && errno == EINTR);
        if (r <= 0 || (fd.revents & (POLLERR | POLLHUP))) return false;
    }
    return true;
}

/* Moves what the program has written into buf, waiting up to timeout_ms
   for the first byte. Returns the bytes moved, 0 on timeout, -1 once it has
   closed and everything has been read. */
int64_t proc_read(int64_t h, int64_t timeout_ms, proc_slice buf) {
    proc_t *p = (proc_t *)(intptr_t)h;
    pthread_mutex_lock(&p->mu);
    if (p->len == 0 && !p->closed && timeout_ms > 0) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += timeout_ms / 1000;
        until.tv_nsec += (timeout_ms % 1000) * 1000000;
        if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
        while (p->len == 0 && !p->closed)
            if (pthread_cond_timedwait(&p->cv, &p->mu, &until) != 0) break;
    }
    int64_t n = p->len < buf.len ? p->len : buf.len;
    if (n > 0) {
        memcpy((uint8_t *)buf.data, p->buf, (size_t)n);
        memmove(p->buf, p->buf + n, (size_t)(p->len - n));
        p->len -= n;
    }
    bool done = n == 0 && p->closed;
    pthread_mutex_unlock(&p->mu);
    return done ? -1 : n;
}

/* Closes stdin, gives it grace_ms to exit, then kills it and anything left
   in its process group. */
void proc_close(int64_t h, int64_t grace_ms) {
    proc_t *p = (proc_t *)(intptr_t)h;
    close(p->in_fd);
    int status;
    for (int64_t waited = 0; waited < grace_ms; waited += 20) {
        if (waitpid(p->pid, &status, WNOHANG) == p->pid) { kill(-p->pid, SIGKILL); goto done; }
        struct timespec ts = {0, 20 * 1000000};
        nanosleep(&ts, NULL);
    }
    kill(-p->pid, SIGKILL);
    kill(p->pid, SIGKILL);
    waitpid(p->pid, &status, 0);
done:
    pthread_mutex_lock(&p->mu);
    p->stop = true;
    pthread_mutex_unlock(&p->mu);
    pthread_join(p->reader, NULL);
    close(p->out_fd);
    free(p->buf);
    pthread_mutex_destroy(&p->mu);
    pthread_cond_destroy(&p->cv);
    free(p);
}
