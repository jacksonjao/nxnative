// Exercise the actual callbacks against a fake monotonic guest clock. Different
// render rates must advance the same simulated second, including missed frames.
#include <assert.h>
#include <sys/mman.h>
#include "../hle.h"
#include <math.h>
#include <stdatomic.h>
#include "../hle_arceus_timing.inc"
static module_t modules[1];
module_t *g_mod = modules;
int g_nmod = 1;
static uint64_t clock_ns;
static int have;
static void (*callback)(uint64_t *, int);
uint64_t guest_ns(void) { return clock_ns; }
void gate_obs_set(int id, void (*fn)(uint64_t *, int)) { assert(id == OBS_ARCEUS_TIMING); callback = fn; }
int gate_obs_present(int id) { return have && id == OBS_ARCEUS_TIMING; }
static void registers(uint64_t *r) { for (int i = 0; i < 31; i++) r[i] = 0x123400 + i; }
int main(int argc, char **argv) {
    assert(argc == 2);
    setenv("DM_ARCEUS_FPS", argv[1], 1);
    module_t *m = modules;
    strcpy(m->name, "main"); strcpy(m->build_id, "aee8f150dda1b5a838806e1a5ea6827a");
    m->size = 0x4354000; m->text_end = 0x32a5690; m->ro_off = 0x32a6000; m->data_off = 0x401a000;
    m->base = mmap(NULL, m->size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(m->base != MAP_FAILED);
    uint64_t *duration = (uint64_t *)(m->base + 0x397e8d8); *duration = 33333334;
    dm_arceus_timing_init(); assert(!g_arceus_time_base);
    have = 1; m->build_id[0] = '0'; dm_arceus_timing_init(); assert(!g_arceus_time_base); m->build_id[0] = 'a';
    *duration = 42; dm_arceus_timing_init(); assert(!g_arceus_time_base); *duration = 33333334;
    dm_arceus_timing_init();
    int target = !strcmp(argv[1], "120") ? 120 : !strcmp(argv[1], "60") ? 60 : !strcmp(argv[1], "30") ? 30 : 0;
    if (target != 30 && target != 60 && target != 120) { assert(!g_arceus_time_base); puts("PASS: Arceus native/invalid target stays untouched"); return 0; }
    const char *framegen = getenv("DM_FRAMEGEN");
    if (framegen && !strcmp(framegen, "opticalflow") && target > 60) target = 60;
    assert(g_arceus_time_base == m->base);
    const char *interval = getenv("DM_PRESENT_INTERVAL");
    assert(interval && !strcmp(interval, "display"));
    assert(atoi(getenv("DM_PRESENT_HZ")) == target);
    uint64_t regs[31];
    clock_ns = 1000000000ull; registers(regs); callback(regs, 0);
    for (int i = 0; i < 31; i++) assert(regs[i] == (uint64_t)(0x123400 + i));
    const int rates[] = {30, 60, 120, 47, 20};
    for (unsigned q = 0; q < sizeof rates / sizeof *rates; q++) {
        double seconds = 0; uint64_t base = clock_ns;
        for (int f = 1; f <= rates[q]; f++) {
            clock_ns = base + (uint64_t)f * 1000000000ull / rates[q];
            callback(regs, 0); registers(regs); callback(regs, 1);
            uint32_t bits = (uint32_t)regs[8]; float dt; memcpy(&dt, &bits, sizeof dt);
            assert(fabs(dt - (double)*duration / 1e9) < 1e-8); seconds += dt;
            for (int i = 0; i < 31; i++) if (i != 8) assert(regs[i] == (uint64_t)(0x123400 + i));
        }
        assert(fabs(seconds - 1) < 1e-6);
    }
    registers(regs); callback(regs, 2); assert(regs[1] == 1);
    for (int i = 0; i < 31; i++) if (i != 1) assert(regs[i] == (uint64_t)(0x123400 + i));
    clock_ns += 1000000000ull; callback(regs, 0); assert(*duration == 66666667);
    puts("PASS: Arceus target, build/gate/value guards, clock at 20/30/47/60/120 fps, hitch bound, register preservation");
}
