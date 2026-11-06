"""Generate a UIKit SDL view for the two private native Red Alert hosts."""

import argparse
import hashlib
from pathlib import Path


VIEW_SHA256 = "e1b9c46b50c5a2199ee5cfc35b3cac0b25df781d6cdea4ef0140b99251ed1326"
BRIDGE = """#if !TARGET_OS_TV
static void RAEmitPointer(void *context, enum ra_pointer_event event, float x, float y)
{
    SDL_Window *window = context;
    if (!window || window->w < 1 || window->h < 1) return;
    if (event == RA_POINTER_MOVE) {
        SDL_SendMouseMotion(window, SDL_TOUCH_MOUSEID, 0,
                            (int)SDL_clamp(x, 0, window->w - 1),
                            (int)SDL_clamp(y, 0, window->h - 1));
        return;
    }
    SDL_SendMouseButton(window, SDL_TOUCH_MOUSEID,
                        (event == RA_LEFT_DOWN || event == RA_RIGHT_DOWN) ? SDL_PRESSED : SDL_RELEASED,
                        (event == RA_RIGHT_DOWN || event == RA_RIGHT_UP) ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT);
}
#endif

"""
METHOD = """#if !TARGET_OS_TV
- (BOOL)raHandleDirectTouch:(UITouch *)touch phase:(enum ra_touch_phase)phase
{
    if (touch.type != UITouchTypeDirect) return NO;
    if (!sdlwindow) return YES;
    CGPoint point = [self touchLocation:touch shouldNormalize:NO];
    CGSize bounds = self.bounds.size;
    if (bounds.width > 0 && bounds.height > 0) {
        /* Keep the gesture threshold in UIKit points. SDL maps the synthetic
         * mouse position from window units to the game's letterboxed area. */
        const float sx = sdlwindow->w / bounds.width, sy = sdlwindow->h / bounds.height;
        if (sx > 0 && sy > 0) {
            struct RAWindowScale scale = {sdlwindow, sx, sy};
            ra_touch_update(&raPointer, RAEmitScaledPointer, &scale,
                            (uintptr_t)(__bridge void *)touch, phase, point.x, point.y);
        }
    } else if (phase == RA_CANCEL || phase == RA_END) {
        ra_touch_reset(&raPointer, RAEmitPointer, sdlwindow);
    }
    return YES;
}
#endif

"""


def replace_one(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one UIKit source anchor: {old}")
    return text.replace(old, new, 1)


def make_overlay(raw):
    if hashlib.sha256(raw).hexdigest() != VIEW_SHA256:
        raise ValueError("UIKit source differs from the reviewed SDL view")
    text = raw.decode()
    text = replace_one(text, '#include "SDL_uikitwindow.h"',
                       '#include "SDL_uikitwindow.h"\n#include "TouchPointer.h"')
    scaled = """struct RAWindowScale { SDL_Window *window; float x, y; };
static void RAEmitScaledPointer(void *context, enum ra_pointer_event event, float x, float y)
{
    struct RAWindowScale *s = context;
    RAEmitPointer(s->window, event, x * s->x, y * s->y);
}
"""
    bridge = replace_one(BRIDGE, "#endif\n", scaled + "#endif\n")
    text = replace_one(text, "@implementation SDL_uikitview {",
                       bridge + "@implementation SDL_uikitview {\n    ra_touch_pointer raPointer;")
    text = replace_one(text, "    /* Remove ourself from the old window. */",
                       "#if !TARGET_OS_TV\n    ra_touch_reset(&raPointer, RAEmitPointer, sdlwindow);\n#endif\n"
                       "    /* Remove ourself from the old window. */")
    for name, phase in (("Began", "BEGIN"), ("Moved", "MOVE"), ("Ended", "END")):
        sig = f"- (void)touches{name}:(NSSet *)touches withEvent:(UIEvent *)event"
        start = sig + "\n{\n    for (UITouch *touch in touches) {\n"
        guard = f"#if !TARGET_OS_TV\n        if ([self raHandleDirectTouch:touch phase:RA_{phase}]) continue;\n#endif\n"
        text = replace_one(text, start, (METHOD if name == "Began" else "") + start + guard)
    text = replace_one(text, "    [self touchesEnded:touches withEvent:event];",
                       """#if !TARGET_OS_TV
    NSMutableSet *remaining = [NSMutableSet setWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        if (![self raHandleDirectTouch:touch phase:RA_CANCEL]) [remaining addObject:touch];
    }
    [self touchesEnded:remaining withEvent:event];
#else
    [self touchesEnded:touches withEvent:event];
#endif""")
    return text


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("overlay", type=Path)
    args = parser.parse_args()
    output = make_overlay(args.source.read_bytes())
    with args.overlay.open("x", encoding="utf-8") as f:
        f.write(output)
