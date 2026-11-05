// The Switch 2 terrain caches include unsigned BC6H (decoded on older
// GPUs) and native ASTC 8x8 sRGB. A mapped guest 64 KiB page is copied into
// private sparse Metal tiles; GPU-written data stays in those tiles until
// the guest changes the backing mapping or writes the backing CPU pages.
enum { LS_PAGE = 65536, LS_BATCH = 8 << 20, LS_HEAP = 384 << 20, LS_DETAIL = 160 << 20 };
static const char ls_key;
int nvn_sparse_pool(const void *pool);
uint64_t nvn_sparse_gen(void);
uint64_t nvn_sparse_copy(const void *pool, void *dst, uint64_t a, uint64_t n);
int nvn_sparse_since(const void *pool, uint64_t a, uint64_t n, uint64_t gen, uint64_t stamp);
int nvn_sparse_mapped(const void *pool, uint64_t a, uint64_t n);
void nvn_sparse_protect(const void *pool, uint64_t a, uint64_t n);

@interface NvLegacySparse : NSObject {
@public
    id<MTLHeap> heap;
    NSMutableData *pages;
    uint64_t gen, stamp;
    uint32_t resident, detail;
    NSUInteger budget;
    BOOL initialized, trimmed, revisit;
    _Atomic bool failed;
}
@end
@implementation NvLegacySparse
@end

typedef struct {
    MTLRegion pixels;
    NSUInteger level, slice, offset, row, image_bytes;
    int mapping; // +1 map, -1 unmap, 0 leave unchanged
} ls_op;

typedef struct {
    __strong id<MTLBuffer> data;
    ls_op ops[256];
    size_t bytes;
    unsigned count;
} ls_batch;

static int legacy_sparse_candidate(const tex_t *t) {
    return t && t->d.target == NVN_TEXTURE_TARGET_2D_ARRAY &&
        ((t->d.format == 0x50 && no_bc()) || t->d.format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB) &&
        t->d.width == 8192 && t->d.height == 8192 && t->d.depth == 68 && t->d.levels == 12 &&
        (t->d.flags & NVN_TEXTURE_FLAGS_SPARSE) &&
        !(t->d.flags & (NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_COMPRESSIBLE |
                        NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET)) &&
        t->d.samples <= 1 && t->mem && t->pool && nvn_sparse_pool(t->pool);
}

// Queue uploads before the replay CB is committed, as for packaged textures.
// Batches retain their staging buffers until the GPU finishes, with at most
// two buffers in flight. No app-visible texture or entire layer is staged.
static bool ls_flush(ls_batch *batch, id<MTLTexture> mt, MTLSize tile, NvLegacySparse *state) {
    if (!batch->count) return true;
    static dispatch_semaphore_t inflight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inflight = dispatch_semaphore_create(2); });
    dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    id<MTLResourceStateCommandEncoder> map = [cb resourceStateCommandEncoder];
    if (!map) { dispatch_semaphore_signal(inflight); return false; }
    for (unsigned i = 0; i < batch->count; i++) {
        ls_op *op = &batch->ops[i];
        if (!op->mapping) continue;
        MTLRegion r = op->pixels;
        MTLRegion tiles = op->level >= mt.firstMipmapInTail ? MTLRegionMake2D(0, 0, 1, 1) :
            MTLRegionMake2D(r.origin.x / tile.width, r.origin.y / tile.height,
                            (r.size.width + tile.width - 1) / tile.width,
                            (r.size.height + tile.height - 1) / tile.height);
        [map updateTextureMapping:mt mode:op->mapping > 0 ? MTLSparseTextureMappingModeMap : MTLSparseTextureMappingModeUnmap
                          region:tiles mipLevel:op->level slice:op->slice];
    }
    [map endEncoding];
    if (batch->bytes) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (!blit) { dispatch_semaphore_signal(inflight); return false; }
        for (unsigned i = 0; i < batch->count; i++) {
            ls_op *op = &batch->ops[i];
            if (!op->row) continue;
            [blit copyFromBuffer:batch->data sourceOffset:op->offset sourceBytesPerRow:op->row
              sourceBytesPerImage:op->image_bytes sourceSize:op->pixels.size
                         toTexture:mt destinationSlice:op->slice destinationLevel:op->level destinationOrigin:op->pixels.origin];
        }
        [blit endEncoding];
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.error && !atomic_exchange(&state->failed, true)) {
            g_ser_gen++;
            MLOG("Legacy sparse terrain command failed: %s", done.error.localizedDescription.UTF8String);
        }
        dispatch_semaphore_signal(inflight);
    }];
    [cb commit];
    batch->data = nil;
    batch->bytes = 0;
    batch->count = 0;
    return true;
}

