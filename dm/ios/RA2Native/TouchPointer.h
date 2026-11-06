#ifndef TONTON_RA_TOUCH_POINTER_H
#define TONTON_RA_TOUCH_POINTER_H

#include <stdint.h>

enum ra_touch_phase { RA_BEGIN, RA_MOVE, RA_END, RA_CANCEL };
enum ra_pointer_event { RA_POINTER_MOVE, RA_LEFT_DOWN, RA_LEFT_UP, RA_RIGHT_DOWN, RA_RIGHT_UP };
typedef void (*ra_pointer_emit)(void *, enum ra_pointer_event, float, float);

typedef struct {
    uintptr_t first, second;
    float x, y, x2, y2;
    unsigned chord : 1, drag : 1, cancelled : 1;
} ra_touch_pointer;

static inline int ra_touch_moved(float x0, float y0, float x, float y) {
    const float dx = x - x0, dy = y - y0;
    return dx * dx + dy * dy >= 64.0f;
}

/* Points are UIKit points, not pixels. Wait for a tap or a deliberate drag
 * before emitting a left click so a two-finger command never selects a unit. */
static inline void ra_touch_update(ra_touch_pointer *s, ra_pointer_emit emit, void *ctx,
                                   uintptr_t id, enum ra_touch_phase phase, float x, float y) {
    if (phase == RA_BEGIN) {
        if (!s->first && !s->second) {
            s->first = id;
            s->x = x;
            s->y = y;
        } else if (!s->chord && !s->drag && s->first != id) {
            s->second = id;
            s->chord = 1;
            s->x2 = x;
            s->y2 = y;
        } else if (s->chord && id != s->first && id != s->second) {
            s->cancelled = 1;
        }
        return;
    }
    if (!id || (id != s->first && id != s->second)) return;

    if (s->chord) {
        const int first = id == s->first;
        if (phase == RA_CANCEL || ra_touch_moved(first ? s->x : s->x2, first ? s->y : s->y2, x, y))
            s->cancelled = 1;
        if (phase == RA_MOVE) return;
        if (first) s->first = 0;
        else s->second = 0;
        if (s->first || s->second) return;
        if (!s->cancelled) {
            const float cx = (s->x + s->x2) * 0.5f, cy = (s->y + s->y2) * 0.5f;
            emit(ctx, RA_POINTER_MOVE, cx, cy);
            emit(ctx, RA_RIGHT_DOWN, cx, cy);
            emit(ctx, RA_RIGHT_UP, cx, cy);
        }
    } else {
        int moved_to_touch = 0;
        if (!s->drag && phase != RA_CANCEL &&
            (phase == RA_END || ra_touch_moved(s->x, s->y, x, y))) {
            const int moved = ra_touch_moved(s->x, s->y, x, y);
            const float down_x = moved ? s->x : x, down_y = moved ? s->y : y;
            emit(ctx, RA_POINTER_MOVE, down_x, down_y);
            emit(ctx, RA_LEFT_DOWN, down_x, down_y);
            s->drag = 1;
            moved_to_touch = !moved;
        }
        if (s->drag && phase != RA_CANCEL && !moved_to_touch)
            emit(ctx, RA_POINTER_MOVE, x, y);
        if (phase == RA_MOVE) return;
        if (s->drag) emit(ctx, RA_LEFT_UP, x, y);
    }
    *s = (ra_touch_pointer){0};
}

static inline void ra_touch_reset(ra_touch_pointer *s, ra_pointer_emit emit, void *ctx) {
    if (s->drag) emit(ctx, RA_LEFT_UP, s->x, s->y);
    *s = (ra_touch_pointer){0};
}

#endif
