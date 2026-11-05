// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone), with a separate 8-way D-pad immediately inward;
//     the A (bottom) B (right) X (left) Y (top) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   Both 2D and 3D have camera drag on empty space in the right half: a right stick that is not drawn, centred where the touch lands, with the centre dragged along past the stick radius.
//   3D (full, Pro Controller style): everything in 2D (left stick, D-pad and diamond keep their place and size), plus L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then the camera for an unclaimed touch in the right half. Ownership stays with its original control until release/cancellation; sliding a camera finger over ABXY never presses a skill.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode). Tap layout keeps direct game touches everywhere except its layout selector.
//   Controllers and keyboards always hide the pad. DM_PAD_KEEP_TOUCH=1 keeps touch visible beside a mouse only. Mouse input follows the same policy; without the switch a direct finger can reclaim touch controls when no controller/keyboard is present. Backbone maps by printed letters; other physical controllers retain Nintendo positional mapping.
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include <strings.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#if defined(DM_LIBRARY_HOST) && !defined(DM_MULTI_GAME)
#error "The game library must use the generated multi-game profile header."
#endif

#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include <stdatomic.h>
#include "DmFaceLayout.h"
#include "DmControllerPolicy.h"
#include "DmRacingTouch.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME, C_RUN, C_AIM, C_GAS, C_BRAKE };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_input_active = YES;
static uint64_t g_input_epoch;
static uint64_t g_touch_btn, g_pad_btn, g_key_btn, g_shake_btn;
static uint64_t g_touch_face, g_touch_native;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry, g_key_lx, g_key_ly, g_key_rx, g_key_ry, g_mouse_rx, g_mouse_ry;
static BOOL g_key_w, g_key_a, g_key_s, g_key_d, g_key_left, g_key_up, g_key_right, g_key_down;
static BOOL g_key_j, g_key_enter, g_key_k, g_key_backspace;
static BOOL g_key_z, g_key_c;

static BOOL nfs_keyboard(void) {
#ifdef DM_MULTI_GAME
    const char *id = getenv("DM_LIBRARY_GAME_ID");
#else
    const char *id = DM_GAME_ID;
#endif
    return id && strcasecmp(id, "010029B0118E8000") == 0;
}
static BOOL g_shift_left, g_shift_right;
static BOOL g_command_left, g_command_right;
static uint64_t g_run_button, g_aim_button;   // native Npad shortcuts, independent of visible face letters
static double g_mouse_deadline, g_raw_mouse_time;
static void read_mouse(float dx, float dy);
static void clear_mouse(void);
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    // GC handlers may still deliver global mouse/controller changes while a
    // visible Stage Manager card is inactive. Never turn its camera off-focus.
    if (!g_input_active) { dm_input_set(0, 0, 0, 0, 0); pthread_mutex_unlock(&g_mu); return; }
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_key_lx, g_key_ly)) { lx = g_key_lx; ly = g_key_ly; }
    if (tilted(g_key_rx, g_key_ry)) { rx = g_key_rx; ry = g_key_ry; }
    if (tilted(g_mouse_rx, g_mouse_ry)) { rx = g_mouse_rx; ry = g_mouse_ry; }
    uint64_t run = (g_shift_left || g_shift_right) ? g_run_button : 0;
    uint64_t aim = (g_command_left || g_command_right) ? g_aim_button : 0;
    // Keep A/B/X/Y identical in menus, exploration and battle. Repositioning
    // our virtual controls must never change keyboard or touch button meaning.
    g_touch_native = g_touch_face | g_touch_btn;
    uint64_t keyboard = g_key_btn;
    dm_input_set(g_touch_native | keyboard | g_shake_btn | run | aim, lx, ly, rx, ry);
    static int records;
    static uint64_t previousTouch, previousKey;
    if (records < 128 && (g_touch_face != previousTouch || (g_key_btn & 15) != previousKey)) {
        const char *diag = getenv("DM_TOUCH_DIAG");
        if (diag && atoi(diag)) {
            LOG("[face-input] touch=%#llx -> %#llx keyboard=%#llx -> %#llx",
                (unsigned long long)g_touch_face, (unsigned long long)(g_touch_native & 15),
                (unsigned long long)(g_key_btn & 15), (unsigned long long)(keyboard & 15));
            records++;
        }
    }
    previousTouch = g_touch_face; previousKey = g_key_btn & 15;
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 0.5,                                 // camera drag area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
static NSString *dm_layout_preference_key(void) {
#ifdef DM_LIBRARY_HOST
    const char *title = getenv("DM_LIBRARY_GAME_ID");
    if (title && *title) return [k_layout_key stringByAppendingFormat:@".%s", title];
#endif
    return k_layout_key;
}
int dm_opmode(void);   // hle_oe.c: 0 = handheld