static bool ls_stage(ls_batch *batch, id<MTLTexture> mt, MTLSize tile, NvLegacySparse *state, ls_op op,
                     const nvn_texdesc *src, unsigned src_level, const void *raw, void *blocks) {
    unsigned w = (unsigned)op.pixels.size.width, h = (unsigned)op.pixels.size.height;
    bool native_astc = src->format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB;
    size_t width_bytes = native_astc ? ((w + 7) / 8) * 16 : w * 8u;
    size_t row = raw ? (width_bytes + 255u) & ~255u : 0;
    size_t bytes = row * (native_astc ? (h + 7) / 8 : h);
    if (batch->count == sizeof batch->ops / sizeof *batch->ops || batch->bytes + bytes > LS_BATCH)
        if (!ls_flush(batch, mt, tile, state)) return false;
    if (raw) {
        if (!batch->data) batch->data = [g_dev newBufferWithLength:LS_BATCH options:MTLResourceStorageModeShared];
        if (!batch->data) return false;
        uint8_t *dst = (uint8_t *)batch->data.contents + batch->bytes;
        if (native_astc) {
            if (nvn_deswizzle(src, src_level, 0, raw, dst, row)) return false;
        } else {
            size_t block_row = ((w + 3) / 4) * 16;
            if (nvn_deswizzle(src, src_level, 0, raw, blocks, block_row) ||
                nvn_bc_decode(src->format, blocks, block_row, w, h, dst, row)) return false;
        }
    }
    op.offset = batch->bytes;
    op.row = row;
    op.image_bytes = bytes;
    batch->ops[batch->count++] = op;
    batch->bytes += bytes;
    return true;
}

static bool ls_fits(NvLegacySparse *s, unsigned tiles, NSUInteger tile_bytes, bool detail) {
    return (s->resident + tiles) * tile_bytes <= s->budget &&
           (!detail || (s->detail + tiles) * tile_bytes <= LS_DETAIL);
}

static void ls_account(NvLegacySparse *s, unsigned tiles, int mode, bool detail) {
    if (mode > 0) { s->resident += tiles; if (detail) s->detail += tiles; }
    if (mode < 0) { s->resident -= tiles; if (detail) s->detail -= tiles; }
}

static unsigned ls_tail_tiles(const tex_t *t, id<MTLTexture> mt, unsigned tail, MTLSize tile) {
    unsigned total = 0;
    for (unsigned l = tail; l < mt.mipmapLevelCount && l <= mt.firstMipmapInTail; l++) {
        if (l == mt.firstMipmapInTail) { total++; break; }
        unsigned w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u);
        total += (unsigned)((w + tile.width - 1) / tile.width * ((h + tile.height - 1) / tile.height));
    }
    return total;
}

