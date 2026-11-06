// Link only into a self-hosted game framework, never the shared launcher.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include "IndependentGameHost.h"
#include "dmsh_chain.h"
#include "front.h"
#include "loader_image.h"
#ifdef DM_MULTI_GAME
#include "game_profile_runtime.h"
#endif

#define DM_EXPORT __attribute__((used, visibility("default")))
DM_EXPORT const int dm_glue_version = TONTON_GAME_HOST_VERSION;
#ifndef DM_INDEPENDENT_SHADER_CHAIN
#define DM_INDEPENDENT_SHADER_CHAIN DMSH_CHAIN
#endif
DM_EXPORT const char *dm_glue_shader_chain(void) { return "b-" DM_INDEPENDENT_SHADER_CHAIN; }

int dm_main(int argc, char **argv);
UIViewController *front_ios_root(void);
void front_ios_audio_session(void);
void front_ios_focus_event(int event);
static char *game_argv[3];
static BOOL prepared;
static void *(*game_catalog)(void *returnBlock);

DM_EXPORT void dm_glue_set_catalog(void *(*catalog)(void *returnBlock)) {
    game_catalog = catalog;
}

UIViewController *TonTonInGameCatalogController(dispatch_block_t returned) {
    return game_catalog ? (__bridge_transfer UIViewController *)game_catalog((__bridge void *)returned) : nil;
}

DM_EXPORT const char *dm_glue_start_game(const char *const *argv, int argc, const void *image) {
    if (prepared || argc != 2 || !argv || !argv[0] || !argv[1] || !image)
        return "Invalid or repeated game start.";
#ifdef DM_INDEPENDENT_GAME_TITLE
    const char *title = getenv("DM_LIBRARY_GAME_ID");
    if (!title || strcasecmp(title, DM_INDEPENDENT_GAME_TITLE))
        return "The selected game is not the one embedded in this engine.";
#ifdef DM_MULTI_GAME
    if (!dm_profile_select(DM_INDEPENDENT_GAME_TITLE)) return "The game's engine profile is missing.";
#endif
#endif
    game_argv[0] = strdup(argv[0]);
    game_argv[1] = strdup(argv[1]);
    if (!game_argv[0] || !game_argv[1] || !dm_set_game_image_header(image)) {
        free(game_argv[0]); free(game_argv[1]);
        game_argv[0] = game_argv[1] = NULL;
        return "Cannot initialize the game's signed module image.";
    }
    front_hud_env();
    dm_host_preload_start(2, game_argv);
    prepared = YES;
    return NULL;
}

DM_EXPORT void dm_glue_present_game(void *window) {
    if (!prepared || !window) return;
    UIWindow *target = (__bridge UIWindow *)window;
    UIViewController *game = front_ios_root();
    target.rootViewController = game;
    if (@available(iOS 16.0, *)) {
        [game setNeedsUpdateOfSupportedInterfaceOrientations];
        [target.windowScene requestGeometryUpdateWithPreferences:
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape]
            errorHandler:^(NSError *error) {
                fprintf(stderr, "boot: independent game landscape request: %s\n", error.localizedDescription.UTF8String);
            }];
    }
}

DM_EXPORT void dm_glue_focus_event(int event) {
    if (prepared) front_ios_focus_event(event);
}

static void *game_thread(void *arg) {
    (void)arg;
    static char alternate[65536];
    stack_t stack = {.ss_sp = alternate, .ss_size = sizeof alternate};
    sigaltstack(&stack, NULL);
    int status = dm_main(2, game_argv);
    fprintf(stderr, "boot: independent game returned %d\n", status);
    return NULL;
}

void front_ios_boot(void) {
    static BOOL started;
    if (!prepared || started) return;
    front_ios_audio_session();
    pthread_attr_t attr;
    if (pthread_attr_init(&attr)) return;
    pthread_t thread;
    int error = pthread_attr_setstacksize(&attr, 64u << 20);
    if (!error) error = pthread_create(&thread, &attr, game_thread, NULL);
    pthread_attr_destroy(&attr);
    if (error) {
        fprintf(stderr, "[RED] boot: independent game thread: %s\n", strerror(error));
        return;
    }
    started = YES;
    pthread_detach(thread);
}

int front_ios_boot_ok(void) { return prepared; }
const char *front_ios_boot_message(void) { return NULL; }
const char *front_ios_device_check(void) { return NULL; }
int dm_locate_game_data(void) {
    const char *romfs = getenv("DM_ROMFS");
    struct stat st;
    return romfs && !stat(romfs, &st);
}
bool dm_show_launcher(void *controller, void (*done)(void)) {
    (void)controller; (void)done;
    return false;
}
