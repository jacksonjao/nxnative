// "Who's playing?", for a game shared by several people. Apple's way to tell Apple TV profiles apart is the User Management capability, which a free Apple ID cannot have, so the app cannot see the active profile.
// With DM_TV_PLAYERS=<names, comma-separated> (TVPort's Players field) it asks instead, before the game starts, and each player gets a save folder of their own. With fewer than two names it goes straight to the game.
// A name keeps its folder for good, whatever else changes in the list: the first name listed takes the save that was already there, whoever picks first, and the others get save.p-<name>. The shader list is shared by all (pso_user.tsv beside them).
// A game whose only save is the console's (Animal Crossing: New Horizons, its island) keeps one folder, as on a Switch: each name is a user of its own instead, a resident of the same island (hle_account.c).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>

static NSString *const FOLDERS = @"dmplayers", *const LAST = @"dmplayer.last", *const OWNER = @"dmplayer.owner";
int dm_console_save_only(void); void dm_host_preload_wait(void);

static NSArray<NSString *> *player_names(void) {
    const char *e = getenv("DM_TV_PLAYERS");
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *part in [@(e ?: "") componentsSeparatedByString:@","]) {
        NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

static NSString *folder_for(NSString *name) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *map = [[d dictionaryForKey:FOLDERS] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (map[name]) return map[name];
    NSString *folder = @"save";
    if (![name isEqualToString:player_names().firstObject] || [map.allValues containsObject:folder]) {
        NSMutableString *slug = [NSMutableString string];
        for (NSUInteger i = 0; i < name.length; i++) { unichar c = [name.lowercaseString characterAtIndex:i]; if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [slug appendFormat:@"%C", c]; }
        if (!slug.length) [slug setString:@"player"];
        folder = [@"save.p-" stringByAppendingString:slug];
        for (int n = 2; [map.allValues containsObject:folder]; n++) folder = [NSString stringWithFormat:@"save.p-%@-%d", slug, n];   // two names with the same letters
    }
    map[name] = folder;
    [d setObject:map forKey:FOLDERS]; [d synchronize];
    return folder;
}

// Everyone, for the host's user list. The first keeps the console's first user for good, so reordering the list does not swap anyone's resident
static NSString *users_of(NSArray<NSString *> *names) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *owner = [d stringForKey:OWNER];
    if (!owner.length) { owner = names.firstObject; [d setObject:owner forKey:OWNER]; [d synchronize]; }
    NSMutableArray *users = [NSMutableArray arrayWithObject:owner];
    for (NSString *name in names) if (![name isEqualToString:owner]) [users addObject:name];
    return [users componentsJoinedByString:@","];
}

static void use_player(NSString *name) {
    dm_host_preload_wait();   // main's imports are known once loading is done
    NSString *where;
    if (dm_console_save_only()) {
        NSString *users = users_of(player_names());
        setenv("DM_USERS", users.UTF8String, 1);
        where = [@"the console's, users " stringByAppendingString:users];
    } else {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        where = folder_for(name);
        setenv("DM_SAVE", [caches stringByAppendingPathComponent:where].fileSystemRepresentation, 1);
    }
    setenv("DM_NICK", name.UTF8String, 1);   // the name a game shows for its player
    [NSUserDefaults.standardUserDefaults setObject:name forKey:LAST];
    fprintf(stderr, "[dm] front end: player %s, save %s\n", name.UTF8String, where.UTF8String);
}

@interface DmPlayerPicker : UIViewController
@property(copy, nonatomic) NSArray<NSString *> *names;
@property(copy, nonatomic) void (^chosen)(NSString *name);
@property(strong, nonatomic) NSMutableArray<UIButton *> *buttons;
@end
@implementation DmPlayerPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new];
    title.text = @"Who's playing?"; title.font = [UIFont systemFontOfSize:57 weight:UIFontWeightSemibold]; title.textColor = UIColor.whiteColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter; stack.spacing = 32; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:64 afterView:title];
    self.buttons = [NSMutableArray array];
    for (NSString *name in self.names) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:name forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightMedium];
        [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [b.widthAnchor constraintEqualToConstant:640].active = YES;
        [stack addArrangedSubview:b]; [self.buttons addObject:b];
    }
    [self.view addSubview:stack];
    [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
}
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {   // whoever played last
    NSUInteger i = [self.names indexOfObject:[NSUserDefaults.standardUserDefaults stringForKey:LAST] ?: @""];
    return i == NSNotFound ? self.buttons : @[self.buttons[i]];
}
- (void)pick:(UIButton *)b { self.chosen(self.names[[self.buttons indexOfObject:b]]); }
@end

static BOOL tv_supports_metal4(void);
static BOOL tv_supports_metalfx(void);

