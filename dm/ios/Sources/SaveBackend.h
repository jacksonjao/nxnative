// Where the save syncs through, chosen in each app's settings (SaveBackend.swift, SaveBackendSection.swift; docs/cloudkit-saves.md): this device only, an iCloud Drive
// folder (CloudSaves.m, the Mac's cloudSaves.folder), or iCloud through CloudKit, which the Apple TV can use too. Kept in files of its own so that a merge of upstream's main
// touches one line in each front end: the calls below.
#pragma once

// 0 = this device only, 1 = an iCloud Drive folder, 2 = CloudKit
int dm_save_backend(void);
// Sets DM_SAVE_SYNC for the chosen backend before the game's first save mount reads it. 1 = done (CloudKit's folder, or sync off); 0 = the caller's own way
// (the iCloud Drive folder, or a build with the host's older CloudKit sync, DMCloudSaveContainer). A DM_SAVE_SYNC an env file or the launch environment set wins: then 1, and nothing changes
int dm_save_backend_env(void);
// A DM_SAVE_SYNC path in CloudKit's folder: the front end's save_sync hooks hand it to dmck_fetch / dmck_store
int dmck_owns(const char *cloud);
// save_sync.h's front_save_sync_fetch / front_save_sync_store for CloudKit: 1 = done, 0 = none there (fetch) / not sent (store), -1 = failed (fetch)
int dmck_fetch(const char *cloud, const char *local);
int dmck_store(const char *local, const char *cloud);
// The Mac launcher once the host has exited: the host wrote the save into CloudKit's folder (it has no iCloud entitlement); this sends it on
void dmck_after_exit(const char *title);
