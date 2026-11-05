#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define MDIE(...) abort()
#include "../nvn/nvn_legacy_buffers.h"

@interface TestLegacyBuffer : NSObject
@property uint64_t gpuAddress;
@property NSUInteger length;
@end
@implementation TestLegacyBuffer
@end

static id<MTLBuffer> make_buffer(uint64_t address) {
    TestLegacyBuffer *buffer = [TestLegacyBuffer new];
    buffer.gpuAddress = address;
    buffer.length = 4096;
    return (id<MTLBuffer>)buffer;
}

int main(void) {
    @autoreleasepool {
        assert(!legacy_texture_rid(nil) && !legacy_sampler_rid(nil));
        NSUInteger offset = 0;
        __weak id<MTLBuffer> expired;
        @autoreleasepool {
            id<MTLBuffer> buffer = make_buffer(0x4000);
            expired = buffer;
            legacy_buffer_add(buffer);
            assert(legacy_buffer_at(0x4080, &offset) == buffer && offset == 128);
        }
        assert(!expired);
        assert(!legacy_buffer_at(0x4080, &offset) && offset == 0);

        // The GPU allocator may assign the same address to a new buffer.
        id<MTLBuffer> replacement = make_buffer(0x4000);
        legacy_buffer_add(replacement);
        assert(legacy_buffer_at(0x4080, &offset) == replacement && offset == 128);

        // Grow and shift the index; ARC weak storage must not move with it.
        NSMutableArray *owners = [NSMutableArray array];
        for (int i = 300; i > 0; --i) {
            id<MTLBuffer> buffer = make_buffer(0x10000 + 0x2000 * i);
            [owners addObject:buffer];
            legacy_buffer_add(buffer);
        }
        assert(legacy_buffer_at(0x12020, &offset) == owners.lastObject && offset == 32);
        legacy_buffer_remove(replacement);
        assert(!legacy_buffer_at(0x4080, &offset) && offset == 0);

        g_legacy_direct_arguments = 0;
        @autoreleasepool {
            id<MTLBuffer> buffer = make_buffer(0);
            uint64_t token = legacy_buffer_gpu(buffer);
            assert(token && token == legacy_buffer_gpu(buffer));
            assert(legacy_buffer_at(token + 1, &offset) == buffer && offset == 1);
            id<MTLBuffer> resolved = legacy_buffer_at(token, &offset);
            buffer = nil;
            assert(resolved && resolved.length == 4096);
            legacy_buffer_remove(resolved);
            assert(!legacy_buffer_at(token, &offset) && offset == 0);
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            legacy_arguments_configure(device);
            __weak id<MTLBuffer> metal_expired;
            uint64_t address;
            @autoreleasepool {
                id<MTLBuffer> buffer = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
                assert(buffer);
                metal_expired = buffer;
                legacy_buffer_add(buffer);
                address = legacy_buffer_gpu(buffer);
                assert(address && legacy_buffer_at(address + 17, &offset) == buffer && offset == 17);
            }
            assert(!metal_expired);
            assert(!legacy_buffer_at(address + 17, &offset) && offset == 0);
        }
    }
    return 0;
}
