#ifdef DM_GTA_NATIVE
#import "TonTonGTAV.h"
#endif
// iOS App entry: set the environment (game files, saves, shader libraries), write the host log to Documents/log.txt, create the window (front_ios.m), then run the host's dm_main on a big-stack thread.
// The game files (RomFS) ship inside the App at <App>/romfs; Documents/romfs.img (one image, scripts/push_romfs.sh; its name in any letter case) or a Documents/romfs folder is also accepted (lets you swap them without reinstalling). The DLC folder aoc/ likewise: Documents/aoc, else <App>/aoc.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "game_profile.h"   // game profile constants (the RomFS marker path)
#include "front.h"
#include "romfs_image.h"
#import "DmCrashLogArchive.h"
#ifdef DM_LIBRARY_HOST
#import "../LibraryApp/Sources/LibraryRoot.h"
#import "../LibraryApp/Sources/LibraryFramework.h"
#ifdef DM_WEB_RUNTIME
#import "../Engines/TonTonWebRuntime.h"
#endif
#endif
#include "romfs_identity.h"
#include "player_env.h"
#include "frame_limit.h"
#ifndef DM_PLAYER_BUILD
#define DM_PLAYER_BUILD 0
#endif

extern char **environ;

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);

static char *g_argv[4]; static int g_argc;
#ifdef DM_LIBRARY_HOST
static TonTonGameHost g_independent_host;
static const void *g_independent_image;
#endif

// Documents/romfs.img, one RomFS image file (dm/tools/romfs_image.py, scripts/push_romfs.sh): only a complete one counts. Its index is written last and ends the file, so a copy cut off partway is skipped
static int romfs_image_complete(NSString *path) {
    romfs_img *m = romfs_image_open(path.fileSystemRepresentation);
    if (!m) {
        if (errno != ENOENT) fprintf(stderr, "[RED] boot: invalid RomFS image %s (errno=%d); trying the folders\n", path.fileSystemRepresentation, errno);
        return 0;
    }
    romfs_image_close(m); return 1;
}
// A build made with DM_COPY_ROMFS=NO carries <App>/romfs.id (dm/host/romfs_identity.h): only a Documents/romfs.img with that identity is used. No romfs.id (the default build): any complete image
static int romfs_identity_accepts(NSString *img, NSString *res) {
    romfs_id want, got;
    int rc = romfs_id_check([res stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation, img.fileSystemRepresentation, &want, &got);
    if (rc != ROMFS_ID_OK && rc != ROMFS_ID_NONE) fprintf(stderr, "[RED] boot: Documents/%s is not the image this build needs (verdict %d); not used\n", img.lastPathComponent.UTF8String, rc);
    return rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE;
}
// The images in Documents: romfs.img in any letter case, romfs.img itself first. The NSP script writes the image as RomFS.img (extract/<version>/RomFS.img) and the Mac's
// file system ignores letter case, but iOS's does not: a copy made through Finder or the Files app keeps the source's name, which an exact lookup of romfs.img never finds
static NSArray<NSString *> *romfs_document_images(NSString *doc) {
    NSMutableArray<NSString *> *imgs = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:doc error:nil])
        if ([n caseInsensitiveCompare:@"romfs.img"] == NSOrderedSame) [imgs addObject:[doc stringByAppendingPathComponent:n]];
    [imgs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL ea = [a.lastPathComponent isEqualToString:@"romfs.img"], eb = [b.lastPathComponent isEqualToString:@"romfs.img"];
        return ea != eb ? (ea ? NSOrderedAscending : NSOrderedDescending) : [a compare:b];
    }];
    return imgs;
}
static NSString *romfs_locate(NSString *doc, NSString *res) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *marker = [NSString stringWithUTF8String:DM_GAME_ROMFS_MARKER];
    for (NSString *img in romfs_document_images(doc)) {
        if (!romfs_image_complete(img) || !romfs_identity_accepts(img, res)) continue;
#ifndef DM_LIBRARY_HOST
        // A folder copy from before images is now dead weight of up to many GB (often cut off partway). Deleting its 300,000 files here took longer than iOS allows an app to start
        // (Tears of the Kingdom: killed on a black screen), so it is moved aside at once and deleted in the background, leftovers of an interrupted delete included
        NSString *old = [doc stringByAppendingPathComponent:@"romfs"], *tmp = NSTemporaryDirectory();
        if ([fm fileExistsAtPath:old] && [fm moveItemAtPath:old toPath:[tmp stringByAppendingPathComponent:[@"romfs-old-" stringByAppendingString:NSUUID.UUID.UUIDString]] error:nil])
            fprintf(stderr, "boot: Documents/romfs moved aside for deletion (Documents/%s replaces it)\n", img.lastPathComponent.UTF8String);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSFileManager *bfm = [NSFileManager new];
            for (NSString *n in [bfm contentsOfDirectoryAtPath:tmp error:nil]) if ([n hasPrefix:@"romfs-old-"]) [bfm removeItemAtPath:[tmp stringByAppendingPathComponent:n] error:nil];
        });
