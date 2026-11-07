// Run the actual display callbacks with module/gate guards and native registers.
#include <assert.h>
#include "../hle_game_display.c"
#include "../hle_arceus_display.c"
static module_t modules[1];
module_t *g_mod = modules;
int g_nmod = 1;
static int have;
uint64_t guest_ns(void) { return 0; }
static void (*aspect_cb)(uint64_t *, int), (*hud_cb)(uint64_t *, int);
void gate_obs_set(int id, void (*fn)(uint64_t *, int)) {
    if (id == OBS_ARCEUS_ASPECT) aspect_cb = fn;
    else if (id == OBS_ARCEUS_HUD) hud_cb = fn;
    else assert(id == OBS_ARCEUS_TIMING || id == OBS_ARCEUS_TASK_TRACE);
}
int gate_obs_present(int id) { return have && (id == OBS_ARCEUS_ASPECT || id == OBS_ARCEUS_HUD); }
int main(int argc, char **argv) {
    const char *ratio = argc > 1 ? argv[1] : "76:35";
    double w, h; assert(sscanf(ratio, "%lf:%lf", &w, &h) == 2);
    module_t *m = modules;
    strcpy(m->name, "main"); strcpy(m->build_id, "aee8f150dda1b5a838806e1a5ea6827a");
    m->base = (uint8_t *)0x1000; m->size = 0x4354000;
    m->text_end = 0x32a5690; m->ro_off = 0x32a6000; m->data_off = 0x401a000;
    setenv("DM_FULLSCREEN", "1", 1); setenv("DM_ASPECT", ratio, 1);
    dm_arceus_display_init(); assert(!dm_game_fullscreen_active());
    have = 1; m->build_id[0] = '0'; dm_arceus_display_init(); assert(!dm_game_fullscreen_active());
    m->build_id[0] = 'a'; m->text_end--; dm_arceus_display_init(); assert(!dm_game_fullscreen_active()); m->text_end++;
    setenv("DM_ASPECT", "nan:1", 1); dm_arceus_display_init(); assert(!dm_game_fullscreen_active());
    setenv("DM_ASPECT", ratio, 1); dm_arceus_display_init(); assert(dm_game_fullscreen_active());
    for (int reg = 8; reg <= 9; reg++) {
        uint64_t regs[31]; for (int i = 0; i < 31; i++) regs[i] = 0x123400 + i;
        aspect_cb(regs, reg);
        float aspect; uint32_t bits = (uint32_t)regs[reg]; memcpy(&aspect, &bits, sizeof aspect);
        assert(fabs(aspect - w / h) < 1e-6 && regs[reg] == bits);
        for (int i = 0; i < 31; i++) if (i != reg) assert(regs[i] == (uint64_t)(0x123400 + i));
    }
    // A resource descriptor may replace the constructor's camera aspect.
    // Only its exact native-screen ratio is adapted; square/offscreen/custom
    // cameras and all unrelated GPRs must survive unchanged.
    const float supplied[] = {16.0f / 9.0f, 1.0f, 4.0f / 3.0f, 2.4f, NAN};
    for (unsigned n = 0; n < sizeof supplied / sizeof *supplied; n++) {
        uint64_t frame[31]; for (int i = 0; i < 31; i++) frame[i] = 0x567800 + i;
        uint32_t bits; memcpy(&bits, &supplied[n], sizeof bits); frame[10] = bits;
        aspect_cb(frame, 10);
        float corrected; bits = (uint32_t)frame[10]; memcpy(&corrected, &bits, sizeof corrected);
        if (n == 0) {
            assert(fabs(corrected - w / h) < 1e-6);
            // For a perspective projection, equal world lengths in X and Y
            // must occupy equal display lengths after the native framebuffer
            // is mapped to the device. This catches a stretched 16:9 camera.
            assert(fabs((w / h) / corrected - 1.0) < 1e-6);
        } else {
            // The untouched input includes NaN: compare the saved register bits.
            uint32_t actual, expected;
            memcpy(&actual, &corrected, sizeof actual);
            memcpy(&expected, &supplied[n], sizeof expected);
            assert(actual == expected);
        }
        for (int i = 0; i < 31; i++) if (i != 10) assert(frame[i] == (uint64_t)(0x567800 + i));
    }
    uint64_t regs[31]; for (int i = 0; i < 31; i++) regs[i] = 0x123400 + i;
    struct { uint32_t unused; float rect[4]; } native={0,{0,0,1920,1080}};
    regs[8]=(uintptr_t)&native;
    hud_cb(regs, 0);
    float rect[4]; memcpy(rect, (char *)(uintptr_t)regs[8] + 4, sizeof rect);
    assert(fabs((rect[2] / 1920) / (rect[3] / 1080) * w / h - 16.0 / 9) < 1e-6);
    assert(fabs(rect[0] - (1920 - rect[2]) * .5) < .001 && fabs(rect[1]-(1080-rect[3])*.5)<.001 && rect[2]<=1920 && rect[3]<=1080);
    for (int i = 0; i < 31; i++) if (i != 8) assert(regs[i] == (uint64_t)(0x123400 + i));
    printf("PASS: Arceus %s camera/HUD, module/gate guards and unrelated registers\n", ratio);
}
