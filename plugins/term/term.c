// term.c — Terminal plugin for the DS engine.
//
// Provides: term_clear, term_move, term_color, term_reset_color,
//           term_hide_cursor, term_show_cursor, term_raw, term_restore,
//           term_read_key, term_sleep, term_write, term_ticks
//
// Build: cc -shared -o build/libterm.dylib plugins/term/term.c
// Usage in .ds: loadlib("build/libterm.dylib")

#include "../../include/ds_plugin.h"
#include <termios.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static DsApi* api = NULL;

// ── Terminal state ──────────────────────────────────────────────

static struct termios g_original_termios;
static int g_raw_mode = 0;
static struct timespec g_start_time;

// ── Host functions ──────────────────────────────────────────────

static DsResult fn_term_clear(DsValue* args, int nargs) {
    printf("\x1b[2J\x1b[H");
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_move(DsValue* args, int nargs) {
    int row = (int)api->as_num(args[0]);
    int col = (int)api->as_num(args[1]);
    printf("\x1b[%d;%dH", row, col);
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_color(DsValue* args, int nargs) {
    int fg = (int)api->as_num(args[0]);
    printf("\x1b[38;5;%dm", fg);
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_reset_color(DsValue* args, int nargs) {
    printf("\x1b[0m");
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_hide_cursor(DsValue* args, int nargs) {
    printf("\x1b[?25l");
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_show_cursor(DsValue* args, int nargs) {
    printf("\x1b[?25h");
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_raw(DsValue* args, int nargs) {
    struct termios t;
    tcgetattr(STDIN_FILENO, &g_original_termios);
    t = g_original_termios;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN]  = 0;
    t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &t);
    g_raw_mode = 1;
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_restore(DsValue* args, int nargs) {
    if (g_raw_mode) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_original_termios);
        g_raw_mode = 0;
    }
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_read_key(DsValue* args, int nargs) {
    if (!g_raw_mode) return ds_ok(api->mk_nil());
    unsigned char c;
    long n = read(STDIN_FILENO, &c, 1);
    if (n <= 0) return ds_ok(api->mk_nil());
    if (c == 27) {
        unsigned char seq[2];
        long n2 = read(STDIN_FILENO, &seq[0], 1);
        if (n2 <= 0) return ds_ok(api->mk_num(27.0));
        if (seq[0] == '[') {
            long n3 = read(STDIN_FILENO, &seq[1], 1);
            if (n3 > 0) {
                switch (seq[1]) {
                    case 'A': return ds_ok(api->mk_num(256.0));
                    case 'B': return ds_ok(api->mk_num(258.0));
                    case 'C': return ds_ok(api->mk_num(257.0));
                    case 'D': return ds_ok(api->mk_num(259.0));
                }
            }
        }
        return ds_ok(api->mk_num(27.0));
    }
    return ds_ok(api->mk_num((double)c));
}

static DsResult fn_term_sleep(DsValue* args, int nargs) {
    unsigned int ms = (unsigned int)api->as_num(args[0]);
    usleep(ms * 1000);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_write(DsValue* args, int nargs) {
    for (int i = 0; i < nargs; i++) {
        const char* s = api->show(args[i]);
        if (s) fputs(s, stdout);
    }
    fflush(stdout);
    return ds_ok(api->mk_nil());
}

static DsResult fn_term_ticks(DsValue* args, int nargs) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed_ms = (now.tv_sec - g_start_time.tv_sec) * 1000 +
                      (now.tv_nsec - g_start_time.tv_nsec) / 1000000;
    return ds_ok(api->mk_num((double)elapsed_ms));
}

// ── Plugin entry point ──────────────────────────────────────────

void ds_init(DsApi* a) {
    api = a;
    clock_gettime(CLOCK_MONOTONIC, &g_start_time);

    api->register_fn("term_clear",       fn_term_clear);
    api->register_fn("term_move",        fn_term_move);
    api->register_fn("term_color",       fn_term_color);
    api->register_fn("term_reset_color", fn_term_reset_color);
    api->register_fn("term_hide_cursor", fn_term_hide_cursor);
    api->register_fn("term_show_cursor", fn_term_show_cursor);
    api->register_fn("term_raw",         fn_term_raw);
    api->register_fn("term_restore",     fn_term_restore);
    api->register_fn("term_read_key",    fn_term_read_key);
    api->register_fn("term_sleep",       fn_term_sleep);
    api->register_fn("term_write",       fn_term_write);
    api->register_fn("term_ticks",       fn_term_ticks);
}