#endif
        return img;
    }
    NSString *bundledImage = [res stringByAppendingPathComponent:@"romfs.img"];
    NSString *documentFolder = [doc stringByAppendingPathComponent:@"romfs"];
    if ([fm fileExistsAtPath:[documentFolder stringByAppendingPathComponent:marker]]) return documentFolder;
    if (romfs_image_complete(bundledImage)) return bundledImage;
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [res stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:marker]]) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    return nil;
}

// The shared library keeps each game's read-only resources and writable data
// under one title-ID directory. A slot is selected before host preload; the
// single-game app continues to use its existing paths when no slot is set.
static int library_slot_paths(NSString **doc, NSString **res) {
    const char *raw = getenv("DM_LIBRARY_GAME_ID");
    if (!raw || !*raw) return 1;
    NSString *title = [[NSString stringWithUTF8String:raw] lowercaseString];
    NSCharacterSet *other = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if (title.length != 16 || [title rangeOfCharacterFromSet:other].location != NSNotFound) {
        fprintf(stderr, "[RED] boot: invalid library title ID\n"); return 0;
    }
    NSString *root = [[*doc stringByAppendingPathComponent:@"Games"] stringByAppendingPathComponent:title];
    NSString *user = [root stringByAppendingPathComponent:@"UserData"];
    NSString *resources = [root stringByAppendingPathComponent:@"Resources"];
    BOOL isDir = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bundled = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"GameResources"] stringByAppendingPathComponent:title];
    if (![fm fileExistsAtPath:[resources stringByAppendingPathComponent:@"dm/shader_map.tsv"]] &&
        [fm fileExistsAtPath:[bundled stringByAppendingPathComponent:@"dm/shader_map.tsv"]])
        resources = bundled;
    if (![fm fileExistsAtPath:resources isDirectory:&isDir] || !isDir ||
        ![fm fileExistsAtPath:[resources stringByAppendingPathComponent:@"dm"] isDirectory:&isDir] || !isDir ||
        ![fm fileExistsAtPath:[resources stringByAppendingPathComponent:@"msl"] isDirectory:&isDir] || !isDir ||
        ![fm fileExistsAtPath:[[resources stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"shader_map.tsv"]]) {
        fprintf(stderr, "[RED] boot: library slot %s is incomplete\n", title.UTF8String); return 0;
    }
    NSString *legacyTitle=[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMLibraryLegacyTitleID"];
    if([legacyTitle isKindOfClass:NSString.class]&&[legacyTitle.lowercaseString isEqualToString:title]&&
       [fm fileExistsAtPath:[*doc stringByAppendingPathComponent:@"save"]])
        user=*doc; // An in-place update of a single-game app keeps its existing save path.
    else if(![fm createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:nil]){
        fprintf(stderr, "[RED] boot: library slot user data is unavailable\n"); return 0;
    }
    *doc = user; *res = resources;
    fprintf(stderr, "boot: library slot %s\n", title.UTF8String);
    return 1;
}
// Add-on content (DLC): each DLC's RomFS image at <dir>/<index>.img (or a legacy <index>/ folder). Like the game files, Documents/aoc comes before <App>/aoc.
// A DM_AOC_DIR that is already set (env.txt, the launch environment) wins. The host mounts and counts the DLC from DM_AOC_DIR (hle_fs.c, hle_misc.c)
static void aoc_locate(NSString *doc, NSString *res) {
    if (getenv("DM_AOC_DIR")) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"aoc"], [res stringByAppendingPathComponent:@"aoc"]]) {
        BOOL dir = NO;
        if (![fm fileExistsAtPath:d isDirectory:&dir] || !dir) continue;
        setenv("DM_AOC_DIR", d.fileSystemRepresentation, 0);
        fprintf(stderr, "boot: DLC from %s\n", d.fileSystemRepresentation);
        return;
    }
}

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
// Why a slim build found no usable game files: the verdict on Documents/romfs.img (the first of romfs_document_images), in the log and for the screen (front_ios_boot_message). NULL when the build has no romfs.id
static char g_boot_message[640];
const char *front_ios_boot_message(void) { return g_boot_message[0] ? g_boot_message : NULL; }
// Why this device cannot run the games: its GPU has no BC texture formats, which the games' textures use and the host does not decompress (dm/gfx/tex/README.md; the A16 and older,
// GitHub issue #704), so the screen says so instead of Metal aborting at the game's first BC texture. NULL on a supported device. Called by startGame (front_ios.m) once the launcher has set
// its switches: this makes the process's first Metal device, and Metal reads MTL_HUD_ENABLED then; checked at launch, it kept the launcher's Performance HUD off (GitHub issue #840)
const char *front_ios_device_check(void) {
    static char msg[320]; static int done;
    if (done++) return msg[0] ? msg : NULL;
    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();   // the system default device, the one the graphics layers take (mtl_init repeats this check for the other routes)
    if (gpu.supportsBCTextureCompression) return NULL;
    // The traditional renderer includes BC decode/upload fallback on iOS 16/17.
    if (gpu) return NULL;
    snprintf(msg, sizeof msg, "This device's GPU (%s) cannot read BC-compressed textures, which the games use. It needs an iPhone 15 Pro or newer (A17 Pro chip or later) or an iPad with an M1 chip or later.",
             gpu ? gpu.name.UTF8String : "no Metal device");
    fprintf(stderr, "[RED] boot: %s\n", msg);
    return msg;
}
static void romfs_identity_report(NSString *doc) {
    romfs_id want, got;
    int rc = romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation,
                            (romfs_document_images(doc).firstObject ?: [doc stringByAppendingPathComponent:@"romfs.img"]).fileSystemRepresentation, &want, &got);
    if (rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE) return;
    romfs_id_message(rc, &want, &got, NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "<bundle ID>", g_boot_message, sizeof g_boot_message);
    fprintf(stderr, "[RED] boot: %s\n", g_boot_message);
}

