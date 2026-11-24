/* FriCAS front end for pdfcc.
 *
 * The PDF embeds ECL (linked as libraries), fricas.tar (FriCAS: Lisp sources
 * for the parts loaded from source, bytecode (.fasc) for the rest, databases,
 * frontend.lisp, toplevel.lisp) and fricas.mem, a memory image of this program
 * taken after startup by tools/snapshot.mjs.
 *
 * main() unpacks fricas.tar to /fricas. With fricas.mem, it then copies the
 * image over the program's memory, and FriCAS is ready. Without it, each
 * pdf_run() frame does one startup step, so the viewer repaints in between:
 * cl_boot() and load frontend.lisp, then (pdf-boot-step) until it returns NIL.
 * Once ready, each typed line goes to (pdf-line "...").
 *
 * C functions run as JavaScript functions, so deep recursion can overflow V8's
 * stack before the C stack (pdfcc README). pdfcc then calls on_overflow(), which
 * restores ECL's dynamic state to what it was before the call, as ecl_unwind()
 * would, and lets FriCAS return to its top level. */
#include <ecl/ecl.h>
#include <ecl/gc/gc.h>
#include <emscripten.h>
#include <emscripten/stack.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include "pdfcc.h"

extern void init_unixtime(void); /* ECL internal (src/c/time.d): origin of GET-INTERNAL-REAL-TIME */

#define ARCHIVE "/fricas.tar"
#define ROOT "/fricas"

static enum { BOOT_ECL, BOOT_FRICAS, READY, FAILED } state = BOOT_ECL;
/* Lisp objects referenced only from C statics are not GC roots here: keep symbols */
static cl_object err_value, boot_symbol, line_symbol, abort_symbol, overflow_symbol;

/* ------------------------------------------------------------------ tar -- */

static unsigned long octal(const char *s, int n) {
    unsigned long v = 0;
    for (int i = 0; i < n && s[i] >= '0' && s[i] <= '7'; i++) v = v * 8 + (unsigned long)(s[i] - '0');
    return v;
}

static void make_dirs(char *path) { /* mkdir -p for the directories in path */
    for (char *p = path + 1; *p; p++)
        if (*p == '/') {
            *p = 0;
            if (mkdir(path, 0755) != 0 && errno != EEXIST) perror(path);
            *p = '/';
        }
}

/* Extracts the regular files of a ustar archive below root. Returns the count,
 * -1 on error (reported). */
static int untar(const char *archive, const char *root) {
    FILE *in = fopen(archive, "rb");
    if (!in) return -1;
    static char hdr[512], buf[1 << 16], path[512];
    int count = 0, ok = 1;
    while (ok && fread(hdr, 1, 512, in) == 512 && hdr[0]) {
        unsigned long size = octal(hdr + 124, 12);
        char type = hdr[156];
        if (hdr[345]) /* ustar prefix */
            (void)snprintf(path, sizeof path, "%s/%.155s/%.100s", root, hdr + 345, hdr);
        else
            (void)snprintf(path, sizeof path, "%s/%.100s", root, hdr);
        FILE *out = NULL;
        if (type == '0' || type == 0) {
            make_dirs(path);
            out = fopen(path, "wb");
            if (!out) { perror(path); ok = 0; break; }
            count++;
        }
        for (unsigned long left = (size + 511) / 512 * 512; ok && left;) {
            size_t n = fread(buf, 1, left < sizeof buf ? left : sizeof buf, in);
            size_t data = n < size ? n : size;
            if (!n) { (void)fprintf(stderr, "%s: truncated archive\n", archive); ok = 0; }
            else if (out && fwrite(buf, 1, data, out) != data) { perror(path); ok = 0; }
            size -= data;
            left -= n;
        }
        if (out && fclose(out) != 0) { perror(path); ok = 0; }
    }
    (void)fclose(in);
    return ok ? count : -1;
}

/* ------------------------------------------------------------- snapshot -- */
/* /fricas.mem: "FMEM", u32 header length, JSON header, data. The header has the
 * memory size, the C stack range (not saved), the chunks of memory that are not
 * all zero ([address, length]; their bytes are the data), and the files FriCAS
 * keeps open. */

