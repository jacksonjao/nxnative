// Apple TV front end: Metal and physical gamepads. The root is a GCEventViewController with controller events kept from UIKit while the game runs (as the tvos branch):
// a gamepad drives only the game, its buttons reach no UIKit press (tvOS reports an Xbox controller's X as Play/Pause, which opened the earlier Siri Remote panel), and Back stays in
// the game. There is no Siri Remote play scheme. Before the game starts, the settings screen (TVLauncher.swift) shows over the root; Play starts the game (dm_tv_start).
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <AVFAudio/AVFAudio.h>
#include "dm.h"
#include "front.h"
#include "dm_input.h"
#include "hle.h"
#include <math.h>

void front_tv_start(void);
int front_tv_ready(void);
int front_tv_preparing(void);
bool dm_show_launcher(void *view_controller, void (*done)(void));   // TVLauncher.swift: false = no launcher.json, or DM_LAUNCHER=0
static CAMetalLayer *tv_layer;
static UIViewController *tv_root;
static BOOL tv_active = YES;
static BOOL tv_settings_open;   // the settings screen shows: the game waits for Play
static void controller_read(GCExtendedGamepad *p) {
    if (!tv_active || tv_settings_open) { dm_pad_set(0, 0, 0, 0, 0); return; }
    uint64_t b = 0;
    // Nintendo's letters follow the physical positions used by the host's
    // existing controllers: bottom B, right A, left Y, top X.
    if (p.buttonA.pressed) b |= DM_BTN_B;
    if (p.buttonB.pressed) b |= DM_BTN_A;
    if (p.buttonX.pressed) b |= DM_BTN_Y;
    if (p.buttonY.pressed) b |= DM_BTN_X;
    if (p.leftShoulder.pressed) b |= DM_BTN_L;
    if (p.rightShoulder.pressed) b |= DM_BTN_R;
    if (p.leftTrigger.pressed) b |= DM_BTN_ZL;
    if (p.rightTrigger.pressed) b |= DM_BTN_ZR;
    if (p.leftThumbstickButton.pressed) b |= DM_BTN_LS;
    if (p.rightThumbstickButton.pressed) b |= DM_BTN_RS;
    if (p.buttonMenu.pressed) b |= DM_BTN_PLUS;
    if (p.buttonOptions.pressed) b |= DM_BTN_MINUS;
    if (p.dpad.left.pressed) b |= DM_BTN_LEFT;
    if (p.dpad.right.pressed) b |= DM_BTN_RIGHT;
    if (p.dpad.up.pressed) b |= DM_BTN_UP;
    if (p.dpad.down.pressed) b |= DM_BTN_DOWN;
    dm_pad_set(b, p.leftThumbstick.xAxis.value * 32767, p.leftThumbstick.yAxis.value * 32767,
               p.rightThumbstick.xAxis.value * 32767, p.rightThumbstick.yAxis.value * 32767);
}
static void controllers_update(void) {
    dm_pad_set(0, 0, 0, 0, 0);
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad) continue;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *p, GCControllerElement *element) {
            dispatch_async(dispatch_get_main_queue(), ^{ controller_read(p); });
        };
        controller_read(c.extendedGamepad); break;
    }
}
void front_tv_focus(int active) {
    tv_active = !!active;
    dm_pad_set(0, 0, 0, 0, 0); dm_input_set(0, 0, 0, 0, 0);
    if (tv_layer) { dm_focus_set(active ? 1 : 3); guest_clock_freeze_for(1, !active); dm_gfx_suspend(!active); }
    NSError *error = nil;
    [AVAudioSession.sharedInstance setActive:!!active error:&error];
    if (active) controllers_update();
}
@interface TVMetalView : UIView
@end
@implementation TVMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.framebufferOnly = NO; l.opaque = YES;
        l.drawableSize = CGSizeMake(1920, 1080);
    } return self;
}
@end
@interface TVRootVC : GCEventViewController
@property(strong, nonatomic) UILabel *preparationLabel;
@property(nonatomic) BOOL launcherAsked;
- (void)createGame;
@end
@implementation TVRootVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    self.controllerUserInteractionEnabled = NO;   // gamepads drive the game only (the settings screen turns it on while it shows)
    if (!front_tv_ready()) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 70, 70)];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.numberOfLines = 0; label.textColor = UIColor.whiteColor; label.textAlignment = NSTextAlignmentCenter;
        label.text = front_tv_preparing() ? @"Preparing game files…" : @"Game resources have not been staged for Apple TV yet.";
        self.preparationLabel = label; [self.view addSubview:label]; return;
    }
    [self createGame];
}
- (void)createGame {
    [self.preparationLabel removeFromSuperview]; self.preparationLabel = nil;
    if (tv_layer) return;
    TVMetalView *view = [[TVMetalView alloc] initWithFrame:self.view.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:view atIndex:0]; tv_layer = (CAMetalLayer *)view.layer;   // under the settings screen when it shows
    NSError *error = nil; AVAudioSession *audio = AVAudioSession.sharedInstance;
    [audio setCategory:AVAudioSessionCategoryPlayback error:&error];
    [audio setPreferredSampleRate:48000 error:&error];
    [audio setPreferredIOBufferDuration:0.005 error:&error];
    [audio setActive:YES error:&error];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { controllers_update(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { controllers_update(); }];
    controllers_update(); UIApplication.sharedApplication.idleTimerDisabled = YES;
}
static void launcher_done(void) { tv_settings_open = NO; controllers_update(); front_tv_start(); }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.launcherAsked) {   // once: the settings screen first, then the game (or straight to the game when the app has no settings)
        self.launcherAsked = YES;
        tv_settings_open = YES;
        if (dm_show_launcher((__bridge void *)self, launcher_done)) return;
        tv_settings_open = NO;
    }
    if (!tv_settings_open) front_tv_start();
}
@end
// TVLauncher.swift, after Play (the settings are in the environment): the screen leaves and controllers go back to the game
void dm_tv_start(void *settings_view_controller, void *root_view_controller, void (*done)(void)) {
    UIViewController *settings = (__bridge UIViewController *)settings_view_controller;
    GCEventViewController *root = (__bridge GCEventViewController *)root_view_controller;
    [settings willMoveToParentViewController:nil]; [settings.view removeFromSuperview]; [settings removeFromParentViewController];
    root.controllerUserInteractionEnabled = NO;
    done();
}
UIViewController *front_tv_root(void) { tv_root = [TVRootVC new]; return tv_root; }
void front_tv_resources_ready(NSString *failure) {
    TVRootVC *root = (TVRootVC *)tv_root;
    if (failure) {
        if (!root.preparationLabel) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(root.view.bounds, 70, 70)];
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            label.numberOfLines = 0; label.textColor = UIColor.whiteColor;
            label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
            label.textAlignment = NSTextAlignmentCenter;
            root.preparationLabel = label; [root.view addSubview:label];
        }
        root.preparationLabel.text = failure; return;
    }
    [root createGame];
    if (!tv_settings_open) front_tv_start();
}
void *front_metal_layer(void) { return (__bridge void *)tv_layer; }
int front_screen_max_fps(void) { return 60; }
void front_screen_match(int fps) { (void)fps; }
void front_run(void (*guest)(void)) { guest(); }
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return 0; }
double dm_brightness_now(void) { return -1; }
void front_save_failed(int err) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save failed"
            message:[NSString stringWithFormat:@"Progress was not saved (error %d).", err] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [tv_root presentViewController:alert animated:YES completion:nil];
    });
}
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    __block int accepted = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@(title ?: "")
            message:@(sub ?: "") preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = @(initial ?: ""); f.placeholder = @(guide ?: ""); }];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { text = alert.textFields.firstObject.text; accepted = 1; dispatch_semaphore_signal(done); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { dispatch_semaphore_signal(done); }]];
        [tv_root presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (accepted) snprintf(out, out_cap, "%s", text.UTF8String ?: "");
    return accepted;
}
