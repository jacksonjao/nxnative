#include "TouchPointer.h"
#include <assert.h>

typedef struct { enum ra_pointer_event event; float x, y; } observation;
static observation observed[16];
static unsigned count;

static void observe(void *unused, enum ra_pointer_event event, float x, float y) {
    (void)unused;
    assert(count < sizeof observed / sizeof *observed);
    observed[count++] = (observation){event, x, y};
}

int main(void) {
    ra_touch_pointer state = {0};
#define F(id, phase, x, y) ra_touch_update(&state, observe, 0, id, RA_##phase, x, y)
    F(1, BEGIN, 20, 10);
    F(1, MOVE, 21, 11);
    assert(count == 0);
    F(1, END, 21, 11);
    assert(count == 3 && observed[1].event == RA_LEFT_DOWN && observed[2].event == RA_LEFT_UP);
    assert(observed[0].x == 21 && observed[0].y == 11);

    count = 0;
    F(1, BEGIN, 20, 10);
    F(1, MOVE, 45, 11);
    assert(count == 3 && observed[0].x == 20 && observed[1].event == RA_LEFT_DOWN);
    assert(observed[2].event == RA_POINTER_MOVE && observed[2].x == 45);
    F(2, BEGIN, 50, 11);  /* A stray finger must not interrupt the box selection. */
    F(2, END, 50, 11);
    F(1, CANCEL, 45, 11);
    assert(count == 4 && observed[3].event == RA_LEFT_UP);

    count = 0;
    F(1, BEGIN, 20, 10);
    F(2, BEGIN, 40, 20);
    F(1, END, 20, 10);
    assert(count == 0);
    F(2, END, 40, 20);
    assert(count == 3 && observed[1].event == RA_RIGHT_DOWN && observed[2].event == RA_RIGHT_UP);
    assert(observed[0].x == 30 && observed[0].y == 15);

    count = 0;
    F(1, BEGIN, 20, 10);
    F(2, BEGIN, 40, 20);
    F(2, MOVE, 70, 20);
    F(2, END, 70, 20);
    F(1, END, 20, 10);
    assert(count == 0);  /* A two-finger pan is not a right click. */
    F(1, BEGIN, 20, 10);
    F(1, CANCEL, 20, 10);
    assert(count == 0);
    return 0;
}