/* True when tools/snapshot.mjs runs the PDF. */
EM_JS(int, snapshot_wanted, (void), { return typeof fricasSnapshot === "function"; })

EM_JS(void, snapshot_save, (unsigned size, unsigned stack_lo, unsigned stack_hi), {
    var files = [];
    FS.streams.forEach(function (s, fd) {
        if (s && fd > 2) files.push({ fd: fd, path: s.path, flags: s.flags, position: s.position });
    });
    fricasSnapshot(HEAPU8.subarray(0, size >>> 0),
                   { size: size >>> 0, stack: [stack_lo >>> 0, stack_hi >>> 0], files: files });
})

/* Tells tools/snapshot.mjs that startup failed. */
EM_JS(void, snapshot_fail, (const char *what), {
    if (typeof fricasSnapshot === "function") fricasSnapshot(null, { error: UTF8ToString(what) });
})

/* Reads and checks /fricas.mem: returns the memory size it needs, 0 if it is absent,
 * damaged, from another build, or names a file that does not exist. */
EM_JS(unsigned, snapshot_open, (unsigned stack_lo, unsigned stack_hi), {
    try {
        var f = FS.readFile("/fricas.mem");
        FS.unlink("/fricas.mem");
        if (String.fromCharCode(f[0], f[1], f[2], f[3]) !== "FMEM") return 0;
        var n = (f[4] | f[5] << 8 | f[6] << 16 | f[7] << 24) >>> 0, json = "";
        for (var i = 0; i < n; i++) json += String.fromCharCode(f[8 + i]);
        var h = JSON.parse(json), data = f.subarray(8 + n), total = 0;
        if (h.stack[0] !== stack_lo >>> 0 || h.stack[1] !== stack_hi >>> 0) return 0;
        h.chunks.forEach(function (c) {
            if (c[0] < h.stack[1] && c[0] + c[1] > h.stack[0] || c[0] + c[1] > h.size) throw "chunk";
            total += c[1];
        });
        if (total !== data.length) return 0;
        h.files.forEach(function (o) { FS.stat(o.path); }); /* throws if missing */
        Module.fricasImage = { h: h, data: data };
        return h.size;
    } catch (e) {
        return 0;
    }
})

/* Copies the image checked by snapshot_open over memory, except the C stack, which
 * is in use; zeroes [image size, brk). Reopens the files at the same descriptors
 * and positions. */
EM_JS(void, snapshot_load, (unsigned brk), {
    var h = Module.fricasImage.h, data = Module.fricasImage.data, at = 0;
    Module.fricasImage = null;
    HEAPU8.fill(0, 0, h.stack[0]);
    HEAPU8.fill(0, h.stack[1], Math.max(h.size, brk >>> 0));
    h.chunks.forEach(function (c) {
        HEAPU8.set(data.subarray(at, at + c[1]), c[0]);
        at += c[1];
    });
    h.files.forEach(function (o) {
        var s = FS.open(o.path, o.flags & ~(64 | 128 | 512)); /* not O_CREAT, O_EXCL, O_TRUNC */
        if (s.fd !== o.fd) { FS.streams[s.fd] = null; s.fd = o.fd; FS.streams[o.fd] = s; }
        s.position = o.position;
    });
})

static uintptr_t heap_end(void) {
    void *brk = sbrk(0);
    return (uintptr_t)brk;
}

/* Replaces this program's memory with the image. Returns 0 if there is none. */
static int restore(void) {
    uintptr_t lo = emscripten_stack_get_end(), hi = emscripten_stack_get_base();
    uintptr_t size = snapshot_open(lo, hi);
    if (!size) return 0;
    uintptr_t brk = heap_end();
    if (size > brk && sbrk((intptr_t)(size - brk)) == (void *)-1) return 0;
    snapshot_load(brk); /* from here on, static and heap data are the image's */
    init_unixtime();    /* the image's time origin is from another run */
    return 1;
}

static void fail(const char *what) {
    printf("\n%s\n", what);
    state = FAILED;
    pdf_stop();
    snapshot_fail(what);
}

/* ------------------------------------------------------------------ ECL -- */

