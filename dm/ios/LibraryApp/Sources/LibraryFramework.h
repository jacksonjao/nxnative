// NX2Apple Route C adapter for TonTon's iOS 16/17 host. The app's signed
// Frameworks directory carries code; Documents still owns resources and saves.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include "loader_image.h"
#include "game_profile_runtime.h"
#include "dmsh_chain.h"
#import "IndependentGameHost.h"

// This fork's signed __TEXT layout differs from newer upstream frameworks.
// Never accept a foreign framework merely because its title ID matches.
#define TONTON_FRAMEWORK_ABI @"tonton-signed-text-v1"
static NSString *TonTonFrameworkProblem(NSDictionary *manifest, NSString *title,
                                       NSArray<NSString *> *modules, NSString *os) {
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isEqual:@1])
        return @"游戏程序的清单缺失或格式不支持。";
    if ([manifest[@"unbound_resource_tables"] boolValue])
        return @"这款卡带还没有匹配当前资源的模块表，未启动。";
    if (![manifest[@"title_id"] isEqual:title.uppercaseString] ||
        ![manifest[@"modules"] isEqual:modules] || !modules.count)
        return @"游戏程序与所选卡带不匹配。";
    BOOL independent = TonTonIndependentManifest(manifest);
    if (independent ? !TonTonIndependentChain(manifest[@"chain"]) :
        (![manifest[@"chain"] isEqual:@"b-" DMSH_CHAIN] ||
         ![manifest[@"tonton_host_abi"] isEqual:TONTON_FRAMEWORK_ABI]))
        return @"游戏程序需要用当前游戏匣的兼容引擎重新构建。";
    NSString *fw=[@"DmGame" stringByAppendingFormat:@"%@.framework",title.uppercaseString];
    if (![manifest[@"framework"] isEqual:fw] || ![manifest[@"framework_executable"] isEqual:@"DmGame"] ||
        ![manifest[@"image_marker"] isEqual:@"dm_game_image_marker"] ||
        (!independent && ![manifest[@"loader"] isEqual:@"FR"]) || ![manifest[@"nro_count"] isEqual:@0])
        return @"游戏程序的加载格式尚不兼容。";
    NSString *min=manifest[@"min_os"];
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
    NSArray *parts=[min isKindOfClass:NSString.class]?[min componentsSeparatedByString:@"."]:nil;
    if (!parts.count || parts.count>3 || [min rangeOfCharacterFromSet:invalid].location!=NSNotFound)
        return @"游戏程序的系统版本格式无效。";
    for (NSString *part in parts) if (!part.length) return @"游戏程序的系统版本格式无效。";
    if ([os compare:min options:NSNumericSearch]==NSOrderedAscending)
        return [NSString stringWithFormat:@"这款游戏程序需要 iOS %@ 或更高版本。",min];
    return nil;
}

// nil framework means the existing embedded cartridge remains in use. Foreign
// downloaded code in Documents is never searched or dlopened.
static BOOL TonTonPrepareGameFramework(NSString *title, NSString **tables, NSString **failure,
                                       TonTonGameHost *host, const void **image) {
    *host = (TonTonGameHost){0};
    *image = NULL;
    NSString *fw=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:
        [NSString stringWithFormat:@"DmGame%@.framework",title.uppercaseString]];
    if (![NSFileManager.defaultManager fileExistsAtPath:fw]) return YES;
    const dm_game_profile *profile=dm_profile_find(title.UTF8String);
    NSMutableArray *modules=[NSMutableArray new];
    if (profile) for (size_t i=0;i<profile->nmod;i++) [modules addObject:@(profile->modules[i])];
    NSData *data=[NSData dataWithContentsOfFile:[fw stringByAppendingPathComponent:@"game.manifest.json"]];
    NSDictionary *manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSOperatingSystemVersion v=NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *os=[NSString stringWithFormat:@"%ld.%ld.%ld",(long)v.majorVersion,(long)v.minorVersion,(long)v.patchVersion];
    NSString *problem=TonTonFrameworkProblem(manifest,title,modules,os);
    NSString *dm=[fw stringByAppendingPathComponent:@"dm"];
    for (NSString *module in modules) for (NSString *ext in @[@"fixups.tsv",@"gates.tsv",@"obs.tsv",@"cuts.tsv"]) {
        NSString *name=[module stringByAppendingFormat:@".%@",ext];
        NSString *file=[dm stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:file]) problem=@"游戏程序的模块表不完整。";
        // Shader/CPU fixes and task-crash tracing must refer to the exact same
        // rewritten code. Never replace a game's active tables implicitly.
        if (![NSFileManager.defaultManager contentsEqualAtPath:file andPath:[*tables stringByAppendingPathComponent:name]])
            problem=@"游戏程序与现有资源的模块表不同，需要构建匹配版本。";
    }
    if (problem) { if(failure)*failure=problem;return NO; }
    NSString *executable=[fw stringByAppendingPathComponent:@"DmGame"];
    void *handle=dlopen(executable.fileSystemRepresentation,RTLD_LOCAL|RTLD_NOW|RTLD_FIRST);
    if (!handle) { if(failure)*failure=@"系统无法验证并加载这款游戏的签名程序。";return NO; }
    void *marker=dlsym(handle,"dm_game_image_marker");Dl_info info={0};
    if (!marker || !dladdr(marker,&info) || !info.dli_fbase || !info.dli_fname ||
        ![[@(info.dli_fname) stringByResolvingSymlinksInPath] isEqual:executable.stringByResolvingSymlinksInPath] ||
        ((const struct mach_header_64 *)info.dli_fbase)->filetype!=MH_DYLIB) {
        // Do not unload an image whose static initialization may have run.
        if(failure)*failure=@"这款游戏的签名模块身份不正确，未启动。";return NO;
    }
    if (TonTonIndependentManifest(manifest)) {
        if (!TonTonReadIndependentHost(handle, info.dli_fbase, manifest[@"chain"], host)) {
            if(failure)*failure=@"游戏自带引擎的接口或着色器版本不匹配。";
            return NO;
        }
        *image = info.dli_fbase;
        *tables = dm;
        return YES;
    }
    if (!dm_set_game_image_header(info.dli_fbase)) {
        if(failure)*failure=@"这款游戏的签名模块身份不正确，未启动。";
        return NO;
    }
    *tables=dm;
    fprintf(stderr,"boot: signed game framework %s, ABI tonton-signed-text-v1\n",executable.fileSystemRepresentation);
    return YES;
}
