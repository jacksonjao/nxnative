#pragma once
// Buffer-only weak address index. Membership changes under this lock; the
// owning resource table/deferred-release queue controls buffer lifetime.
// Dynamic capacity avoids silently dropping buffers in larger game profiles.
// Keep the ARC weak slot at a stable address when the C index grows or shifts.
@interface DMLegacyBufferRef : NSObject {
@public
    __weak id<MTLBuffer> buffer;
}
@end
@implementation DMLegacyBufferRef
@end

typedef struct {
    uint64_t gpu, length;
    const void *identity;
    CFTypeRef ref;
} legacy_buffer_entry;
static legacy_buffer_entry *g_legacy_buffers;
static size_t g_legacy_count, g_legacy_capacity;
static size_t g_legacy_additions;
static os_unfair_lock g_legacy_lock = OS_UNFAIR_LOCK_INIT;
static int g_legacy_direct_arguments = 1;
static uint64_t g_legacy_next_buffer = UINT64_C(0x10000000000);
static void legacy_arguments_configure(id<MTLDevice> device) {
    const char *force = getenv("DM_NVN_ARGUMENT_ENCODER");
    g_legacy_direct_arguments = device.argumentBuffersSupport == MTLArgumentBuffersTier2 && !(force && atoi(force));
}
static id<MTLBuffer> legacy_buffer_load(const legacy_buffer_entry *entry) {
    return ((__bridge DMLegacyBufferRef *)entry->ref)->buffer;
}
static void legacy_buffer_erase(size_t at) {
    CFRelease(g_legacy_buffers[at].ref);
    --g_legacy_count;
    memmove(g_legacy_buffers + at, g_legacy_buffers + at + 1,
            (g_legacy_count - at) * sizeof *g_legacy_buffers);
}
static void legacy_buffer_add(id<MTLBuffer> b) {
    if (!b) return;
    const void *identity = (__bridge const void *)b;
    os_unfair_lock_lock(&g_legacy_lock);
    for (size_t i = 0; i < g_legacy_count;) {
        if (g_legacy_buffers[i].identity != identity) { i++; continue; }
        if (legacy_buffer_load(&g_legacy_buffers[i]) == b) {
            os_unfair_lock_unlock(&g_legacy_lock); return;
        }
        legacy_buffer_erase(i);
    }
    if (++g_legacy_additions % 1024 == 0 || g_legacy_count == g_legacy_capacity) {
        size_t kept = 0;
        for (size_t i = 0; i < g_legacy_count; i++) {
            legacy_buffer_entry entry = g_legacy_buffers[i];
            if (legacy_buffer_load(&entry)) g_legacy_buffers[kept++] = entry;
            else CFRelease(entry.ref);
        }
        g_legacy_count = kept;
    }
    uint64_t gpu;
    if (g_legacy_direct_arguments) gpu = b.gpuAddress;
    else {
        // CPU-only address arithmetic. These tokens never reach GPU memory;
        // the argument encoder resolves them to a real buffer and offset.
        uint64_t span = ((uint64_t)b.length + 65535) & ~UINT64_C(65535);
        if (!span || span > UINT64_MAX - g_legacy_next_buffer) {
            os_unfair_lock_unlock(&g_legacy_lock); MDIE("[RED] Buffer token range exhausted");
        }
        gpu = g_legacy_next_buffer; g_legacy_next_buffer += span;
    }
    size_t at = 0;
    while (at < g_legacy_count && g_legacy_buffers[at].gpu <= gpu) at++;
    if (g_legacy_count == g_legacy_capacity) {
        size_t cap = g_legacy_capacity ? g_legacy_capacity * 2 : 256;
        legacy_buffer_entry *next = realloc(g_legacy_buffers, cap * sizeof *next);
        if (!next) { os_unfair_lock_unlock(&g_legacy_lock); MDIE("【红】Buffer index allocation failed"); }
        g_legacy_buffers = next; g_legacy_capacity = cap;
    }
    memmove(g_legacy_buffers + at + 1, g_legacy_buffers + at,
            (g_legacy_count - at) * sizeof *g_legacy_buffers);
    DMLegacyBufferRef *ref = [DMLegacyBufferRef new];
    ref->buffer = b;
    g_legacy_buffers[at] = (legacy_buffer_entry){gpu, b.length, identity, CFBridgingRetain(ref)};
    g_legacy_count++;
    os_unfair_lock_unlock(&g_legacy_lock);
}
static uint64_t legacy_buffer_gpu(id<MTLBuffer> b) {
    if (!b) return 0;
    if (g_legacy_direct_arguments) return b.gpuAddress;
    legacy_buffer_add(b);
    os_unfair_lock_lock(&g_legacy_lock);
    uint64_t gpu = 0;
    for (size_t i = 0; i < g_legacy_count; i++) if (g_legacy_buffers[i].identity == (__bridge const void *)b &&
                                                 legacy_buffer_load(&g_legacy_buffers[i]) == b) {
        gpu = g_legacy_buffers[i].gpu; break;
    }
    os_unfair_lock_unlock(&g_legacy_lock);
    return gpu;
}
static uint64_t legacy_texture_rid(id<MTLTexture> t) {
    return !t ? 0 : g_legacy_direct_arguments ? t.gpuResourceID._impl : (uint64_t)(uintptr_t)(__bridge void *)t;
}
static uint64_t legacy_sampler_rid(id<MTLSamplerState> s) {
    return !s ? 0 : g_legacy_direct_arguments ? s.gpuResourceID._impl : (uint64_t)(uintptr_t)(__bridge void *)s;
}
static void legacy_buffer_remove(id<MTLBuffer> b) {
    const void *identity = (__bridge const void *)b;
    os_unfair_lock_lock(&g_legacy_lock);
    for (size_t i = 0; i < g_legacy_count; i++)
        if (g_legacy_buffers[i].identity == identity) { legacy_buffer_erase(i); break; }
    os_unfair_lock_unlock(&g_legacy_lock);
}
static id<MTLBuffer> legacy_buffer_at(uint64_t gpu, NSUInteger *offset) {
    *offset = 0;
    if (!gpu) return nil;
    os_unfair_lock_lock(&g_legacy_lock);
    size_t lo = 0, hi = g_legacy_count;
    while (lo < hi) { size_t m = lo + (hi - lo) / 2;
        if (g_legacy_buffers[m].gpu <= gpu) lo = m + 1; else hi = m;
    }
    id<MTLBuffer> b = nil;
    if (lo) {
        uint64_t base = g_legacy_buffers[lo - 1].gpu;
        do {
            legacy_buffer_entry *entry = &g_legacy_buffers[--lo];
            if (gpu - base < entry->length && (b = legacy_buffer_load(entry))) {
                *offset = (NSUInteger)(gpu - base);
                break;
            }
        } while (lo && g_legacy_buffers[lo - 1].gpu == base);
    }
    os_unfair_lock_unlock(&g_legacy_lock);
    return b;
}