static bool ls_refresh(const tex_t *t, id<MTLTexture> mt, NvLegacySparse *s, MTLSize tile) {
    uint64_t gen = nvn_sparse_gen(), stamp = nvn_dirty_now();
    if (s->initialized && gen == s->gen && stamp == s->stamp && !s->revisit) return true;
    uint32_t tw, th, td;
    int tail = nvn_tex_sparse_tiles(&t->d, &tw, &th, &td);
    unsigned mt_tail = (unsigned)mt.firstMipmapInTail;
    if (tail <= 0 || (unsigned)tail >= t->d.levels || !tw || !th || td != 1 || !tile.width || !tile.height ||
        tw % tile.width || th % tile.height || mt_tail < (unsigned)tail) {
        MLOG("Legacy sparse terrain incompatible tile layout: guest %ux%ux%u tail=%d; Metal %lux%lux%lu tail=%u/%lu tile=%lu B",
             tw, th, td, tail, (unsigned long)tile.width, (unsigned long)tile.height, (unsigned long)tile.depth,
             mt_tail, (unsigned long)mt.mipmapLevelCount, (unsigned long)g_dev.sparseTileSizeInBytes);
        return false;
    }
    nvn_texdesc page = {.target = NVN_TEXTURE_TARGET_2D, .format = t->d.format,
                        .width = tw, .height = th, .depth = 1, .levels = 1};
    unsigned bh, bd;
    nvn_tex_level_tiles(&t->d, 0, &bh, &bd);
    page.pkg_block_h = bh + 1;
    nvn_texlayout pl;
    nvn_tex_layout(&page, &pl);
    size_t tail_off = nvn_tex_level_offset(&t->d, (unsigned)tail), layer = t->L.layer_size;
    if (bd || pl.size != LS_PAGE || tail_off % LS_PAGE || layer < tail_off || layer - tail_off != LS_PAGE) {
        MLOG("Legacy sparse terrain invalid guest pages: blockDepth=%u page=%zu layer=%zu tailOffset=%zu",
             bd, (size_t)pl.size, layer, tail_off);
        return false;
    }
    if (!s->pages) s->pages = [NSMutableData dataWithLength:layer / LS_PAGE * t->d.depth];
    uint8_t *mapped = s->pages.mutableBytes;
    uint8_t *blocks = malloc(LS_PAGE);
    // nvn_deswizzle accepts a layer base; only its last page is read for
    // the tail. Reserve the preceding address range without touching it.
    uint8_t *raw = mmap(NULL, layer, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    bool ok = mapped && blocks && raw != MAP_FAILED;
    ls_batch batch = {0};
    const NSUInteger tile_bytes = g_dev.sparseTileSizeInBytes;
    if (!tile_bytes) ok = false;
    // NVN exposes more mapped compressed pages than this heap can hold after
    // decoding. Keep the existing sparse texture live and leave excess pages
    // unmapped, with a separate cap for high-detail levels to preserve coarse
    // terrain. Reconsider skipped pages after an unmap actually frees space.
    bool retry = s->revisit, trimmed = s->trimmed && !retry, freed = false;
    const unsigned tail_tiles = ls_tail_tiles(t, mt, (unsigned)tail, tile);
    for (unsigned slice = 0; ok && slice < t->d.depth; slice++) {
        uint64_t addr = (uint64_t)(uintptr_t)t->mem + (uint64_t)slice * layer;
        if (!retry && !nvn_sparse_since(t->pool, addr, layer, s->gen, s->stamp)) continue;
        uint8_t *live = mapped + slice * (layer / LS_PAGE);
        for (unsigned l = 0; ok && l < (unsigned)tail; l++) {
            unsigned nx = (t->d.width >> l) / tw, ny = (t->d.height >> l) / th;
            size_t off = nvn_tex_level_offset(&t->d, l);
            for (unsigned y = 0; ok && y < ny; y++) for (unsigned x = 0; ok && x < nx; x++) {
                size_t p = off / LS_PAGE + y * nx + x;
                uint64_t a = addr + p * LS_PAGE;
                if (!(retry && !live[p]) && !nvn_sparse_since(t->pool, a, LS_PAGE, s->gen, s->stamp)) continue;
                bool present = nvn_sparse_mapped(t->pool, a, LS_PAGE);
                int mode = (int)present - live[p];
                if (!present && !mode) continue;
                unsigned tiles = (unsigned)(tw / tile.width * (th / tile.height));
                bool detail = t->d.format == 0x50 && l < 4;
                if (mode > 0 && !ls_fits(s, tiles, tile_bytes, detail)) { trimmed = true; continue; }
                if (present) { nvn_sparse_protect(t->pool, a, LS_PAGE); if (nvn_sparse_copy(t->pool, raw, a, LS_PAGE)) continue; }
                ls_op op = {.pixels = MTLRegionMake2D(x * tw, y * th, tw, th), .level = l, .slice = slice, .mapping = mode};
                ok = ls_stage(&batch, mt, tile, s, op, &page, 0, present ? raw : NULL, blocks);
                if (ok) { ls_account(s, tiles, mode, detail); live[p] = present; freed |= mode < 0; }
            }
        }
        uint64_t a = addr + tail_off;
        size_t p = tail_off / LS_PAGE;
        if (!ok || (!(retry && !live[p]) && !nvn_sparse_since(t->pool, a, LS_PAGE, s->gen, s->stamp))) continue;
        bool present = nvn_sparse_mapped(t->pool, a, LS_PAGE);
        int mode = (int)present - live[p];
        if (!present && !mode) continue;
        if (mode > 0 && !ls_fits(s, tail_tiles, tile_bytes, false)) { trimmed = true; continue; }
        if (present) { nvn_sparse_protect(t->pool, a, LS_PAGE); if (nvn_sparse_copy(t->pool, raw + tail_off, a, LS_PAGE)) continue; }
        for (unsigned l = (unsigned)tail; ok && l < mt.mipmapLevelCount; l++) {
            unsigned w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u);
            if (!present && l > mt_tail) break;
            int map_mode = l <= mt_tail ? mode : 0;
            ls_op op = {.pixels = MTLRegionMake2D(0, 0, w, h), .level = l, .slice = slice, .mapping = map_mode};
            ok = ls_stage(&batch, mt, tile, s, op, &t->d, l, present ? raw : NULL, blocks);
        }
        if (ok) { ls_account(s, tail_tiles, mode, false); live[p] = present; freed |= mode < 0; }
    }
    if (raw != MAP_FAILED) munmap(raw, layer);
    free(blocks);
    if (ok) ok = ls_flush(&batch, mt, tile, s);
    if (ok) {
        if (trimmed && !s->trimmed)
            MLOG("Legacy sparse terrain budget reached: keep %u mapped tiles, leave excess pages unmapped", s->resident);
        s->trimmed = trimmed; s->revisit = trimmed && freed; s->gen = gen; s->stamp = stamp; s->initialized = YES;
    }
    return ok;
}

