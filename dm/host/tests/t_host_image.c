#include "../host_image.h"
#include <mach-o/getsect.h>

#ifndef HOST_IMAGE_SENTINEL
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#define HOST_IMAGE_SENTINEL 17
#endif

// Keep the fixture's one-word section exact when ASan instruments globals.
__attribute__((used,section("__DATA,__dm_host_test"),no_sanitize("address")))
static const unsigned sentinel = HOST_IMAGE_SENTINEL;

unsigned host_image_probe(void) {
    unsigned long size = 0;
    const unsigned *entry = (const unsigned *)getsectiondata(DM_HOST_IMAGE, "__DATA", "__dm_host_test", &size);
    return entry && size == sizeof *entry ? *entry : 0;
}

#if HOST_IMAGE_SENTINEL == 17
int main(int argc, char **argv) {
    assert(argc == 3 && host_image_probe() == 17);
    void *handles[2];
    for (unsigned i = 0; i < 2; ++i) {
        handles[i] = dlopen(argv[i + 1], RTLD_NOW | RTLD_LOCAL);
        assert(handles[i]);
        unsigned (*probe)(void) = dlsym(handles[i], "host_image_probe");
        assert(probe && probe() == 21 + i && host_image_probe() == 17);
    }
    for (unsigned i = 0; i < 2; ++i) {
        unsigned (*probe)(void) = dlsym(handles[i], "host_image_probe");
        assert(probe && probe() == 21 + i);
    }
    for (unsigned i = 0; i < 2; ++i) assert(dlclose(handles[i]) == 0);
    puts("Host image: executable and two loaded libraries resolve their own Mach-O sections");
    return 0;
}
#endif
