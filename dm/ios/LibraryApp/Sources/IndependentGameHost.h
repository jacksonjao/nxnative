#pragma once

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <string.h>

// TonTon's signed module layout is distinct from upstream FH. Keep a
// separate ABI so a manifest cannot opt foreign code into this loader.
#define TONTON_INDEPENDENT_ABI @"tonton-independent-host-v1"
#define TONTON_GAME_HOST_VERSION 1

typedef struct {
    const char *(*start)(const char *const *argv, int argc, const void *image);
    void (*present)(void *window);
    void (*focus)(int event);
    void (*setCatalog)(void *(*catalog)(void *returnBlock));
} TonTonGameHost;

static BOOL TonTonIndependentManifest(NSDictionary *manifest) {
    return [manifest isKindOfClass:NSDictionary.class] && [manifest[@"loader"] isEqual:@"FH"] &&
           [manifest[@"tonton_host_abi"] isEqual:TONTON_INDEPENDENT_ABI];
}

static BOOL TonTonIndependentChain(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 14 ||
        ![value hasPrefix:@"b-"]) return NO;
    NSString *hash = [value substringFromIndex:2];
    NSCharacterSet *other = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [hash rangeOfCharacterFromSet:other].location == NSNotFound;
}

// Return the complete b-… directory name. A signed independent host owns
// its shader contract; the shared engine's upgrade must not change it.
static NSString *TonTonResourceChain(NSDictionary *manifest, NSString *sharedChain) {
    if (!TonTonIndependentManifest(manifest)) return sharedChain;
    NSString *chain = manifest[@"chain"];
    return TonTonIndependentChain(chain) ? chain : nil;
}

static void *TonTonImageSymbol(void *handle, const char *name, const void *image) {
    void *symbol = dlsym(handle, name);
    Dl_info owner = {0};
    return symbol && dladdr(symbol, &owner) && owner.dli_fbase == image ? symbol : NULL;
}

static BOOL TonTonReadIndependentHost(void *handle, const void *image, NSString *chain,
                                     TonTonGameHost *out) {
    const int *version = TonTonImageSymbol(handle, "dm_glue_version", image);
    const char *(*ownChain)(void) = TonTonImageSymbol(handle, "dm_glue_shader_chain", image);
    TonTonGameHost host = {
        .start = TonTonImageSymbol(handle, "dm_glue_start_game", image),
        .present = TonTonImageSymbol(handle, "dm_glue_present_game", image),
        .focus = TonTonImageSymbol(handle, "dm_glue_focus_event", image),
        .setCatalog = TonTonImageSymbol(handle, "dm_glue_set_catalog", image),
    };
    if (!version || *version != TONTON_GAME_HOST_VERSION || !ownChain ||
        !host.start || !host.present || !host.focus || !host.setCatalog) return NO;
    const char *builtChain = ownChain();
    if (!builtChain || !TonTonIndependentChain(chain) || strcmp(builtChain, chain.UTF8String)) return NO;
    *out = host;
    return YES;
}