static id<MTLTexture> legacy_sparse_terrain(const tex_t *t, id<MTLTexture> existing) {
    id<MTLTexture> mt = existing;
    // Replay owns both the page bookkeeping and command ordering.
    if (!on_sub_thread()) return mt;
    NvLegacySparse *s = mt ? objc_getAssociatedObject(mt, &ls_key) : nil;
    bool fresh = !mt;
    if (fresh) {
        s = [NvLegacySparse new];
        s->budget = LS_HEAP;
        MTLHeapDescriptor *heap = [MTLHeapDescriptor new];
        heap.type = MTLHeapTypeSparse;
        heap.storageMode = MTLStorageModePrivate;
        heap.size = LS_HEAP;
        s->heap = [g_dev newHeapWithDescriptor:heap];
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = MTLTextureType2DArray;
        d.pixelFormat = t->d.format == NVN_FORMAT_RGBA_ASTC_8x8_SRGB ? MTLPixelFormatASTC_8x8_sRGB : MTLPixelFormatRGBA16Float;
        d.width = t->d.width; d.height = t->d.height;
        d.arrayLength = t->d.depth; d.mipmapLevelCount = t->d.levels;
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        mt = [s->heap newTextureWithDescriptor:d];
        if (!mt.isSparse) { RED_ONCE(2, "Legacy sparse terrain array allocation failed"); return nil; }
        objc_setAssociatedObject(mt, &ls_key, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!s || atomic_load(&s->failed)) return nil;
    MTLSize tile = [g_dev sparseTileSizeWithTextureType:mt.textureType pixelFormat:mt.pixelFormat sampleCount:1];
    if (!ls_refresh(t, mt, s, tile)) {
        if (!atomic_exchange(&s->failed, true)) {
            g_ser_gen++;
            MLOG("Legacy sparse terrain refresh stopped: resident=%u tile=%lu B, Metal tile=%lux%lu tail=%lu; layer=%zu",
                 s->resident, (unsigned long)g_dev.sparseTileSizeInBytes, (unsigned long)tile.width,
                 (unsigned long)tile.height, (unsigned long)mt.firstMipmapInTail, (size_t)t->L.layer_size);
        }
        return nil;
    }
    if (fresh) {
        res_add(mt);
        tex_tag_format(mt, t->d.format);
        tex_put(t->serial, mt);
        MLOG("Legacy sparse terrain array format=%#x %ux%u x%u initialized (%u resident Metal tiles)", t->d.format, t->d.width, t->d.height, t->d.depth, s->resident);
    }
    return mt;
}