static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath;
#ifdef DM_MULTI_GAME
    const char *selected = getenv("DM_LIBRARY_GAME_ID");
    if (!dm_profile_select(selected)) { fprintf(stderr, "[RED] boot: no registered library game selected\n"); return 0; }
#endif
    if (!library_slot_paths(&doc, &res)) return 0;
    NSString *romfs = romfs_locate(doc, res);
    if (!romfs) { fprintf(stderr, "[RED] boot: selected game files not found or incomplete\n"); return 0; }
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep game files and scratch data out of device backups (Documents is backed up by default; a RomFS placed there is many GB). Saves, logs and the pipeline list stay in the backup
    for (NSString *d in [@[@"romfs", @"aoc", @"temp"] arrayByAddingObjectsFromArray:[romfs_document_images(doc) valueForKey:@"lastPathComponent"]]) {
        NSURL *u = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:d]]; NSError *e = nil;
        if ([fm fileExistsAtPath:u.path] && ![u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) fprintf(stderr, "boot: %s could not be excluded from backup: %s\n", d.UTF8String, e.localizedDescription.UTF8String);
    }
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    // Keep a bounded history across repeated launches: the report being
    // investigated must survive the player's attempts to reopen the game.
    NSString *history = [doc stringByAppendingPathComponent:@"Logs"];
    [fm createDirectoryAtPath:history withIntermediateDirectories:YES attributes:nil error:nil];
    // Do not rotate away the evidence if a crash archive could not be made.
    if (!dm_archive_crash_log(log, history) || !dm_archive_crash_log(prev, history)) {
        NSLog(@"[RED] boot: cannot preserve crash log; existing reports retained");
        return 0;
    }
    if ([fm fileExistsAtPath:prev]) {
        NSString *last = [history stringByAppendingPathComponent:@"previous-4.txt"];
        [fm removeItemAtPath:last error:nil];
        for (int i = 3; i >= 1; i--) {
            NSString *a = [history stringByAppendingPathComponent:[NSString stringWithFormat:@"previous-%d.txt", i]];
            NSString *b = [history stringByAppendingPathComponent:[NSString stringWithFormat:@"previous-%d.txt", i + 1]];
            [fm moveItemAtPath:a toPath:b error:nil];
        }
        [fm moveItemAtPath:prev toPath:[history stringByAppendingPathComponent:@"previous-1.txt"] error:nil];
    }
    [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    else NSLog(@"[RED] boot: cannot open Documents log (errno %d)", errno);
    NSLog(@"boot: Documents writable=%d", [fm isWritableFileAtPath:doc]);
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over dm/env.txt in the bundle (put there by build_ipa.sh's DM_ENV_FILE)
    NSMutableArray<NSString *> *from_file = [NSMutableArray array], *from_launch = [NSMutableArray array];
    for (char **e = environ; *e; e++) {   // set at launch (Xcode, devicectl): before the env files, and the launcher keeps them
        const char *eq = strchr(*e, '='); NSString *k = eq && !strncmp(*e, "DM_", 3) ? [[NSString alloc] initWithBytes:*e length:(NSUInteger)(eq - *e) encoding:NSUTF8StringEncoding] : nil;
        if (k) [from_launch addObject:k];
    }
#if DM_PLAYER_BUILD
    // Player-facing choices belong to the launcher, including saved choices.
    // Neither old diagnostic files nor bundled defaults may lock those rows.
    NSMutableSet<NSString *> *launcher_keys = [NSMutableSet set];
    NSData *settings_data = [NSData dataWithContentsOfFile:[res stringByAppendingPathComponent:@"dm/launcher.json"]];
    NSDictionary *settings_file = settings_data ? [NSJSONSerialization JSONObjectWithData:settings_data options:0 error:nil] : nil;
    for (NSDictionary *row in settings_file[@"settings"]) if ([row[@"env"] isKindOfClass:NSString.class]) [launcher_keys addObject:row[@"env"]];
#endif
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
#if DM_PLAYER_BUILD
            if (dm_player_diagnostic_key(k.UTF8String) || [launcher_keys containsObject:k] ||
                ([launcher_keys containsObject:@"DM_METAL_HUD"] && [k isEqualToString:@"MTL_HUD_ENABLED"])) continue;
#endif
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); [from_file addObject:k]; fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    // A portable per-app dump path for diagnostics baked into an IPA. Resolve
    // it inside the app; an external installer need not write its container.
    if (getenv("DM_NVN_SHDUMP") && !strcmp(getenv("DM_NVN_SHDUMP"), "auto")) {
        NSString *dump = [doc stringByAppendingPathComponent:@"shader-dumps"];
        NSError *error = nil;
        if ([fm createDirectoryAtPath:dump withIntermediateDirectories:YES attributes:nil error:&error])
            setenv("DM_NVN_SHDUMP", dump.fileSystemRepresentation, 1);
        else { unsetenv("DM_NVN_SHDUMP"); fprintf(stderr, "[RED] boot: shader dump directory unavailable: %s\n", error.localizedDescription.UTF8String); }
    }
    // Default for every iPhone/iPad, independent of device/GPU generation.
    // Explicit launch/environment preferences can retain original game pacing.
    if (!getenv("DM_FRAME_LIMIT")) setenv("DM_FRAME_LIMIT", "unlimited", 0);
    if (dm_frame_limit_unlimited()) setenv("DM_PRESENT_LINK", "2", 1);
    setenv("DM_ENV_FILE_KEYS", [from_file componentsJoinedByString:@" "].UTF8String, 1);   // the launcher keeps what an env file set (LauncherSettings.swift)
    setenv("DM_ENV_LAUNCH_KEYS", [from_launch componentsJoinedByString:@" "].UTF8String, 1);   // and what the launch environment set (docs/frontends.md, Saved choices)
    front_hud_env();   // an env file's DM_METAL_HUD; nothing in this process makes a Metal device before startGame (front_ios.m), which applies the launcher's
    // Game language (nn::oe::GetDesiredLanguage, hle_oe.c): the one the IPA was packed with (the NSP script's LANGUAGE / --language → DMLanguage in Info.plist), unless an env file sets DM_LANG
    // (or the launcher, which replaces this default before the game starts)
    NSString *lang = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMLanguage"];
    if (!getenv("DM_LANG") && [lang isKindOfClass:NSString.class] && lang.length) setenv("DM_LANG", lang.UTF8String, 0);
    fprintf(stderr, "boot: game language %s\n", getenv("DM_LANG") ?: "en-US");
    fprintf(stderr, "boot: game files %s\n", romfs.fileSystemRepresentation);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 0);
    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    NSString *moduleTables=dm;
