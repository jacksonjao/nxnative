// Exercise real callbacks against entry.S's complete saved frame, not a GPU.
#include <assert.h>
#include "../hle_game_display.c"
#include "../hle_violet_display.c"
static module_t modules[1];
module_t *g_mod = modules;
int g_nmod = 1;
static int have;
static void (*camera_cb)(uint64_t *, int), (*hud_cb)(uint64_t *, int);
void gate_obs_set(int id, void (*fn)(uint64_t *, int)) {
    if (id == OBS_VIOLET_CAMERA) camera_cb = fn;
    else { assert(id == OBS_VIOLET_HUD); hud_cb = fn; }
}
int gate_obs_present(int id) { return have && (id == OBS_VIOLET_CAMERA || id == OBS_VIOLET_HUD); }
int main(int argc, char **argv) {
    const char *ratio = argc > 1 ? argv[1] : "76:35";
    double w, h; assert(sscanf(ratio, "%lf:%lf", &w, &h) == 2);
    module_t *m = modules;
    strcpy(m->name, "main"); strcpy(m->build_id, "709bfd66115298640155fcc4979dba15");
    m->base = (uint8_t *)0x1000; m->size = 0x47d3000;
    m->text_end = 0x343fc90; m->ro_off = 0x3440000; m->data_off = 0x4383000;
    setenv("DM_FULLSCREEN", "1", 1); setenv("DM_ASPECT", ratio, 1);
    dm_violet_display_init(); assert(!dm_game_fullscreen_active());
    have = 1; m->build_id[0] = '0'; dm_violet_display_init(); assert(!dm_game_fullscreen_active());
    m->build_id[0] = '7'; m->data_off--; dm_violet_display_init(); assert(!dm_game_fullscreen_active()); m->data_off++;
    setenv("DM_ASPECT", "nan:1", 1); dm_violet_display_init(); assert(!dm_game_fullscreen_active());
    setenv("DM_ASPECT", ratio, 1); dm_violet_display_init(); assert(dm_game_fullscreen_active());
    uint64_t frame[100], before[100]; memset(frame, 0x5a, sizeof frame);
    const size_t lane = 256 + 16 * 16;
    float original = 4.0f; memcpy((uint8_t *)frame + lane, &original, sizeof original);
    memcpy(before, frame, sizeof frame); camera_cb(frame, 0);
    float scaled; memcpy(&scaled, (uint8_t *)frame + lane, sizeof scaled);
    assert(fabs(scaled - original * (w / h) / (16.0 / 9)) < 3e-6);
    const size_t frame_bytes = sizeof frame;
    for (size_t i = 0; i < frame_bytes; i++) if (i < lane || i >= lane + sizeof scaled)
        assert(((uint8_t *)frame)[i] == ((uint8_t *)before)[i]);
    memset(frame, 0x5a, sizeof frame); memcpy(before, frame, sizeof frame);
    hud_cb(frame, 0);
    float rect[4]; memcpy(rect, (uint8_t *)(uintptr_t)frame[8] + 4, sizeof rect);
    assert(fabs((rect[2] / 1920) * w / h - 16.0 / 9) < 1e-6);
    assert(fabs(rect[0] - (1920 - rect[2]) * .5) < .001 && rect[1] == 0 && rect[3] == 1080);
    for (size_t i = 0; i < frame_bytes; i++) if (i < 8 * 8 || i >= 9 * 8)
        assert(((uint8_t *)frame)[i] == ((uint8_t *)before)[i]);
    printf("PASS: Violet %s camera/HUD, guards, all other SIMD/GPR/flags bytes\n", ratio);
}