/* ECL state saved before each call into Lisp, restored after a stack overflow */
static struct {
    __typeof__(((cl_env_ptr)0)->frs_stack.top) frs;
    __typeof__(((cl_env_ptr)0)->ihs_stack.top) ihs;
    cl_index bds, run;
    cl_object stack_frame;
} saved;

static cl_object eval(cl_object form) {
    cl_env_ptr env = ecl_process_env();
    saved.frs = env->frs_stack.top;
    saved.ihs = env->ihs_stack.top;
    saved.bds = (cl_index)(env->bds_stack.top - env->bds_stack.org);
    saved.run = ECL_STACK_INDEX(env);
    saved.stack_frame = env->stack_frame;
    cl_object r = si_safe_eval(3, form, ECL_NIL, err_value);
    (void)fflush(stdout);
    return r;
}

static cl_object eval_string(const char *s) { return eval(c_string_to_object(s)); }

static void on_overflow(void) {
    if (state != READY) { /* saved may be unset, or ECL not booted */
        fail("Stack overflow during startup.");
        return;
    }
    cl_env_ptr env = ecl_process_env();
    env->ihs_stack.top = saved.ihs;
    ecl_bds_unwind(env, saved.bds);
    ECL_STACK_UNWIND(env, saved.run);
    env->frs_stack.top = saved.frs;
    env->stack_frame = saved.stack_frame;
    env->nvalues = 0;
    env->disable_interrupts = 0;
    eval(cl_list(1, overflow_symbol));
}

static void started(void) { /* pdf_now(): since the viewer started the PDF's JavaScript */
    printf("Started in %.1f s.\n", pdf_now() / 1000);
    state = READY;
}

static void frame(void) {
    char line[8192];
    int n;
    switch (state) {
    case BOOT_ECL: {
        char *argv[] = {"fricas", NULL};
        /* stack kept free to run ECL's own stack-overflow handler */
        ecl_set_option(ECL_OPT_C_STACK_SAFETY_AREA, 64 << 10);
        cl_boot(1, argv);
        err_value = ecl_make_keyword("PDF-ERROR");
        if (eval_string("(load \"frontend.lisp\" :verbose nil)") == err_value) {
            fail("Cannot load frontend.lisp.");
            return;
        }
        boot_symbol = c_string_to_object("pdf-boot-step");
        line_symbol = c_string_to_object("pdf-line");
        abort_symbol = c_string_to_object("pdf-abort");
        overflow_symbol = c_string_to_object("pdf-overflow");
        state = BOOT_FRICAS;
        break;
    }
    case BOOT_FRICAS: {
        cl_object r = eval(cl_list(1, boot_symbol));
        if (r != ECL_T && r != ECL_NIL) {
            fail("FriCAS failed to start.");
        } else if (r == ECL_NIL) {
            started();
            if (eval_string("(boot::pdf-start)") == err_value) {
                fail("FriCAS failed to start.");
            } else if (snapshot_wanted()) {
                eval_string("(boot::pdf-warm-up)");
                eval_string("(si:gc t)");
                printf("GC heap %lu bytes, %lu free\n", (unsigned long)GC_get_heap_size(),
                       (unsigned long)GC_get_free_bytes());
                pdf_stop();
                snapshot_save(heap_end(), emscripten_stack_get_end(), emscripten_stack_get_base());
            }
        }
        break;
    }
    case READY:
        while (state == READY && (n = pdf_read_line(line, sizeof line)) >= 0)
            if (eval(cl_list(2, line_symbol, ecl_make_simple_base_string(line, n))) == err_value)
                eval(cl_list(1, abort_symbol));
        break;
    case FAILED:
        break;
    }
}

int main(void) {
    if (untar(ARCHIVE, ROOT) < 0) { fail("Cannot unpack " ARCHIVE "."); return 1; }
    unlink(ARCHIVE);
    if (chdir(ROOT) != 0) { fail("Cannot enter " ROOT "."); return 1; }
    if (restore()) { /* state is READY, as when the image was taken */
        eval_string("(boot::|spadStartUpMsgs|)");
        started();
        eval_string("(boot::pdf-restart)");
    } else {
        printf("Starting ECL...\n");
    }
    pdf_on_stack_overflow(on_overflow);
    pdf_run(frame, 1);
    return 0;
}