static BOOL pad_env_on(const char *name) {
    const char *value = getenv(name);
    return value && atoi(value) != 0;
}
static BOOL pad_force_full(void) { return pad_env_on("DM_PAD_FORCE_FULL"); }
static BOOL pad_keep_touch(void) { return pad_env_on("DM_PAD_KEEP_TOUCH"); }

@interface DmGamepad : UIView
- (void)mouseMotionX:(float)dx y:(float)dy raw:(BOOL)raw;
- (void)updateSkillFaceLayout;
@end
static __weak DmGamepad *g_view;
void dm_gamepad_active(void);
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    dm_face_layout _faceLayout;                  // shared visible/hit-test geometry; native bits remain A/B/X/Y
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;
    unsigned _hapticSticks;
    CAShapeLayer *_run; CATextLayer *_runLabel; BOOL _runHeld;
    CAShapeLayer *_aim; CATextLayer *_aimLabel; BOOL _aimHeld, _aimLatched;
    CAShapeLayer *_throw; CATextLayer *_throwLabel; BOOL _throwEnabled;
    CAShapeLayer *_gas, *_brake; CATextLayer *_gasLabel, *_brakeLabel;
    BOOL _racingTouch, _gasLatchedShown; dm_racing_touch _racing;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer; the default external-input policy may hide it while the view stays active for game touches
    BOOL _padOff;                                  // when the policy hides the pad, every touch goes to the game
    BOOL _controllerOrKeyboard, _touchPreferred;    // direct fingers can take over from an idle persistent mouse
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    CGPoint _hoverLast;
    BOOL _hoverValid;
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS; }   // stick clicks are shown only in the 3D layout; directions are always available

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        // Generic opt-in: games choose their own existing logical run button.
        // No synthetic skill press is generated by moving or dragging a stick.
        const char *run = getenv("DM_RUN_BUTTON"); g_run_button = 0;
        static const char *runNames[] = {"A", "B", "X", "Y", "LS", "RS"};
        for (int b = 0; run && b < 6; b++) if (!strcmp(run, runNames[b])) g_run_button = 1ull << b;
        _run = shape(_controls); _runLabel = label(_run, @"奔跑");
        const char *aim = getenv("DM_AIM_ZL"); g_aim_button = aim && atoi(aim) ? DM_BTN_ZL : 0;
        _aim = shape(_controls); _aimLabel = label(_aim, @"瞄准");
        // A left-hand alias of the native right trigger. Unlike the ZL focus
        // toggle this is momentary: left hold prepares, right drag aims, left
        // release throws. It shares C_BTN ownership with the original ZR.
        _throwEnabled = pad_env_on("DM_THROW_ZR");
        _throw = shape(_controls); _throwLabel = label(_throw, @"投掷");
        _racingTouch = nfs_keyboard();
        _gas = shape(_controls); _gasLabel = label(_gas, @"油门锁");
        _brake = shape(_controls); _brakeLabel = label(_brake, @"刹车");
        if (g_run_button) LOG("front end: Run touch button and either Shift alias native %s independently of visible face labels", run);
        if (g_aim_button) LOG("front end: tap Aim toggles ZL; hold either Command to aim; release/focus loss clears modifier input");
        if (_throwEnabled) LOG("front end: left Throw holds native ZR; right camera drag stays independent; release throws");
        LOG("front end: native A/B/X/Y unchanged; virtual face geometry alone can follow the original battle skill HUD");
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:dm_layout_preference_key()];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        // A profile may require the complete controller surface. This also
        // upgrades an existing install whose saved preference predates newly
        // exposed controls, while leaving every native button bit unchanged.
        if (pad_force_full()) l = 1;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCKeyboardDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCKeyboardDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCMouseDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(inputDevicesChanged:) name:GCMouseDidDisconnectNotification object:nil];
        pads_start();
        [self inputDevicesChanged:nil];
        UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(pointerMoved:)];
        hover.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        hover.cancelsTouchesInView = NO;
        [self addGestureRecognizer:hover];
        UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadScrolled:)];
        scroll.allowedTouchTypes = @[];  // scroll events only; never steal a finger from either stick
        scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;
        scroll.cancelsTouchesInView = NO;
        [self addGestureRecognizer:scroll];
        __weak DmGamepad *weakSelf = self;
        NSTimer *releaseTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            pthread_mutex_lock(&g_mu);
            BOOL expired = g_mouse_deadline > 0 && CACurrentMediaTime() >= g_mouse_deadline;
            if (expired) { g_mouse_rx = g_mouse_ry = 0; g_mouse_deadline = 0; }
            pthread_mutex_unlock(&g_mu);
            if (expired) publish();
            [weakSelf updateSkillFaceLayout];   // the main run loop owns geometry and touch routing together
        }];
        [NSRunLoop.mainRunLoop addTimer:releaseTimer forMode:NSRunLoopCommonModes];
        LOG("front end: trackpad raw/hover/scroll camera input with bounded release timer");
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)didMoveToWindow { [super didMoveToWindow]; if (self.window) [self becomeFirstResponder]; }
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (!g_input_active) return @[];
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray array];
    // Keep arrows inside the game even when UIKit would otherwise use them for
    // focus movement. GCKeyboard still supplies the matching down/up events.
    for (NSString *key in @[UIKeyInputUpArrow, UIKeyInputDownArrow, UIKeyInputLeftArrow, UIKeyInputRightArrow]) {
        UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key modifierFlags:0 action:@selector(gameCommand:)];
        command.wantsPriorityOverSystemBehavior = YES;
        [commands addObject:command];
    }
    // Consume only game combinations, in particular Command-W, rather than
    // allowing the system to close a Stage Manager window while moving.
    if (g_aim_button) for (NSString *key in @[@"w", @"a", @"s", @"d", @"u", @"i", @"j", @"k", @"l", @"q", @"e", @"z", @"c", UIKeyInputUpArrow, UIKeyInputDownArrow, UIKeyInputLeftArrow, UIKeyInputRightArrow])
        for (NSNumber *extra in @[@0, @(UIKeyModifierShift)]) {
            UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key modifierFlags:UIKeyModifierCommand | extra.unsignedIntegerValue action:@selector(gameCommand:)];
            command.wantsPriorityOverSystemBehavior = YES;
            [commands addObject:command];
        }
    return commands;
}
- (void)gameCommand:(UIKeyCommand *)command { (void)command; }   // GCKeyboard supplies down/up; do not synthesize another press here
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap;
    _run.hidden = _tap || !g_run_button;
    _aim.hidden = _tap || !g_aim_button;
    _throw.hidden = _tap || !_throwEnabled;
    _gas.hidden = _brake.hidden = _tap || !_racingTouch;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    int l = pad_force_full() ? 1 : _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:dm_layout_preference_key()];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    dm_face_offset offset = dm_face_layout_offset(&_faceLayout, (unsigned)b);
    return CGPointMake(c.x + offset.x * g, c.y + offset.y * g); }