@interface DmTVGameSettings : UIViewController
@property(copy, nonatomic) NSArray<NSString *> *names;
@property(copy, nonatomic) void (^chosen)(void);
@property(copy, nonatomic) NSArray<NSDictionary *> *settings;
@property(strong, nonatomic) NSMutableDictionary<NSString *, NSString *> *values;
@property(strong, nonatomic) UIStackView *stack;
@property(strong, nonatomic) UIButton *startButton;
@end

@implementation DmTVGameSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new];
    title.text = @"Game settings"; title.font = [UIFont systemFontOfSize:58 weight:UIFontWeightBold]; title.textColor = UIColor.whiteColor;
    UILabel *hint = [UILabel new];
    hint.text = @"Choose the language and console mode before playing."; hint.font = [UIFont systemFontOfSize:28]; hint.textColor = UIColor.secondaryLabelColor;
    UILabel *gpu = [UILabel new];
    gpu.text = tv_supports_metal4() ? @"GPU support: Metal 4 (used automatically when available)" : @"GPU support: classic Metal only";
    gpu.font = [UIFont systemFontOfSize:24]; gpu.textColor = UIColor.secondaryLabelColor;
    self.stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, hint, gpu]];
    self.stack.axis = UILayoutConstraintAxisVertical; self.stack.alignment = UIStackViewAlignmentCenter; self.stack.spacing = 8; self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack setCustomSpacing:26 afterView:gpu];
    [self rebuildRows];
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"Start game" forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightSemibold];
    self.startButton.titleLabel.textColor = UIColor.whiteColor;
    [self.startButton.widthAnchor constraintEqualToConstant:920].active = YES;
    [self.startButton.heightAnchor constraintEqualToConstant:80].active = YES;
    [self.startButton addTarget:self action:@selector(start:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.stack addArrangedSubview:self.startButton];
    [self.view addSubview:self.stack];
    [self.stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [self.stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
}
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments { for (UIView *view in self.stack.arrangedSubviews) if ([view isKindOfClass:UIButton.class] && view != self.startButton) return @[view]; return self.startButton ? @[self.startButton] : @[]; }
- (NSArray<NSDictionary *> *)visibleSettings {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *s in self.settings) {
        NSString *key = s[@"env"];
        // Touch haptics have no touch surface on tvOS. Metal 4 controls appear only on a GPU that can run that path.
        if ([key isEqualToString:@"DM_TOUCH_HAPTICS"]) continue;
        if ([key isEqualToString:@"DM_PSO_MTL4"] && !tv_supports_metal4()) continue;
        if ([key isEqualToString:@"DM_PRESENT_UPSCALE"] && !tv_supports_metalfx()) continue;
        NSString *needs = s[@"needs"]; NSRange eq = [needs rangeOfString:@"="];
        if (needs.length && eq.location != NSNotFound) {
            NSString *parent = [needs substringToIndex:eq.location], *value = [needs substringFromIndex:eq.location + 1];
            if (![self.values[parent] isEqualToString:value]) continue;
        }
        [rows addObject:s];
    }
    return rows;
}
- (NSArray<NSArray<NSString *> *> *)optionsFor:(NSDictionary *)s {
    if ([s[@"kind"] isEqualToString:@"choice"]) {
        NSArray *options = s[@"options"];
        return options ?: @[];
    }
    if ([s[@"kind"] isEqualToString:@"toggle"]) return @[@[s[@"on"] ?: @"1", @"On"], @[s[@"off"] ?: @"0", @"Off"]];
    if ([s[@"kind"] isEqualToString:@"range"]) {
        double lo = [s[@"min"] doubleValue], hi = [s[@"max"] doubleValue], step = [s[@"step"] doubleValue];
        if (step <= 0 || hi < lo) return @[];
        NSMutableArray *options = [NSMutableArray array];
        for (int i = 0; lo + i * step <= hi + step * 0.001 && i < 101; i++) {
            double value = lo + i * step; NSString *code = [NSString stringWithFormat:@"%.6g", value];
            NSString *label = [NSString stringWithFormat:@"%d%%", (int)lrint(value * 100)];
            [options addObject:@[code, label]];
        }
        return options;
    }
    return @[];
}
- (NSString *)displayValue:(NSDictionary *)s {
    NSString *value = self.values[s[@"env"]] ?: s[@"default"] ?: @"";
    for (NSArray *option in [self optionsFor:s]) if ([option[0] isEqualToString:value]) return option[1];
    return value;
}
- (void)rebuildRows {
    for (UIView *view in [self.stack.arrangedSubviews copy]) if (view.tag == 200) { [self.stack removeArrangedSubview:view]; [view removeFromSuperview]; }
    NSArray *rows = [self visibleSettings];
    NSArray *sections = @[@"Game", @"Controls", @"Performance"];
    for (NSString *section in sections) {
        NSMutableArray *inSection = [NSMutableArray array];
        for (NSDictionary *s in rows) if ([((NSString *)s[@"section"] ?: @"Game") isEqualToString:section]) [inSection addObject:s];
        if (!inSection.count) continue;
        UILabel *heading = [UILabel new]; heading.text = section; heading.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBold]; heading.textColor = UIColor.whiteColor; heading.tag = 200;
        [self.stack addArrangedSubview:heading];
        for (NSDictionary *s in inSection) {
            NSString *key = s[@"env"], *label = s[@"label"] ?: key;
            NSString *value = self.values[key] ?: s[@"default"] ?: @"";
            NSArray *options = [self optionsFor:s]; NSMutableArray<UIAction *> *actions = [NSMutableArray array];
            for (NSArray<NSString *> *option in options) {
                if (option.count < 2) continue;
                NSString *code = option[0], *name = option[1];
                UIAction *action = [UIAction actionWithTitle:name image:nil identifier:nil handler:^(__kindof UIAction *a) {
                    self.values[key] = code; [NSUserDefaults.standardUserDefaults setObject:code forKey:[@"tv.setting." stringByAppendingString:key]];
                    if ([key isEqualToString:@"DM_LANG"]) [NSUserDefaults.standardUserDefaults setObject:code forKey:@"tv.language"];
                    if ([key isEqualToString:@"DM_OPMODE"]) [NSUserDefaults.standardUserDefaults setObject:code forKey:@"tv.mode"];
                    [self rebuildRows];
                }];
                action.state = [code isEqualToString:value] ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
            }
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:[NSString stringWithFormat:@"%@: %@", label, [self displayValue:s]] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium]; button.titleLabel.textColor = UIColor.whiteColor;
            [button.widthAnchor constraintEqualToConstant:980].active = YES; [button.heightAnchor constraintEqualToConstant:64].active = YES;
            button.menu = [UIMenu menuWithTitle:label children:actions]; button.showsMenuAsPrimaryAction = YES; button.tag = 200;
            [self.stack addArrangedSubview:button];
        }
    }
}
- (void)start:(UIButton *)sender { (void)sender; self.chosen(); }
@end

