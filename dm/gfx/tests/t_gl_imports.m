// Direct GL imports and eglGetProcAddress must reach the same implementations (issue #228), including big-stack entries.
#include "../gl/hle_gl.m"
#include <assert.h>

uint64_t resolve_import(module_t *m, const char *name);
int hle_implements(const char *name);
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
struct dm_flags g_flag;
void svc_thread_dump(void) {}
void dm_vi_layer_size(int *w, int *h) { *w = *h = 0; }
void dm_vi_layer_crop(int c[4]) { memset(c, 0, 4 * sizeof *c); }
int dm_opmode(void) { return 1; }
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
uint64_t guest_ns(void) { return 0; }
uint64_t guest_ticks(void) { return 0; }
void guest_clock_read_wait(void) {}
void thr_svc_enter(uint64_t *r, uint64_t a) { (void)r; (void)a; }
void thr_svc_leave(void) {}
void dm_spin_wait(uint64_t r, uint64_t a) { (void)r; (void)a; }
uint64_t svc_dispatch(int n, uint64_t *r, uint64_t a) { (void)n; (void)r; (void)a; return 0; }
uint64_t unimpl_stubs[4096];
static const char *wrap_kind;
void *hlecount_wrap(const char *kind, const char *name, void *fn) { (void)name; wrap_kind = kind; return fn; }

static void *import(const char *name) {
    assert(hle_implements(name));
    void *fn = (void *)resolve_import(NULL, name);
    assert(!strcmp(wrap_kind, "HLE"));
    return fn;
}
static void *unbound_thread(void *unused) {
    (void)unused;
    assert(!h_eglGetCurrentDisplay() && !h_eglGetCurrentContext());
    assert(!h_eglGetCurrentSurface(0x3059) && !h_eglGetCurrentSurface(0x305a));
    assert(h_eglGetError() == 0x3000);
    return NULL;
}

int main(int argc, char **argv) {
    (void)argv;
    int stubs = argc > 1;
    setenv("DM_GL_STUBS", stubs ? "1" : "0", 1);
    // The calls from the issue must bind without using a GL loader first.
    GLuint (*create)(GLenum) = import("glCreateShader");
    assert((void *)create == (void *)h_glCreateShader);
    GLuint sh = create(GL_VERTEX_SHADER); assert(sh);
    void (*source)(GLuint, GLsizei, const GLchar *const *, const GLint *) = import("glShaderSource");
    const GLchar *text = "void main() {}";
    source(sh, 1, &text, NULL);
    void (*getiv)(GLuint, GLenum, GLint *) = import("glGetShaderiv");
    GLint value = 0; getiv(sh, GL_SHADER_TYPE, &value); assert(value == GL_VERTEX_SHADER);
    getiv(sh, GL_SHADER_SOURCE_LENGTH, &value); assert(value == strlen(text) + 1);
    // The import and loader paths must both keep the wrapper, rather than exposing the Metal implementation's small-stack entry.
    assert(import("glCompileShader") == (void *)h_glCompileShader_bs);
    assert(import("glClear") == (void *)h_glClear_bs);
    void (*clearcolor)(GLfloat, GLfloat, GLfloat, GLfloat) = import("glClearColor");
    clearcolor(0.25f, 0.5f, 0.75f, 1); assert(S.clear_c[0] == 0.25f && S.clear_c[3] == 1);
    void (*info)(GLuint, GLsizei, GLsizei *, GLchar *) = import("glGetShaderInfoLog");
    GLsizei len = -1; GLchar log[2] = {'?', 0}; info(sh, sizeof log, &len, log); assert(!len && !log[0]);
    void (*delete)(GLuint) = import("glDeleteShader"); delete(sh); assert(!shader_of(sh));

    unsigned long sz;
    const hle_ent *sec = (const hle_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swhle", &sz);
    unsigned count = 0;
    for (unsigned long i = 0; i < sz / sizeof *sec; i++)
        if (!strncmp(sec[i].name, "gl", 2) || !strncmp(sec[i].name, "egl", 3)) {
            assert(import(sec[i].name) == sec[i].fn);
            assert(h_eglGetProcAddress(sec[i].name) == sec[i].fn); count++;
        }
    assert(count > 100);
    assert((void *)resolve_import(NULL, "eglGetProcAddress") == (void *)h_eglGetProcAddress_bs);
    assert(!h_eglGetProcAddress(NULL));
    assert(!h_eglGetProcAddress("not_a_GL_function"));
    assert(!h_eglGetProcAddress("eglMissingFunctionForTest"));
    assert(import("eglGetCurrentDisplay") == (void *)h_eglGetCurrentDisplay_bs);
    assert(!h_eglGetCurrentDisplay() && !h_eglGetCurrentContext());
    EGLDisplay d = (EGLDisplay)(uintptr_t)1; EGLContext c = (EGLContext)(uintptr_t)2;
    EGLSurface draw = (EGLSurface)(uintptr_t)3, read = (EGLSurface)(uintptr_t)4;
    assert(h_eglMakeCurrent(d, draw, read, c));
    assert(h_eglGetCurrentDisplay() == d && h_eglGetCurrentContext() == c);
    assert(h_eglGetCurrentSurface(0x3059) == draw && h_eglGetCurrentSurface(0x305a) == read);
    assert(!h_eglGetCurrentSurface(0) && h_eglGetError() == 0x300c && h_eglGetError() == 0x3000);
    pthread_t thread; assert(!pthread_create(&thread, NULL, unbound_thread, NULL)); assert(!pthread_join(thread, NULL));
    assert(h_eglGetCurrentDisplay() == d);
    assert(h_eglMakeCurrent(d, NULL, NULL, NULL) && !h_eglGetCurrentDisplay());
    assert(h_eglMakeCurrent(d, draw, read, c) && h_eglReleaseThread());
    assert(!h_eglGetCurrentDisplay() && !h_eglGetCurrentContext() && !h_eglGetCurrentSurface(0x3059));
    // A foreign pointer (e.g. a game-owned NVNsync) and a stale GL handle
    // must be rejected without passing either to the host allocator.
    uintptr_t foreign = 0;
    h_glDeleteSync(&foreign); assert(h_glGetError() == 0x501);
    h_glDeleteSync(NULL); assert(h_glGetError() == 0);
    void *sync = h_glFenceSync(0x9117, 0);
    uint64_t serial;
    assert(gl_sync_serial(sync, &serial) && serial == g_serial);
    h_glDeleteSync(sync); assert(h_glGetError() == 0);
    void *next_sync = h_glFenceSync(0x9117, 0); assert(next_sync != sync);
    assert(h_glClientWaitSync(sync, 0, 0) == 0x911d && h_glGetError() == 0x501);
    h_glWaitSync(&foreign, 0, UINT64_MAX); assert(h_glGetError() == 0x501);
    h_glDeleteSync(next_sync); assert(h_glGetError() == 0);
    const char *missing = "glMissingFunctionForTest";
    assert(!hle_implements(missing));
    assert((h_eglGetProcAddress(missing) != NULL) == stubs);
    assert(resolve_import(NULL, missing) == (uint64_t)&unimpl_stubs[0]);
    assert(!strcmp(wrap_kind, "STUB"));
    printf("GL imports: %u shared entries, shader handle/source, wrappers and missing names (DM_GL_STUBS=%d): OK\n", count, stubs);
    return 0;
}
