// The Apple TV's half of the settings' Save sync choice (dm/ios/Sources/SaveBackend.h, docs/cloudkit-saves.md): save_sync.h's fetch and store, which hand CloudKit's
// folder to SaveBackend.swift. tvOS has no iCloud Drive; any other DM_SAVE_SYNC folder (an env file's) is copied as save_sync.c's plain defaults do.
// Kept in a file of its own, so that the Apple TV's other sources only call dm_save_backend_env (main_tv.m front_tv_start).
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>
#include "save_sync.h"

// SaveBackend.h (dm/ios/Sources; the prepared project has no path to it)
int dmck_owns(const char *cloud);
int dmck_fetch(const char *cloud, const char *local);
int dmck_store(const char *local, const char *cloud);

int front_save_sync_fetch(const char *cloud, const char *local) {
    if (dmck_owns(cloud)) return dmck_fetch(cloud, local);
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager new];
        if (![fm fileExistsAtPath:@(cloud)]) return 0;
        [fm removeItemAtPath:@(local) error:nil];
        return [fm copyItemAtPath:@(cloud) toPath:@(local) error:nil] ? 1 : -1;
    }
}

int front_save_sync_store(const char *local, const char *cloud) {
    if (dmck_owns(cloud)) return dmck_store(local, cloud);
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager new];
        NSString *part = [NSString stringWithFormat:@"%s.%d.part", cloud, (int)getpid()];
        [fm removeItemAtPath:part error:nil];
        if (![fm copyItemAtPath:@(local) toPath:part error:nil]) return 0;
        if (rename(part.fileSystemRepresentation, cloud)) { [fm removeItemAtPath:part error:nil]; return 0; }
        return 1;
    }
}
