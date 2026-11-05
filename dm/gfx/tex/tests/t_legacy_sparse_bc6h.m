#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "nvn_tex.h"
#include "nvn_bcdec.h"
#include "nvn_deswizzle.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

// Run the production uploader with a synthetic page table and the real GPU.
#include <stdatomic.h>
#include "nvn.h"

typedef struct {
    nvn_texdesc d;
    nvn_texlayout L;
    void *mem;
    const void *pool;
    uint64_t serial;
} tex_t;

static id<MTLDevice> g_dev;
static id<MTLCommandQueue> g_q;
static _Atomic uint64_t g_ser_gen;
static uint64_t generation, dirty;
typedef struct {
    uint64_t at, gen, stamp;
    bool mapped;
    uint8_t data[65536];
} guest_page;
static guest_page table[2];
int nvn_sparse_pool(const void *p) { return p == table; }
uint64_t nvn_sparse_gen(void) { return generation; }
static uint64_t nvn_dirty_now(void) { return dirty; }
int nvn_sparse_mapped(const void *pool, uint64_t a, uint64_t n) {
    assert(pool == table && n == 65536);
    for (unsigned i = 0; i < 2; i++) if (table[i].at == a) return table[i].mapped;
    return 0;
}
int nvn_sparse_since(const void *pool, uint64_t a, uint64_t n, uint64_t gen, uint64_t stamp) {
    assert(pool == table);
    for (unsigned i = 0; i < 2; i++)
        if (table[i].at >= a && table[i].at - a < n &&
            (table[i].gen > gen || (table[i].mapped && table[i].stamp > stamp))) return 1;
    return 0;
}
uint64_t nvn_sparse_copy(const void *pool, void *dst, uint64_t a, uint64_t n) {
    assert(nvn_sparse_mapped(pool, a, n));
    for (unsigned i = 0; i < 2; i++) if (table[i].at == a) { memcpy(dst, table[i].data, n); return 0; }
    return n;
}
void nvn_sparse_protect(const void *pool, uint64_t a, uint64_t n) { assert(nvn_sparse_mapped(pool, a, n)); }
static int no_bc(void) { return 1; }
static int on_sub_thread(void) { return 1; }
static void res_add(id<MTLTexture> t) { assert(t.isSparse); }
static void tex_put(uint64_t serial, id<MTLTexture> t) { assert(serial && t.isSparse); }
static void tex_tag_format(id<MTLTexture> t, int format) { assert(t.isSparse && (format == 0x50 || format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB)); }
#define MLOG(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define RED_ONCE(tag, ...) MLOG(__VA_ARGS__)
#include "../../nvn/nvn_legacy_sparse.inc"

static void verify_region(id<MTLTexture> mt, NSUInteger level, MTLRegion region,
                          const nvn_texdesc *guest, unsigned guest_level, const uint8_t *raw) {
    unsigned w = (unsigned)region.size.width, h = (unsigned)region.size.height;
    bool astc = guest->format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB;
    size_t rows = astc ? (h + 7) / 8 : h, row_bytes = astc ? ((w + 7) / 8) * 16 : w * 8;
    size_t src_row = ((w + 3) / 4) * 16, row = (row_bytes + 255) & ~255u, bytes = row * rows;
    uint8_t *blocks = malloc(src_row * ((h + 3) / 4));
    uint8_t *expected = calloc(1, bytes);
    id<MTLBuffer> result = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    assert(blocks && expected && result);
    if (guest->format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB)
        assert(!nvn_deswizzle(guest, guest_level, 0, raw, expected, row));
    else {
        assert(!nvn_deswizzle(guest, guest_level, 0, raw, blocks, src_row));
        assert(!nvn_bc_decode(guest->format, blocks, src_row, w, h, expected, row));
    }
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:mt sourceSlice:67 sourceLevel:level sourceOrigin:region.origin
               sourceSize:region.size toBuffer:result destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:bytes];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    assert(!cb.error);
    for (size_t y = 0; y < rows; y++)
        assert(!memcmp(expected + y * row, (uint8_t *)result.contents + y * row, row_bytes));
    free(blocks); free(expected);
}

