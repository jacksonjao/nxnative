#pragma once

#include <mach-o/loader.h>

// ld supplies a private __dso_handle for each Mach-O image. A game with a
// self-contained host must resolve its own HLE tables, not the shell's.
extern const struct mach_header_64 __dso_handle __attribute__((visibility("hidden")));
#define DM_HOST_IMAGE (&__dso_handle)