#ifdef DM_LIBRARY_HOST
    NSString *frameworkError=nil;
    if (!TonTonPrepareGameFramework(@(getenv("DM_LIBRARY_GAME_ID")),&moduleTables,&frameworkError,
                                    &g_independent_host,&g_independent_image)) {
        fprintf(stderr,"[RED] boot: %s\n",frameworkError.UTF8String);return 0;
    }
#endif
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 0);
    setenv("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 0);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 0);   // Shared-font stand-ins (standard.ttf / nintendo_ext.ttf): iOS lacks the macOS font path
    aoc_locate(doc, res);   // add-on content: Documents/aoc, else <App>/aoc; an empty Documents/aoc explicitly selects no DLC
    NSString *pso = [res stringByAppendingPathComponent:@"pso"];   // the pipeline archive made offline (build_ipa.sh, dm/gfx/tools/pso_offline.py): the shader pairs' bases, which the device then does not build
    if ([fm fileExistsAtPath:pso]) setenv("DM_PSO_BUNDLE", pso.fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(moduleTables.fileSystemRepresentation); g_argc = 2;
#ifdef DM_LIBRARY_HOST
    if (g_independent_host.start) return 1;   // Start after the library applies per-game settings.
#endif
    dm_host_preload_start(g_argc, g_argv);   // Module tables / relocation / takeover run early in the background, in parallel with UIKit startup (and the launcher: the settings it sets are read when the game starts)
    return 1;
}
static int g_boot_ok;

static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main returned %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (once++ || !g_boot_ok) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

static void focus_game(int event) {
#ifdef DM_LIBRARY_HOST
    if (g_boot_ok && g_independent_host.focus) {
        g_independent_host.focus(event);
        return;
    }
#endif
    front_ios_focus_event(event);
}

@class SceneDelegate;
@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    BOOL tv = [s.role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:tv ? @"TV" : @"Default" sessionRole:s.role];
    c.delegateClass = NSClassFromString(tv ? @"DmTVSceneDelegate" : @"SceneDelegate");
    return c;
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
#ifdef DM_LIBRARY_HOST
    __weak SceneDelegate *weakSelf=self;
    self.window.rootViewController=TonTonLibraryController(^(NSString *titleID){
        SceneDelegate *owner=weakSelf;
        if(!owner||g_boot_ok)return;
#ifdef DM_WEB_RUNTIME
        if([titleID isEqual:@"redalert2"]){
            NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            UIViewController *game=TonTonWebRuntimeController(titleID,[documents stringByAppendingPathComponent:@"Games/redalert2"]);
            if(game){g_boot_ok=1;owner.window.rootViewController=game;}
            return;
        }
#endif
#ifdef DM_GTA_NATIVE
        if([titleID isEqual:@"gta5"]){
            NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            UIViewController *library=owner.window.rootViewController;
            UIViewController *game=TonTonGTAVCreateControllerWithReturn([documents stringByAppendingPathComponent:@"Games/gta5"],^{
                SceneDelegate *current=weakSelf;
                if(!current)return;
                g_boot_ok=0;
                current.window.rootViewController=library;
            });
            if(game){g_boot_ok=1;owner.window.rootViewController=game;}
            return;
        }
#endif
        setenv("DM_LIBRARY_GAME_ID",titleID.UTF8String,1);
        if(!boot_env()){
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"卡带暂时无法启动" message:@"请检查该游戏的资源是否已完整移入游戏匣。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [owner.window.rootViewController presentViewController:alert animated:YES completion:nil];return;
        }
        TonTonApplyGlobalSettings(titleID);
        if (g_independent_host.start) {
            const char *error = g_independent_host.start((const char *const *)g_argv, g_argc, g_independent_image);
            if (error) {
                fprintf(stderr,"[RED] boot: independent game host: %s\n",error);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"卡带暂时无法启动"
                    message:@"游戏自带引擎未能启动。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [owner.window.rootViewController presentViewController:alert animated:YES completion:nil];
                g_independent_host = (TonTonGameHost){0};
                return;
            }
            g_boot_ok=1;
            g_independent_host.present((__bridge void *)owner.window);
            return;
        }
        g_boot_ok=1;
        owner.window.rootViewController=front_ios_root();
    });
#else
    self.window.rootViewController = front_ios_root();
#endif
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s {
#ifdef DM_GTA_NATIVE
    if(TonTonGTAVIsActive()){TonTonGTAVFocus(0,0);return;}
#endif
 focus_game(0); }
- (void)sceneDidEnterBackground:(UIScene *)s {
#ifdef DM_GTA_NATIVE
    if(TonTonGTAVIsActive()){TonTonGTAVFocus(0,1);return;}
#endif
 focus_game(1); }
- (void)sceneWillEnterForeground:(UIScene *)s {
#ifdef DM_GTA_NATIVE
    if(TonTonGTAVIsActive()){TonTonGTAVFocus(0,0);return;}
#endif
 focus_game(2); }
- (void)sceneDidBecomeActive:(UIScene *)s {
#ifdef DM_GTA_NATIVE
    if(TonTonGTAVIsActive()){TonTonGTAVFocus(1,0);return;}
#endif
 focus_game(3); }
@end

int main(int argc, char **argv) {
#ifndef DM_LIBRARY_HOST
    @autoreleasepool { g_boot_ok = boot_env(); }
#endif
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
