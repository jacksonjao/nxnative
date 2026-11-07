// Real Metal 4 queue and offscreen drawables exercise generated/real pairs,
// guest texture lifetime, suspend/resume and a silent-display-link watchdog.
#include "../nvn/nvn_mtl.m"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@end
@implementation FakeLinkUpdate
@end
static CAMetalLayer *g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)g_test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static tex_t source(unsigned serial, uint8_t left, uint8_t right) {   // 8x8 grey, the left four columns one value and the right four another
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; uint8_t bytes[256];
    for (int i = 0; i < 64; i++) { uint8_t v = i % 8 < 4 ? left : right; bytes[4 * i] = bytes[4 * i + 1] = bytes[4 * i + 2] = v; bytes[4 * i + 3] = 255; }
    [mt replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(16, 16); return l;
}
// Every present gets a drawable of its own layer. With all drawables from one offscreen layer, 1 of 100 runs under CPU load got ticket 1's IOSurface back from
// nextDrawable while the gate still held ticket 1's present, and ticket 4 then drew over the picture this test reads back
static NSMutableArray *g_layers;
static id<CAMetalDrawable> drawable(void) {
    CAMetalLayer *l = offscreen_layer(); [g_q4 addResidencySet:l.residencySet]; [g_layers addObject:l]; return [l nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate;
static id<CAMetalDrawable> tick_with(id<CAMetalDrawable> dr) {   // one display-link callback (it does not look at the link)
    FakeLinkUpdate *u = [FakeLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = CACurrentMediaTime() + 0.016;
    [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u];
    return dr;
}
static id<CAMetalDrawable> tick(void) { return tick_with(drawable()); }
int main(void) { @autoreleasepool {
    alarm(60); if (setvbuf(stdout,NULL,_IONBF,0)) return 1;
    setenv("DM_FRAMEGEN","opticalflow",1); setenv("DM_PRESENT_HZ","60",1);
    mtl_init(); g_test_layer=offscreen_layer(); g_layers=[NSMutableArray new];
    g_dm_present_link=2; g_link_started=1; g_link_owns_layer=1; g_delegate=[NvMetalDisplayLinkDelegate new];
    tex_t a=source(93001,40,120),b=source(93002,80,140);
    present_enqueue(&a,1./60,NULL,0); tick();
    id<MTLSharedEvent> done=[g_dev newSharedEvent];
    if (!done) { fprintf(stderr, "Could not allocate Metal shared event\n"); return 1; }
    [g_q4 signalEvent:done value:1]; CHECK("first picture GPU done",[done waitUntilSignaledValue:1 timeoutMS:10000]);
    CHECK("first frame has no generated predecessor",g_fg_pending_ticket==0);
    usleep(17000);
    present_enqueue(&b,1./60,NULL,0); tick();
    [g_q4 signalEvent:done value:2]; CHECK("generated picture GPU done",[done waitUntilSignaledValue:2 timeoutMS:10000]);
    CHECK("real picture retained for second tick",g_fg_pending_ticket==2);
    CHECK("guest texture remains owned until real picture submitted",g_pq_done<2);
    tick(); [g_q4 signalEvent:done value:3]; CHECK("real picture GPU done",[done waitUntilSignaledValue:3 timeoutMS:10000]);
    usleep(10000); CHECK("second tick clears pending picture",g_fg_pending_ticket==0 && g_pq_done==2);
    usleep(17000); present_enqueue(&a,1./60,NULL,0); tick();
    CHECK("next pair is pending",g_fg_pending_ticket==3);
    present_drop_for_suspend(); CHECK("suspend discards pending real and releases guest",!g_fg_pending_ticket && g_pq_done==3);
    CHECK("suspend requests history reset",atomic_load(&g_framegen_reset));
    usleep(17000); present_enqueue(&a,1./60,NULL,0); tick();
    CHECK("resume starts with real picture",!g_fg_pending_ticket);
    [g_q4 signalEvent:done value:4]; CHECK("resumed work completes",[done waitUntilSignaledValue:4 timeoutMS:10000]);
    usleep(17000); present_enqueue(&b,1./60,NULL,0); tick();
    CHECK("watchdog case has pending real",g_fg_pending_ticket==5);
    __atomic_store_n(&g_link_tick_ns,now_ns()-200000000ull,__ATOMIC_RELAXED); mtl_present_wait(5);
    CHECK("silent display link releases an unfinished pair",!g_fg_pending_ticket && g_pq_done>=5);
    printf("paired display: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
