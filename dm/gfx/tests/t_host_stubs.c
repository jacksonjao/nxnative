// What the tests that link hle_nvn.c and hle_bigstack.c without the host need of it: weak definitions, so a test that defines its own keeps it
#include <stdint.h>
__attribute__((weak)) uint64_t g_t0_ns;   // process start time (host main.c), read by hle_nvn's per-frame timing
__attribute__((weak)) _Atomic uint64_t dm_present_ns;   // when the last present was made, for DM_HITCH_DUMP (hle_thread.c)
__attribute__((weak)) int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }   // no guest address space (hle_bigstack.c)
__attribute__((weak)) int front_screen_max_fps(void) { return 60; }   // ordinary test display; dedicated pacing tests override this
__attribute__((weak)) void dm_vi_layer_crop(int c[4]) { c[0] = c[1] = c[2] = c[3] = 0; }   // no vi layer crop (hle_vi.c), read by hle_nvn's present

__attribute__((weak)) void dm_cheats_present(void) {} // No guest cheat store in renderer-only tests.

// NVN-only test hosts do not provide GL interoperability.
#include "../nvn/nvn_tex.h"
__attribute__((weak)) void *gl_host_texture_2d(uint32_t name, nvn_texdesc *desc) { (void)name; (void)desc; return 0; }
__attribute__((weak)) void *gl_host_export_nvn_fence(uint64_t serial) { (void)serial; return 0; }
__attribute__((weak)) void *gl_host_export_gl_fence(uint64_t serial) { (void)serial; return 0; }
__attribute__((weak)) int gl_host_get_fence(void *handle, uint64_t *serial, int *from_nvn) { (void)handle; (void)serial; (void)from_nvn; return 0; }
__attribute__((weak)) int gl_host_wait_fence(uint64_t serial, uint64_t timeout_ns) { (void)serial; (void)timeout_ns; return 0; }