- (void)updateSkillFaceLayout {
    if (!NSThread.isMainThread) return;
    // Freeze the entire diamond until every face-owned finger releases, even
    // if a held finger slides into a gap. A UI transition cannot change its key.
    if (!dm_face_layout_update(&_faceLayout, dm_za_skill_layout_active(), _faceOf.count != 0)) return;
    [self setNeedsLayout]; [self layoutIfNeeded];
    LOG("front end: virtual face geometry=%s; native button functions unchanged",
        _faceLayout.skill ? "skill A right B bottom X top Y left" : "normal A bottom B right X left Y top");
}
- (CGPoint)stickHome { CGRect s = self.corner; return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u); }   // the left stick's ring centre
- (CGPoint)runCenter { CGPoint c = self.stickHome; return CGPointMake(c.x, c.y - 145 * self.u); }
- (CGPoint)aimCenter { CGPoint c = self.runCenter; return CGPointMake(c.x + 70 * self.u, c.y); }
- (CGPoint)throwCenter {
    CGPoint c = self.runCenter;
    // Reuse the closest free shortcut slot above the left stick.
    if (g_run_button) c.x += (g_aim_button ? 140 : 70) * self.u;
    return c;
}
- (CGRect)gasRect {
    CGRect s = self.corner; CGFloat u = self.u;
    return CGRectMake(CGRectGetMaxX(s) - 169 * u, CGRectGetMaxY(s) - 235 * u, 72 * u, 44 * u);
}
- (CGRect)brakeRect { return CGRectOffset(self.gasRect, 82 * self.u, 0); }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO, run = NO, aim = NO, gas = NO, brake = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    for (UITouch *t in _owner) {
        int c = [_owner objectForKey:t].unsignedLongLongValue & 0xff;
        if (c == C_RUN) run = YES;
        if (c == C_AIM) aim = YES;
        if (c == C_GAS) gas = YES;
        if (c == C_BRAKE) brake = YES;
    }
    if (run) btn |= g_run_button;
    if (aim || _aimLatched) btn |= g_aim_button;
    if (_racingTouch) {
        brake = brake || (btn & DM_BTN_ZL) != 0;
        if (brake) btn &= ~DM_BTN_ZR;
        btn |= dm_racing_touch_buttons(&_racing, gas, brake);
    }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld || run != _runHeld || aim != _aimHeld || _gasLatchedShown != _racing.throttle_latched;
    _gasLatchedShown = _racing.throttle_latched;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    _runHeld = run;
    _aimHeld = aim;
    pthread_mutex_lock(&g_mu);
    g_touch_face = face; g_touch_btn = dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    pthread_mutex_lock(&g_mu); uint64_t nativeTouch = g_touch_native; pthread_mutex_unlock(&g_mu);
    // Observe actual UIKit ownership, rather than a separate input model.
    static int diagnostic = -1, records; static unsigned prior; static uint64_t priorButtons;
    if (diagnostic < 0) { const char *e = getenv("DM_TOUCH_DIAG"); diagnostic = e && atoi(e) != 0; }
    unsigned state = (_stick[0] != nil) | ((_stick[1] != nil) << 1) |
        ((ax[0] != 0 || ax[1] != 0) << 2) | ((ax[2] != 0 || ax[3] != 0) << 3);
    if (diagnostic && records < 256 && (state != prior || (face | dpad | btn) != priorButtons)) {
        LOG("[touch-input] owners=%lu left=%d right=%d buttons=%#llx native=%#llx axes=%d,%d,%d,%d", (unsigned long)_owner.count,
            _stick[0] != nil, _stick[1] != nil, (unsigned long long)(face | dpad | btn),
            (unsigned long long)nativeTouch, ax[0], ax[1], ax[2], ax[3]);
        records++;
    }
    prior = state; priorButtons = face | dpad | btn;
    BOOL stick = _stick[0] != nil;
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) if (t.type == UITouchTypeDirect && _padOff && !_controllerOrKeyboard) {
        // A persistent virtual mouse is not evidence that the player still has
        // a keyboard cover attached. Let the first finger choose touch input.
        [self reset]; clear_mouse();
        _touchPreferred = YES; _padOff = NO; _controls.hidden = NO;
        LOG("front end: direct touch restored controls while only mice remain connected");
        break;
    }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (t.type == UITouchTypeIndirectPointer) continue;
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self]; int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if (!_tap && _racingTouch && CGRectContainsPoint(self.gasRect, p)) {
            [_owner setObject:@(C_GAS) forKey:t]; continue;
        }
        if (!_tap && _racingTouch && CGRectContainsPoint(self.brakeRect, p)) {
            [_owner setObject:@(C_BRAKE) forKey:t]; continue;
        }
        if (!_tap && _throwEnabled && dist(p, self.throwCenter) <= 34 * self.u) {
            [_owner setObject:@(C_BTN | (uint64_t)B_ZR << 8) forKey:t]; continue;
        }
        if (!_tap && g_run_button && dist(p, self.runCenter) <= 28 * self.u) { [_owner setObject:@(C_RUN) forKey:t]; continue; }
        if (!_tap && g_aim_button && dist(p, self.aimCenter) <= 28 * self.u) { [_owner setObject:@(C_AIM) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        // Camera is available in Simple too: detaching a keyboard restores the
        // saved layout, and Simple previously routed every blank-area drag to
        // the game's touchscreen instead of its right-stick camera. Controls
        // above always claim first; no gesture recognizer competes for fingers.
        if (kind == C_NONE && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO, game = NO;
    if (!ended) dm_racing_touch_reset(&_racing);
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_GAS && CGRectContainsPoint(self.gasRect, [t locationInView:self]))
            dm_racing_touch_tap(&_racing);
        if ((v & 0xff) == C_AIM) {
            if (ended && dist([t locationInView:self], self.aimCenter) <= 28 * self.u) _aimLatched = !_aimLatched;
            else if (!ended) _aimLatched = NO;
        }
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    [self updateSkillFaceLayout];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { _hoverValid = NO; _aimLatched = NO; dm_racing_touch_reset(&_racing); [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; [self updateSkillFaceLayout]; }

// Some keyboard-cover trackpads deliver UIKit pointer/scroll events without
// appearing in GCMouse.mice. Prefer recent raw motion to avoid double counting.
- (void)pointerMoved:(UIHoverGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) { _hoverValid = NO; return; }
    CGPoint p = [g locationInView:self];
    if (_hoverValid && g.state == UIGestureRecognizerStateChanged) {
        pthread_mutex_lock(&g_mu); BOOL raw = CACurrentMediaTime() - g_raw_mouse_time < 0.1; pthread_mutex_unlock(&g_mu);
        if (!raw) { [self mouseMotionX:(float)(p.x - _hoverLast.x) y:(float)(_hoverLast.y - p.y) raw:NO];
            static int once; if (!once++) LOG("front end: UIKit trackpad hover is driving the camera"); }
    }
    _hoverLast = p; _hoverValid = YES;
}
- (void)trackpadScrolled:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) { clear_mouse(); return; }
    CGPoint d = [g translationInView:self]; [g setTranslation:CGPointZero inView:self];
    if (d.x || d.y) { [self mouseMotionX:(float)d.x y:(float)-d.y raw:NO];
        static int once; if (!once++) LOG("front end: two-finger trackpad scroll is driving the camera"); }
}

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    setPath(_run, circlePath(self.runCenter, 25 * u)); placeLabel(_runLabel, self.runCenter, 14 * u);
    setPath(_aim, circlePath(self.aimCenter, 25 * u)); placeLabel(_aimLabel, self.aimCenter, 14 * u);
    setPath(_throw, circlePath(self.throwCenter, 30 * u)); placeLabel(_throwLabel, self.throwCenter, 14 * u);
    CGRect gas = self.gasRect, brake = self.brakeRect;
    setPath(_gas, CGPathCreateWithRoundedRect(gas, 14 * u, 14 * u, NULL));
    setPath(_brake, CGPathCreateWithRoundedRect(brake, 14 * u, 14 * u, NULL));
    placeLabel(_gasLabel, CGPointMake(CGRectGetMidX(gas), CGRectGetMidY(gas)), 14 * u);
    placeLabel(_brakeLabel, CGPointMake(CGRectGetMidX(brake), CGRectGetMidY(brake)), 14 * u);
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    _run.fillColor = (_runHeld ? k_on : k_idle).CGColor; _runLabel.foregroundColor = (_runHeld ? k_textOn : k_text).CGColor;
    BOOL aim = _aimHeld || _aimLatched;
    _aim.fillColor = (aim ? k_on : k_idle).CGColor; _aimLabel.foregroundColor = (aim ? k_textOn : k_text).CGColor;
    BOOL throwing = (all & DM_BTN_ZR) != 0;
    _throw.fillColor = (throwing ? k_on : k_idle).CGColor; _throwLabel.foregroundColor = (throwing ? k_textOn : k_text).CGColor;
    BOOL gas = _racingTouch && (all & DM_BTN_ZR) != 0, brake = _racingTouch && (all & DM_BTN_ZL) != 0;
    _gas.fillColor = (gas ? k_on : k_idle).CGColor; _gasLabel.foregroundColor = (gas ? k_textOn : k_text).CGColor;
    _gasLabel.string = _racing.throttle_latched ? @"已锁油门" : @"油门锁";
    _gasLabel.bounds = CGRectMake(0, 0, 70 * self.u, _gasLabel.bounds.size.height);
    _brake.fillColor = (brake ? k_on : k_idle).CGColor; _brakeLabel.foregroundColor = (brake ? k_textOn : k_text).CGColor;
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    int backbone = dm_controller_is_backbone(g.controller.vendorName.UTF8String) ||
        dm_controller_is_backbone(g.controller.productCategory.UTF8String);
    if (backbone) m = dm_controller_face_buttons(g.buttonA.isPressed, g.buttonB.isPressed,
        g.buttonX.isPressed, g.buttonY.isPressed, backbone);
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
static uint64_t keyboard_button(GCKeyCode key) {
    // Preserve the original keyboard bindings independently of screen layout.
    if (key == GCKeyCodeKeyJ) return DM_BTN_A;
    if (key == GCKeyCodeKeyK) return DM_BTN_B;
    if (key == GCKeyCodeKeyU) return DM_BTN_X;
    if (key == GCKeyCodeKeyI) return DM_BTN_Y;
    if (key == GCKeyCodeKeyF) return DM_BTN_LS;
    if (key == GCKeyCodeKeyG) return DM_BTN_RS;
    if (key == GCKeyCodeKeyQ) return DM_BTN_L;
    if (key == GCKeyCodeKeyE) return DM_BTN_R;
    if (key == GCKeyCodeKeyZ) return DM_BTN_ZL;
    if (key == GCKeyCodeKeyC) return DM_BTN_ZR;
    if (key == GCKeyCodeReturnOrEnter) return DM_BTN_A;
    if (key == GCKeyCodeDeleteOrBackspace) return DM_BTN_B;
    if (key == GCKeyCodeEqualSign) return DM_BTN_PLUS;
    if (key == GCKeyCodeTab) return DM_BTN_MINUS;
    if (key == GCKeyCodeSpacebar) return DM_BTN_SHAKE;
    if (key == GCKeyCodeLeftArrow) return DM_BTN_LEFT;
    if (key == GCKeyCodeUpArrow) return DM_BTN_UP;
    if (key == GCKeyCodeRightArrow) return DM_BTN_RIGHT;
    if (key == GCKeyCodeDownArrow) return DM_BTN_DOWN;
    return 0;
}
static void read_key(GCKeyCode key, BOOL pressed) {
    pthread_mutex_lock(&g_mu);
    if (key == GCKeyCodeKeyW) g_key_w = pressed;
    else if (key == GCKeyCodeKeyA) g_key_a = pressed;
    else if (key == GCKeyCodeKeyS) g_key_s = pressed;
    else if (key == GCKeyCodeKeyD) g_key_d = pressed;
    else if (key == GCKeyCodeKeyZ) g_key_z = pressed;
    else if (key == GCKeyCodeKeyC) g_key_c = pressed;
    else if (key == GCKeyCodeLeftShift) g_shift_left = pressed;
    else if (key == GCKeyCodeRightShift) g_shift_right = pressed;
    else if (key == GCKeyCodeLeftGUI) g_command_left = pressed;
    else if (key == GCKeyCodeRightGUI) g_command_right = pressed;
    uint64_t bit = keyboard_button(key);
    if (key == GCKeyCodeKeyJ) g_key_j = pressed;
    else if (key == GCKeyCodeReturnOrEnter) g_key_enter = pressed;
    else if (key == GCKeyCodeKeyK) g_key_k = pressed;
    else if (key == GCKeyCodeDeleteOrBackspace) g_key_backspace = pressed;
    if (bit == DM_BTN_A || bit == DM_BTN_B) {
        g_key_btn &= ~(DM_BTN_A | DM_BTN_B);
        if (g_key_j || g_key_enter) g_key_btn |= DM_BTN_A;
        if (g_key_k || g_key_backspace) g_key_btn |= DM_BTN_B;
    } else g_key_btn = pressed ? g_key_btn | bit : g_key_btn & ~bit;
    if (nfs_keyboard()) {
        // NFS drives on the Switch triggers. Keep Z/C as aliases; W/S are
        // the natural keyboard pedals, while A/D still steer the left stick.
        g_key_btn &= ~(DM_BTN_ZL | DM_BTN_ZR);
        if (g_key_s || g_key_z) g_key_btn |= DM_BTN_ZL;
        if (g_key_w || g_key_c) g_key_btn |= DM_BTN_ZR;
    }
    g_key_lx = ((int)g_key_d - (int)g_key_a) * DM_STICK_MAX;
    g_key_ly = nfs_keyboard() ? 0 : ((int)g_key_w - (int)g_key_s) * DM_STICK_MAX;
    // Arrow keys are the four digital directions. Camera input remains on the
    // right-side touch drag, mouse/trackpad, or a physical right stick.
    g_key_rx = g_key_ry = 0;
    pthread_mutex_unlock(&g_mu);
    publish();
}
static void clear_keyboard(void) {
    pthread_mutex_lock(&g_mu);
    g_key_btn = 0; g_key_lx = g_key_ly = g_key_rx = g_key_ry = 0;
    g_key_w = g_key_a = g_key_s = g_key_d = g_key_left = g_key_up = g_key_right = g_key_down = NO;
    g_key_j = g_key_enter = g_key_k = g_key_backspace = NO;
    g_key_z = g_key_c = NO;
    g_shift_left = g_shift_right = NO;
    g_command_left = g_command_right = NO;
    pthread_mutex_unlock(&g_mu);
    publish();
}
// A mouse or keyboard-cover trackpad supplies relative deltas through
// GameController.  Turn a short burst into right-stick motion and return the
// stick to centre shortly after the last delta.  This keeps camera motion
// responsive without leaving it drifting after the finger stops.
static int32_t mouse_axis(float v) {
    static float scale;
    if (!scale) { const char *e = getenv("DM_MOUSE_LOOK_SCALE"); scale = e && atof(e) > 0 ? (float)atof(e) : 1400.f; }
    return (int32_t)fmaxf(-DM_STICK_MAX, fminf(DM_STICK_MAX, v * scale));
}
static void read_mouse(float dx, float dy) {
    if (!isfinite(dx) || !isfinite(dy) || (!dx && !dy)) return;
    pthread_mutex_lock(&g_mu);
    g_mouse_rx = mouse_axis(dx); g_mouse_ry = mouse_axis(dy);
    g_mouse_deadline = CACurrentMediaTime() + 0.060;
    pthread_mutex_unlock(&g_mu);
    publish();
}
static void clear_mouse(void) {
    pthread_mutex_lock(&g_mu); g_mouse_deadline = 0; g_mouse_rx = g_mouse_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
- (void)mouseMotionX:(float)dx y:(float)dy raw:(BOOL)raw {
    if (!isfinite(dx) || !isfinite(dy) || (!dx && !dy)) return;
    if (!NSThread.isMainThread) {
        pthread_mutex_lock(&g_mu); uint64_t epoch = g_input_epoch; BOOL eligible = g_input_active; pthread_mutex_unlock(&g_mu);
        if (!eligible) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            pthread_mutex_lock(&g_mu); BOOL current = g_input_active && epoch == g_input_epoch; pthread_mutex_unlock(&g_mu);
            if (current) [self mouseMotionX:dx y:dy raw:raw];
        });
        return;
    }
    pthread_mutex_lock(&g_mu); BOOL active = g_input_active; pthread_mutex_unlock(&g_mu);
    if (!active || _owner.count) return;   // never steal a held movement/camera/skill finger
    if (!pad_keep_touch() && (_touchPreferred || !_padOff)) {
        _touchPreferred = NO; _padOff = YES; _controls.hidden = YES;
        [self reset];
        LOG("front end: mouse motion selected pointer input; touch controls hidden");
    }
    if (raw) { pthread_mutex_lock(&g_mu); g_raw_mouse_time = CACurrentMediaTime(); pthread_mutex_unlock(&g_mu); }
    read_mouse(dx, dy);
    if (raw) { static int once; if (!once++) LOG("front end: raw mouse/trackpad motion is driving the camera"); }
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)inputDevicesChanged:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self inputDevicesChanged:note]; });
        return;
    }
    GCController *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? note.object : nil;
    BOOL controller = g_merge ? pads_merged(gone) : pads_slotted(gone);
    GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
    BOOL hasKeyboard = keyboard.keyboardInput != nil;
    _controllerOrKeyboard = controller || hasKeyboard;
    if (_controllerOrKeyboard) _touchPreferred = NO;
    if (hasKeyboard) {
        keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCDeviceButtonInput *button, GCKeyCode key, BOOL pressed) {
            (void)input; (void)button; read_key(key, pressed);
        };
    } else clear_keyboard();
    BOOL mouse = NO;
    for (GCMouse *m in GCMouse.mice) if (m.mouseInput) {
        mouse = YES;
        LOG("front end: mouse inventory vendor=%s category=%s", m.vendorName.UTF8String ?: "unknown", m.productCategory.UTF8String ?: "unknown");
        m.mouseInput.mouseMovedHandler = ^(GCMouseInput *input, float dx, float dy) {
            (void)input; [g_view mouseMotionX:dx y:dy raw:YES];
        };
    }
    if (!mouse) clear_mouse();
    BOOL keepTouch = pad_keep_touch();
    BOOL any = dm_controller_hides_touch(controller, hasKeyboard, mouse, _touchPreferred, keepTouch);
    LOG("front end: input devices controller=%d keyboard=%d mouse=%d; touch controls %s; blank right-half camera %s", controller, hasKeyboard, mouse, any ? "hidden" : "visible", !any && !_tap ? "enabled" : "disabled");
    BOOL changed = _padOff != any;
    _padOff = any; _controls.hidden = any;
    if (changed) [self reset];
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
static void clear_input_locked(void) {
    g_touch_btn = g_pad_btn = g_key_btn = 0; g_shake_btn = 0;
    g_touch_face = g_touch_native = 0;
    g_touch_lx = g_touch_ly = g_touch_rx = g_touch_ry = g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = g_key_lx = g_key_ly = g_key_rx = g_key_ry = g_mouse_rx = g_mouse_ry = 0;
    g_mouse_deadline = g_raw_mouse_time = 0;
    g_key_w = g_key_a = g_key_s = g_key_d = g_key_left = g_key_up = g_key_right = g_key_down = NO;
    g_key_j = g_key_enter = g_key_k = g_key_backspace = NO;
    g_shift_left = g_shift_right = NO;
    g_command_left = g_command_right = NO;
}
static void reset_touch_owners(void) {
    if (NSThread.isMainThread) [g_view reset];
    else dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
}
void dm_gamepad_reset(void) {   // A key held while switching away and released in background gets no "release"
    // Publish neutral touch axes immediately too: a queued UIKit reset must not
    // leave the camera turning after focus has already moved to another app.
    pthread_mutex_lock(&g_mu); clear_input_locked(); g_input_epoch++; pthread_mutex_unlock(&g_mu);
    publish(); reset_touch_owners();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
void dm_gamepad_set_active(int active) {
    // Clear old state and change eligibility under the same lock: a late global
    // callback cannot publish an inactive epoch's held axes on reactivation.
    pthread_mutex_lock(&g_mu); clear_input_locked(); g_input_epoch++; g_input_active = active != 0; pthread_mutex_unlock(&g_mu);
    publish(); reset_touch_owners();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    if (active) dm_gamepad_active();
    if (active) dispatch_async(dispatch_get_main_queue(), ^{
        if (g_input_active && g_view.window) [g_view becomeFirstResponder];
    });
    LOG("front end: input focus active=%d; all input neutralized", active != 0);
}
