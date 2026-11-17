# Save sync: this device, iCloud Drive or iCloud (CloudKit)

The Mac, iPhone and Apple TV apps each have a **Save sync** choice in their settings:

| Choice | Mac | iPhone | Apple TV |
|---|---|---|---|
| **This device only** | sync off | sync off | the save stays on the Apple TV (its preferences store, `SourcesTV/TVSaves.m`) |
| **iCloud Drive folder** | the folder chosen in **Cloud saves** | the folder chosen in **Cloud saves** | not offered: tvOS has no iCloud Drive, Files app or folder picker |
| **iCloud (Mac, iPhone and Apple TV)** | CloudKit | CloudKit | CloudKit |

A choice the device cannot use is shown dimmed, with the reason under it: no iCloud Drive on tvOS; a build without an iCloud container; an app not signed for that container;
no iCloud account signed in, or iCloud restricted. When the chosen one cannot be used at **Play**, the game starts with this device's save only (the log says why).

Defaults: the Mac and iPhone keep what they did before the choice existed (**iCloud Drive folder**, off until a folder is chosen); the Apple TV starts with **This Apple TV only**.

## How iCloud (CloudKit) works

The host's own save sync does the work (`dm/host/save_sync.h`): it packs the save into one file, compares it with the cloud's and the one last in step, asks which to keep when
both changed, and keeps the replaced saves in `save-backups`. CloudKit is only where that one file lives: a record in the private database of your iCloud container, one per game
and save folder (`<save folder>__<title ID>`, for example `save__0100A3D008C5C000`, or `save.p-ana__…` for an Apple TV player with a save of their own; `save` is the folder the
three apps share).

- **iPhone and Apple TV**: the host runs in the app, so every send goes straight to CloudKit, and the start reads the record.
- **Mac**: the host is a process of its own, without the iCloud entitlement. It writes the save into `~/Library/Application Support/nxnative/cloudkit/`, and the launcher sends it
  once the game has exited, and before the next start if that send did not go. A record that changed in iCloud since the Mac last synced is not overwritten: the next start
  asks which save to keep.

The code is kept apart from upstream's, so that merging `main` touches little: `dm/ios/Sources/SaveBackend.swift` (the choice and CloudKit), `SaveBackendSection.swift` (the
settings rows, the same on the three apps), `SaveBackend.h`, `dm/mac/cloudkit_mac.py` and `dm/ios/tools/cloudkit_build.sh`. Upstream's files only call them: one line in each
of `SaveSync.m`, `CloudSaves.m`, `TVSaves.m`, the three settings screens, `dm/mac/launcher.c`, `pack_app.py` and `build_ipa.sh`.

## What it needs

iCloud is an entitlement only a **paid Apple Developer Program** account can sign. A free Apple ID cannot (its builds show the iCloud row dimmed). Nothing goes to the App
Store: development-signed builds installed on your own registered devices use CloudKit's **Development** environment, which holds your data just the same.

1. In the Apple developer site, **Identifiers**: create an **iCloud Container**, for example `iCloud.com.yourname.nxnative`. The three apps share it.
2. For each game's app (the bundle ID is `org.nxnative.<title ID in lower case>` unless `DM_BUNDLE_ID` sets another), create an **App ID** with the **iCloud** capability,
   **CloudKit** checked and that container assigned. A Mac app and an iPhone/Apple TV app of the same game may use the same App ID (it covers iOS, tvOS and macOS).
3. Register your Mac, iPhone and Apple TV under **Devices**, and make a **development provisioning profile** for each App ID (an iOS/tvOS one and a macOS one).
4. Build with the container:
   - iPhone / Apple TV: `DM_CLOUDKIT_CONTAINER=iCloud.com.yourname.nxnative` with `build_ipa.sh` (or the NSP script). The app's Info.plist gets `DMCloudKitContainer` and the
     entitlements ask for the container (`com.apple.developer.icloud-container-identifiers`, `com.apple.developer.icloud-services` = CloudKit). Sign the IPA with your paid team
     and the profile from step 3: Xcode (a prepared project, `--prepare-xcode`), or a tool that signs with your own profile. A tool that re-signs with a free account drops the
     iCloud entitlement, and the row then says the app is not signed for the container.
   - Mac: `DM_CLOUDKIT_CONTAINER=iCloud.com.yourname.nxnative DM_MAC_PROVISIONING_PROFILE=<the .provisionprofile>` and `--sign "Apple Development: <you> (<team>)"` for
     `pack_app.py` (or the NSP script's `--platform mac-app`). The profile goes into `Contents/embedded.provisionprofile` and the launcher is signed with its iCloud entitlements.
5. Sign in to the same iCloud account on the Mac, the iPhone and the Apple TV (Settings > Users and Accounts on the Apple TV).
6. In each app's settings, choose **iCloud (Mac, iPhone and Apple TV)**.

The first start on each device sends its save if iCloud has none. When both have changed (or both have a save at the first sync), the Mac and iPhone ask which to keep; the
Apple TV has no such question and keeps the newer one. Either way the replaced save is kept in `save-backups`.

The data can be seen and cleared in the [CloudKit Console](https://icloud.developer.apple.com/) (your container, Development, Private database, record type `Save`).
