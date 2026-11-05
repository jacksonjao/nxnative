#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn_tex.h"
#include "nvn_bcdec.h"
#include "nvn_deswizzle.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) { @autoreleasepool {
    nvn_texdesc guest = {.target = 4, .format = 0x50, .width = 8192, .height = 8192,
                         .depth = 68, .levels = 12, .flags = 0x20};
    uint32_t tw, th, td;
    int tiled = nvn_tex_sparse_tiles(&guest, &tw, &th, &td);
    assert(tiled == 6 && tw == 256 && th == 256 && td == 1);
    nvn_texdesc page = {.target = 1, .format = guest.format, .width = tw, .height = th, .depth = 1, .levels = 1};
    unsigned h, z;
    nvn_tex_level_tiles(&guest, 0, &h, &z);
    page.pkg_block_h = h + 1;
    nvn_texlayout layout;
    nvn_tex_layout(&page, &layout);
    assert(layout.size == 65536 && z == 0);

    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
    assert(gpu && [gpu supportsFamily:MTLGPUFamilyApple6]);
    MTLHeapDescriptor *heapDesc = [MTLHeapDescriptor new];
    heapDesc.type = MTLHeapTypeSparse;
    heapDesc.storageMode = MTLStorageModePrivate;
    heapDesc.size = 16 << 20;
    id<MTLHeap> heap = [gpu newHeapWithDescriptor:heapDesc];
    assert(heap);
    MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType2DArray;
    desc.pixelFormat = MTLPixelFormatRGBA16Float;
    desc.width = guest.width; desc.height = guest.height;
    desc.arrayLength = guest.depth; desc.mipmapLevelCount = guest.levels;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [heap newTextureWithDescriptor:desc];
    assert(texture.isSparse && !heap.usedSize);
    MTLSize tile = [gpu sparseTileSizeWithTextureType:desc.textureType pixelFormat:desc.pixelFormat sampleCount:1];
    assert(tile.width && tile.height && !(tw % tile.width) && !(th % tile.height));

    uint8_t *guest_page = malloc(layout.size);
    uint8_t *linear = malloc(layout.size);
    assert(guest_page && linear);
    // Exercise the original tiled layout with valid, distinct BC6H blocks.
    memset(guest_page, 0x21, layout.size);
    for (size_t i = 0; i < layout.size; i += 16) guest_page[i + 1] = (uint8_t)(i >> 4);
    assert(!nvn_deswizzle(&page, 0, 0, guest_page, linear, (size_t)tw * 4));
    size_t row = tw * 8, bytes = row * th;
    id<MTLBuffer> source = [gpu newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> result = [gpu newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    assert(source && result);
    assert(!nvn_bc_decode(guest.format, linear, (size_t)tw * 4, tw, th, source.contents, row));
    free(linear); free(guest_page);

    id<MTLCommandBuffer> cb = [[gpu newCommandQueue] commandBuffer];
    id<MTLResourceStateCommandEncoder> map = [cb resourceStateCommandEncoder];
    MTLOrigin origin = MTLOriginMake(desc.width - tw, desc.height - th, 0);
    [map updateTextureMapping:texture mode:MTLSparseTextureMappingModeMap
                       region:MTLRegionMake2D(origin.x / tile.width, origin.y / tile.height, tw / tile.width, th / tile.height)
                     mipLevel:0 slice:67];
    [map endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    MTLSize size = MTLSizeMake(tw, th, 1);
    [blit copyFromBuffer:source sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:bytes sourceSize:size
               toTexture:texture destinationSlice:67 destinationLevel:0 destinationOrigin:origin];
    [blit copyFromTexture:texture sourceSlice:67 sourceLevel:0 sourceOrigin:origin sourceSize:size
                 toBuffer:result destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:bytes];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    assert(!cb.error && !memcmp(source.contents, result.contents, bytes));
    assert(heap.usedSize == bytes);
    printf("Guest page: %ux%u/%llu bytes. Legacy Metal tiles: %lux%lu. GPU allocated %lu bytes and read back slice 67. Guest/Metal tails start at %d/%lu.\n",
           tw, th, (unsigned long long)layout.size, tile.width, tile.height, heap.usedSize, tiled, texture.firstMipmapInTail);
    // The guest groups mips 6 and 7 in its tail. Metal still treats
    // them as regular tiles, then maps one tail at its own level 8.
    nvn_texlayout full;
    nvn_tex_layout(&guest, &full);
    uint8_t *layer = mmap(NULL, full.layer_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(layer != MAP_FAILED);
    size_t tail_start = nvn_tex_level_offset(&guest, tiled);
    memset(layer + tail_start, 0x21, full.layer_size - tail_start);
    NSUInteger tail_base = texture.firstMipmapInTail;
    assert(tail_base >= (NSUInteger)tiled && tail_base < desc.mipmapLevelCount);
    id<MTLCommandBuffer> tails = [[gpu newCommandQueue] commandBuffer];
    map = [tails resourceStateCommandEncoder];
    for (NSUInteger level = tiled; level < tail_base; level++) {
        NSUInteger w = MAX(desc.width >> level, 1), h = MAX(desc.height >> level, 1);
        [map updateTextureMapping:texture mode:MTLSparseTextureMappingModeMap
                           region:MTLRegionMake2D(0, 0, (w + tile.width - 1)/tile.width, (h + tile.height - 1)/tile.height)
                         mipLevel:level slice:67];
    }
    [map updateTextureMapping:texture mode:MTLSparseTextureMappingModeMap
                       region:MTLRegionMake2D(0, 0, 1, 1) mipLevel:tail_base slice:67];
    [map endEncoding];
    blit = [tails blitCommandEncoder];
    NSMutableArray<id<MTLBuffer>> *inputs = [NSMutableArray array], *outputs = [NSMutableArray array];
    for (NSUInteger level = tiled; level < desc.mipmapLevelCount; level++) {
        NSUInteger w = MAX(desc.width >> level, 1), h = MAX(desc.height >> level, 1);
        size_t src_row = ((w + 3)/4) * 16, src_bytes = src_row * ((h + 3)/4), dst_row = w * 8, dst_bytes = dst_row * h;
        uint8_t *blocks = malloc(src_bytes);
        id<MTLBuffer> src = [gpu newBufferWithLength:dst_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [gpu newBufferWithLength:dst_bytes options:MTLResourceStorageModeShared];
        assert(blocks && src && dst);
        assert(!nvn_deswizzle(&guest, (unsigned)level, 0, layer, blocks, src_row));
        assert(!nvn_bc_decode(guest.format, blocks, src_row, (unsigned)w, (unsigned)h, src.contents, dst_row));
        free(blocks);
        [inputs addObject:src]; [outputs addObject:dst];
        MTLSize mip = MTLSizeMake(w,h,1);
        MTLOrigin zero = MTLOriginMake(0,0,0);
        [blit copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:dst_row sourceBytesPerImage:dst_bytes sourceSize:mip
                   toTexture:texture destinationSlice:67 destinationLevel:level destinationOrigin:zero];
        [blit copyFromTexture:texture sourceSlice:67 sourceLevel:level sourceOrigin:zero sourceSize:mip
                     toBuffer:dst destinationOffset:0 destinationBytesPerRow:dst_row destinationBytesPerImage:dst_bytes];
    }
    [blit endEncoding]; [tails commit]; [tails waitUntilCompleted];
    assert(!tails.error);
    for (NSUInteger i = 0; i < inputs.count; i++)
        assert(!memcmp(inputs[i].contents, outputs[i].contents, inputs[i].length));
    assert(!munmap(layer, full.layer_size));
    printf("Mips %d through %lu read back correctly after mapping the two different tails. Heap used %lu bytes.\n",
           tiled, desc.mipmapLevelCount - 1, heap.usedSize);
    return 0;
} }

