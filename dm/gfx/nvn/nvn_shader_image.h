// Read an optional b-<chain>.img without unpacking it or changing the shader ABI.
#pragma once
#include "../../host/romfs_image.h"
#include <sys/mman.h>

typedef struct { const void *bytes; size_t size; void *base; size_t mapped; } nvn_shader_mapping;
static romfs_img *nvn_shader_image;

static const img_ent *nvn_shader_find(const romfs_img *image, const char *name) {
    size_t len = strlen(name);
    uint64_t lo = 1, hi = image->n;
    while (lo < hi) {
        uint64_t mid = lo + (hi - lo) / 2;
        const img_ent *entry = &image->e[mid];
        int cmp = memcmp(image->names + entry->name, name, MIN(entry->nlen, len));
        if (!cmp) cmp = (entry->nlen > len) - (entry->nlen < len);
        if (!cmp) return entry;
        if (cmp < 0) lo = mid + 1; else hi = mid;
    }
    return NULL;
}

static BOOL nvn_shader_image_open(NSString *folder, NSData *stamp) {
    if (!stamp.length || stamp.length > 4096) return NO;
    NSString *path = [folder stringByAppendingString:@".img"];
    romfs_img *image = romfs_image_open(path.fileSystemRepresentation);
    if (!image) return NO;
    const img_ent *entry = image->e[0].b == image->n - 1 && !image->damaged ?
        nvn_shader_find(image, "inputs.tsv") : NULL;
    unsigned char copy[4096] = {0};
    if (!entry || !entry->type || entry->b != stamp.length ||
        !romfs_image_read(image->fd, copy, stamp.length, (off_t)entry->a) ||
        memcmp(copy, stamp.bytes, stamp.length)) {
        romfs_image_close(image);
        return NO;
    }
    // The profile is fixed for this host. Archive updates publish a new inode for its next launch.
    nvn_shader_image = image;
    return YES;
}

static BOOL nvn_shader_image_map(NSString *folder, NSString *path, nvn_shader_mapping *out) {
    if (!nvn_shader_image || ![folder isEqualToString:path.stringByDeletingLastPathComponent]) return NO;
    NSString *name = path.lastPathComponent;
    const img_ent *entry = nvn_shader_find(nvn_shader_image, name.fileSystemRepresentation);
    if (!entry || !entry->type || !entry->b) return NO;
    if (name.length < 19) return NO;
    // Keep the entire shader family loose whenever a base override exists. Never mix
    // an incremental reflection file with a metallib (or variant) from a previous build.
    NSString *key = [name substringToIndex:16];
    NSString *base = [folder stringByAppendingPathComponent:[key stringByAppendingString:@"_b"]];
    struct stat st;
    if (!lstat(path.fileSystemRepresentation, &st) || errno != ENOENT ||
        !lstat([base stringByAppendingString:@".json"].fileSystemRepresentation, &st) || errno != ENOENT ||
        !lstat([base stringByAppendingString:@".metallib"].fileSystemRepresentation, &st) || errno != ENOENT) return NO;
    uint64_t delta = entry->a % (uint64_t)getpagesize();
    if (entry->b > SIZE_MAX - delta) return NO;
    size_t length = (size_t)(entry->b + delta);
    void *mapped = mmap(NULL, length, PROT_READ, MAP_SHARED, nvn_shader_image->fd, (off_t)(entry->a - delta));
    if (mapped == MAP_FAILED) return NO;
    *out = (nvn_shader_mapping){ (const char *)mapped + delta, (size_t)entry->b, mapped, length };
    return YES;
}

static NSData *nvn_shader_data(NSString *folder, NSString *path) {
    nvn_shader_mapping map;
    if (nvn_shader_image_map(folder, path, &map))
        return [[NSData alloc] initWithBytesNoCopy:(void *)map.bytes length:map.size deallocator:^(void *unused, NSUInteger length) {
            (void)unused; (void)length; munmap(map.base, map.mapped);
        }];
    return [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
}