int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice();
    assert(g_dev && [g_dev supportsFamily:MTLGPUFamilyApple6]);
    g_q = [g_dev newCommandQueue];
    tex_t t = {.d = {.target = 4, .format = 0x50, .width = 8192, .height = 8192,
                     .depth = 68, .levels = 12, .flags = 0x20},
               .mem = (void *)0x100000000ull, .pool = table, .serial = 1};
    nvn_tex_layout(&t.d, &t.L);
    assert(legacy_sparse_candidate(&t));
    uint64_t last_slice = (uint64_t)t.mem + 67 * t.L.layer_size;
    table[0].at = last_slice + 1023 * LS_PAGE;
    unsigned tail = 6;
    size_t tail_off = nvn_tex_level_offset(&t.d, tail);
    table[1].at = last_slice + tail_off;
    for (unsigned i = 0; i < 2; i++) {
        table[i].gen = ++generation;
        table[i].mapped = true;
        memset(table[i].data, 0x21, LS_PAGE);
    }
    id<MTLTexture> mt = legacy_sparse_terrain(&t, nil);
    assert(mt.isSparse);
    NvLegacySparse *state = objc_getAssociatedObject(mt, &ls_key);
    nvn_texdesc page = {.target = 1, .format = 0x50, .width = 256, .height = 256, .depth = 1, .levels = 1, .pkg_block_h = 4};
    MTLRegion region = MTLRegionMake2D(8192 - 256, 8192 - 256, 256, 256);
    verify_region(mt, 0, region, &page, 0, table[0].data);
    size_t resident = state->heap.usedSize;
    assert(resident && !atomic_load(&state->failed));
    uint8_t *layer = mmap(NULL, t.L.layer_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(layer != MAP_FAILED);
    memcpy(layer + tail_off, table[1].data, LS_PAGE);
    for (unsigned l = tail; l < t.d.levels; l++)
        verify_region(mt, l, MTLRegionMake2D(0, 0, 8192 >> l, 8192 >> l), &t.d, l, layer);
    assert(!munmap(layer, t.L.layer_size));

    memset(table[0].data + 1, 0x41, LS_PAGE - 1);
    table[0].stamp = ++dirty;
    assert(legacy_sparse_terrain(&t, mt) == mt);
    verify_region(mt, 0, region, &page, 0, table[0].data);
    assert(state->heap.usedSize == resident);

    table[0].gen = ++generation;
    table[0].mapped = false;
    assert(legacy_sparse_terrain(&t, mt) == mt);
    id<MTLCommandBuffer> fence = [g_q commandBuffer];
    [fence commit]; [fence waitUntilCompleted];
    assert(state->heap.usedSize < resident && !atomic_load(&state->failed));

    state->budget = state->resident * g_dev.sparseTileSizeInBytes;
    table[0].gen = ++generation;
    table[0].mapped = true;
    assert(legacy_sparse_terrain(&t, mt) == mt);
    assert(state->trimmed && !atomic_load(&state->failed));
    assert(state->heap.usedSize < resident);
    state->budget = LS_HEAP;
    state->revisit = true; // Simulate a budget freed by another page.
    memset(table[0].data, 0x57, LS_PAGE);
    assert(legacy_sparse_terrain(&t, mt) == mt);
    verify_region(mt, 0, region, &page, 0, table[0].data);
    assert(state->heap.usedSize == resident && !atomic_load(&state->failed));
    puts("Legacy sparse BC6H: initial tile and all tail mips, dirty rewrite, budget exhaustion, unmap and remap verified.");

    t.d.format = NVN_FORMAT_RGBA_ASTC_8x8_SRGB;
    t.serial = 2;
    nvn_tex_layout(&t.d, &t.L);
    uint32_t tw, th, td;
    tail = nvn_tex_sparse_tiles(&t.d, &tw, &th, &td);
    assert((tw / 8) * (th / 8) * 16 == LS_PAGE && td == 1);
    tail_off = nvn_tex_level_offset(&t.d, tail);
    last_slice = (uint64_t)t.mem + 67 * t.L.layer_size;
    table[0].at = last_slice + ((8192 / tw) * (8192 / th) - 1) * LS_PAGE;
    table[1].at = last_slice + tail_off;
    for (unsigned i = 0; i < 2; i++) {
        table[i].gen = ++generation;
        for (unsigned j = 0; j < LS_PAGE; j++) table[i].data[j] = j ^ (j >> 9) ^ i;
    }
    assert(legacy_sparse_candidate(&t));
    mt = legacy_sparse_terrain(&t, nil);
    assert(mt.isSparse && mt.pixelFormat == MTLPixelFormatASTC_8x8_sRGB);
    state = objc_getAssociatedObject(mt, &ls_key);
    unsigned tile_h, tile_d;
    nvn_tex_level_tiles(&t.d, 0, &tile_h, &tile_d);
    page = (nvn_texdesc){.target = 1, .format = t.d.format, .width = tw, .height = th,
                         .depth = 1, .levels = 1, .pkg_block_h = tile_h + 1};
    region = MTLRegionMake2D(8192 - tw, 8192 - th, tw, th);
    verify_region(mt, 0, region, &page, 0, table[0].data);
    resident = state->heap.usedSize;
    assert(resident && resident < (1 << 20) && !atomic_load(&state->failed));
    layer = mmap(NULL, t.L.layer_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(layer != MAP_FAILED);
    memcpy(layer + tail_off, table[1].data, LS_PAGE);
    for (unsigned l = tail; l < t.d.levels; l++)
        verify_region(mt, l, MTLRegionMake2D(0, 0, 8192 >> l, 8192 >> l), &t.d, l, layer);
    assert(!munmap(layer, t.L.layer_size));
    table[0].data[15] ^= 0xa5;
    table[0].stamp = ++dirty;
    assert(legacy_sparse_terrain(&t, mt) == mt);
    verify_region(mt, 0, region, &page, 0, table[0].data);
    assert(state->heap.usedSize == resident);
    puts("Legacy sparse ASTC 8x8 sRGB: native tile and mip tail GPU readback, bounded residency and dirty rewrite verified.");
    return 0;
} }
