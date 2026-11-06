#import <Foundation/Foundation.h>
#include "game_profile_runtime.h"
#include "dmsh_chain.h"
#import "IndependentGameHost.h"
#ifdef DM_WEB_RUNTIME
#import "../../Engines/TonTonWebRuntime.h"
#endif
#ifdef DM_GTA_NATIVE
#import "TonTonGTAV.h"
#endif

// A missing UserData directory is normal for a newly imported cartridge:
// library_slot_paths creates it before boot. Never require an existing save.
static BOOL TonTonNonemptyFile(NSString *path) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileType] isEqual:NSFileTypeRegular] &&
        [attributes[NSFileSize] unsignedLongLongValue] > 0;
}
static BOOL TonTonDirectory(NSString *path) {
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory;
}
static NSDictionary *TonTonGameReadiness(NSString *titleID, NSString *gamesRoot, NSString *bundledRoot) {
    NSString *title = titleID.lowercaseString;
    NSString *frameworkManifest = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:
        [NSString stringWithFormat:@"DmGame%@.framework/game.manifest.json", title.uppercaseString]];
    NSData *manifestData = frameworkManifest ? [NSData dataWithContentsOfFile:frameworkManifest] : nil;
    id manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    NSString *chain = TonTonResourceChain(manifest, @"b-" DMSH_CHAIN);
#ifdef DM_WEB_RUNTIME
    if ([title isEqual:@"redalert2"]) {
        BOOL ready=TonTonWebRuntimeAvailable(title,[gamesRoot stringByAppendingPathComponent:title]);
        return @{@"ready":@(ready),@"code":ready?@"experimental_runtime":@"game_data_incomplete",
                 @"detail":ready?@"实验运行：完整版资源已导入，Wine 兼容仍在修复。":@"红警完整版资源或运行层尚未传入。"};
    }
#endif
#ifdef DM_GTA_NATIVE
    if ([title isEqual:@"gta5"]) {
        BOOL ready=TonTonGTAVAvailable([gamesRoot stringByAppendingPathComponent:title]);
        return @{@"ready":@(ready),@"code":ready?@"ready":@"game_data_incomplete",
                 @"detail":ready?@"可以打开":@"GTA5 的完整数据和着色器尚未传入。"};
    }
#endif
    const dm_game_profile *profile = dm_profile_find(title.UTF8String);
    NSString *code = nil, *detail = nil, *resourceRoot = nil;
    if (!profile) {
        code = @"host_missing"; detail = @"这款游戏的运行程序还未编入当前版本。";
    } else {
        NSString *local = [[gamesRoot stringByAppendingPathComponent:title] stringByAppendingPathComponent:@"Resources"];
        NSString *bundled = [bundledRoot stringByAppendingPathComponent:title];
        for (NSString *candidate in @[local, [bundled stringByAppendingPathComponent:@"Resources"], bundled]) {
            if (TonTonNonemptyFile([candidate stringByAppendingPathComponent:@"dm/shader_map.tsv"]) &&
                TonTonDirectory([candidate stringByAppendingPathComponent:@"msl"])) {
                resourceRoot = candidate; break;
            }
        }
        if (!resourceRoot) {
            code = @"shader_resources_missing"; detail = @"这款游戏的着色器资源尚未完整传入。";
        } else {
            NSString *stampPath = chain ? [resourceRoot stringByAppendingPathComponent:
                [NSString stringWithFormat:@"msl/%@/inputs.tsv", chain]] : nil;
            NSString *stamp = stampPath ? [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] : nil;
            NSString *row = [@"game\t" stringByAppendingString:title.uppercaseString];
            if (![[stamp componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] containsObject:row]) {
                code = @"shader_identity_mismatch"; detail = @"着色器版本与当前游戏程序不匹配，需补齐对应版本。";
            } else {
                NSString *user = [[gamesRoot stringByAppendingPathComponent:title] stringByAppendingPathComponent:@"UserData"];
                NSString *marker = [NSString stringWithUTF8String:profile->romfs_marker];
                BOOL romfs = NO;
                for (NSString *base in @[resourceRoot, user]) {
                    if (TonTonNonemptyFile([base stringByAppendingPathComponent:@"romfs.img"]) ||
                        TonTonNonemptyFile([[base stringByAppendingPathComponent:@"romfs"] stringByAppendingPathComponent:marker])) {
                        romfs = YES; break;
                    }
                }
                if (!romfs) {
                    code = @"game_data_incomplete"; detail = @"游戏主资源传输未完成；空文件不能启动。";
                }
            }
        }
    }
    return @{@"ready":@(code == nil), @"code":code ?: @"ready", @"detail":detail ?: @"可以打开",
             @"chain":chain ? [chain substringFromIndex:2] : @"", @"resources":resourceRoot ?: @""};
}