static BOOL tv_supports_metal4(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device && [device supportsFamily:MTLGPUFamilyMetal4];
}

static BOOL tv_supports_metalfx(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device && [device supportsFamily:MTLGPUFamilyMetal4] && [MTLFXSpatialScalerDescriptor supportsMetal4FX:device];
}

// Always show the game choices on Apple TV; unlike the phone, tvOS has no settings launcher.
bool dm_show_launcher(void *view_controller, void (*done)(void)) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *file = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"dm/launcher.json"]] options:0 error:nil];
    NSArray<NSDictionary *> *settingsList = [file[@"settings"] isKindOfClass:NSArray.class] ? file[@"settings"] : @[];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *s in settingsList) {
        NSString *key = s[@"env"], *fallback = s[@"default"] ?: @"";
        NSString *old = [key isEqualToString:@"DM_LANG"] ? [defaults stringForKey:@"tv.language"] : [key isEqualToString:@"DM_OPMODE"] ? [defaults stringForKey:@"tv.mode"] : nil;
        values[key] = [defaults stringForKey:[@"tv.setting." stringByAppendingString:key]] ?: old ?: fallback;
    }
    GCEventViewController *root = (__bridge GCEventViewController *)view_controller;
    root.controllerUserInteractionEnabled = YES;
    DmTVGameSettings *settings = [DmTVGameSettings new];
    settings.settings = settingsList; settings.values = values;
    settings.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak DmTVGameSettings *weakSettings = settings;
    settings.chosen = ^{
        for (NSDictionary *s in settingsList) { NSString *key = s[@"env"], *value = weakSettings.values[key] ?: s[@"default"]; if (key.length && value.length) setenv(key.UTF8String, value.UTF8String, 1); }
        NSArray<NSString *> *names = player_names();
        void (^startGame)(void) = ^{ root.controllerUserInteractionEnabled = NO; done(); };
        if (names.count < 2) {
            if (names.count) use_player(names.firstObject);
            [weakSettings dismissViewControllerAnimated:NO completion:startGame];
            return;
        }
        DmPlayerPicker *picker = [DmPlayerPicker new]; picker.names = names; picker.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak DmPlayerPicker *weakPicker = picker;
        picker.chosen = ^(NSString *name) {
            use_player(name); root.controllerUserInteractionEnabled = NO;
            [weakPicker dismissViewControllerAnimated:NO completion:^{ done(); }];
        };
        [weakSettings presentViewController:picker animated:NO completion:nil];
    };
    [root presentViewController:settings animated:NO completion:nil];
    return true;
}
