# Build games for Apple TV

The `tvos` branch of this fork is seedds' nxnative with a tvOS target on top. Each game is built from your own dump, update and `prod.keys`, as for the iPhone. The repository has no game data, keys or prebuilt apps.

## What runs where

| Apple TV | Chip | Memory | NVN games (most Nintendo titles) | Vulkan / OpenGL games |
|---|---|---|---|---|
| 4K (1st generation) | A10X | 3 GB | no: needs Metal 4 | classic presenter, untested |
| 4K (2nd generation) | A12 | 3 GB | no: needs Metal 4 (Cuphead 1.3.7, 2026-11-09: the settings screen opens, then at Play `[nvn-mtl] FATAL the Metal device Apple A12 GPU has no Metal 4` and the app closes) | classic presenter: Super Mario Galaxy 1.3.1 boots; built and installed again after the merge of 2026-11-09 (tvOS 27.2); not play-tested. Super Mario Galaxy 2 1.3.1 (v327680, from a profile derived from 1.4.0's) built and installed 2026-11-09; starts and runs on the Apple TV (reported by the player, 2026-11-09); not play-tested through |
| 4K (3rd generation) | A15 | 4 GB | yes (tested upstream: Super Mario Odyssey, Tears of the Kingdom, Animal Crossing) | yes |
| 4K (4th generation) | A19 | 8 GB | expected to, untested | expected to, untested |

The NVN layer replays on Metal 4 queues (A14 and later). Running NVN games on the A10X and A12 needs a renderer on classic Metal queues, which this branch does not have yet. None of these GPUs has BC texture formats, so the host stores BC textures decompressed (`nvn_mtl.m` `no_bc`; `DM_BC_MAX_DIM=<pixels>` drops the finest mip levels to save memory).

What the tvOS target changes, and why:

- Game files, saves and logs live in `Library/Caches` (tvOS apps keep no Documents). tvOS may purge it when storage is low, so `SourcesTV/TVSaves.m` keeps a copy of the saves in the app's preferences and puts them back.
- Guest memory goes into files when the game's pool is larger than the room to the app's memory limit (about 2.1 GB on tvOS): seedds' `DM_GUEST_FILE`, the same as on iPhone.
- The app opens on a settings screen (`SourcesTV/TVLauncher.swift`, SwiftUI): the Mac app's settings window (`dm/mac/Launcher.swift`) laid out as a tvOS app page, on the same model and store (`LauncherSettings.swift`: `launcher.<VAR>` in the app's preferences, only the choices that differ from the game's default, saved at **Play**). The game's icon (`dm/icon.jpg`, copied by `build_ipa.sh`, as a layered icon cannot be read back), name, version and **Play**, which has focus, on the left; the settings on the right as tvOS rows, scrolling with the Siri Remote or a controller, with **Reset settings** (the Mac's Reset to tested defaults, dimmed when nothing differs; it keeps the Apple TV's game language); the icon blurred behind. Both columns are focus sections, so left from any row reaches **Play**. The screen is a child of the game's root view controller, not a presented one: tvOS's Back button dismisses a presented controller, which left the empty (black) game view with nothing to start the game; now Back on the screen goes to the Apple TV's Home screen, and in a list of values goes back to the screen. A choice or a range opens the list of its values; a toggle flips in place. Each row has a short description under it (its note from `settings.tsv`, or the screen's own line when the note is empty).
- The screen speaks the Apple TV's language among English, Spanish, French, German, Italian, Portuguese and Japanese (English otherwise): its own text, the shown settings' labels, options and descriptions, and the game languages' names. With no choice saved, **Game language** starts at the Apple TV's language when the game has it (a Latin American Spanish Apple TV picks `es-419`, a Spain one `es`; en-US / en-GB, fr / fr-CA, pt-BR / pt and zh-Hans / zh-Hant by region), else the packed one; that default is not saved, so it follows the Apple TV's language later, while a language the player picks is saved as any choice.
- The screen offers only what a TV player needs, each when the game has it: **Console mode**, **Frame rate**, **Render scale**, **Upscaling** (MetalFX, on A15 and later), **Game language**, **Game rumble** with **Rumble strength**, and **Press a button to join**. Every other setting (the Performance HUD, rumble cutoff, pipeline and encode switches, the iPhone's touch and picture rows, the Mac's window and Bluetooth rows) takes the game's tested default, even when an earlier screen saved another choice (a Performance HUD turned on there stayed on, with no row to turn it off); all of them still go into the environment at **Play**. A list of values opens on the checked one. Choices the earlier screen kept (`tv.setting.<VAR>`, `tv.language`, `tv.mode`) move to `launcher.<VAR>` once.
- After **Play**, `SourcesTV/TVPlayers.m` (`dm_tv_start`) asks who is playing when `DM_TV_PLAYERS` names several, gives the controllers back to the game and starts it. In the game, controllers work as on the iPhone; the remote's Back button stays in the game. The iPhone's touch gamepad and its gear (the in-game menu) are hidden on tvOS from the start (`DmGamepad.m`); hidden only at the first controller check, they showed for a few frames when the game began.
- `DM_TV_PLAYERS=<names, comma-separated>` asks who is playing first, with a save folder each.

## Requirements

- An Apple silicon Mac with Xcode, the tvOS SDK and the Metal toolchain; Homebrew `xcodegen`, `zstd` and `glslang`; the .NET 10 SDK; the repository's Python virtual environment (as for the iPhone build, [development.md](development.md)).
- An Apple ID in Xcode (its team ID from **Xcode > Settings > Accounts**).
- An Apple TV in Developer Mode, paired in **Xcode > Window > Devices and Simulators**, with **tvOS 27.2 or later**, the version the fork is built and tested on: it supports nothing older (`project_tv.yml`'s deployment target). Its identifier: `xcrun devicectl list devices`.

### Setting up without global installs

Everything outside Homebrew stays inside the repository or Xcode:

```sh
xcodebuild -downloadComponent MetalToolchain        # Xcode component, not on the PATH
brew install xcodegen zstd glslang dotnet           # the dotnet formula, not the dotnet-sdk cask
python3 -m venv .venv                               # the Python packages live in the repository only
.venv/bin/pip install lz4 "capstone>=5,<6" fonttools nsz zbic
echo ".venv/" >> .git/info/exclude                  # local ignore, no change to a tracked file
```

- The `dotnet` formula (.NET SDK 10) lives under `/opt/homebrew`; the `dotnet-sdk` cask installs a system package in `/usr/local/share/dotnet` and asks for the password. The NSP script finds the formula's `dotnet` by itself (`configure_dotnet`), with no `DOTNET_ROOT`.
- `backports.zstd` is only needed below Python 3.14.
- Run the scripts with the venv's interpreter (`.venv/bin/python scripts/...`): the build's tools take the `python3` of the caller's PATH, which `build_tvos_from_nsp.py` puts first.

### Finding the team ID

**Xcode > Settings > Accounts** lists the team; once Xcode has fetched it, it is also in its preferences:

```sh
plutil -p ~/Library/Preferences/com.apple.dt.Xcode.plist | grep -iE '"teamID"|"teamName"|isFreeProvisioningTeam'
```

`isFreeProvisioningTeam => false` is a paid account (the app does not expire after 7 days). Certificates listed as "Not in Keychain" belong to other Macs and cannot sign here; the first build (`-allowProvisioningUpdates`) creates an Apple Development certificate for this Mac.

## Build and install

```sh
python3 scripts/build_tvos_from_nsp.py "$HOME/Games/Super Mario Odyssey" -k "$HOME/Keys/prod.keys" \
  --team-id TEAM_ID --device APPLE_TV_ID --language es-419 --mode docked
```

The first build of a game extracts it, rewrites its code and builds its shaders (30 to 60 minutes); later builds reuse `<game folder>/<title ID>_build`. Without `--device` the app is built and not installed. The DLC the NSP script extracted (`<build>/aoc`) goes into the app as `aoc/` (the script passed none before, so The Delicious Last Course was left out of Cuphead). With `--device`, the app is installed and the game's RomFS image is copied to the app's `Library/Caches/romfs.img` (several GB over the network). Do not share the built app: it holds rewritten game code.

A game already built as a Mac app (`--platform mac-app`) reuses its extraction and its captured Vulkan shaders; the shaders are translated again for iOS/tvOS (Super Mario Galaxy: about 1.5 minutes, then the Xcode build and a 3.2 GB copy).

**Signing and installing.** `AGENTS.md` (upstream's) tells agents not to sign or install builds on the user's devices: upstream's iOS builds are unsigned IPAs the user sideloads. tvOS has no sideloading tool, so in this fork the Apple TV build is signed with the user's team and installed with `devicectl`; an agent does it when the user asks for it.

## Keeping up with seedds

`main` follows `seedds/nxnative` unchanged. `tvos` is `main` plus the commits that make the tvOS target work; to update it, merge `main` into `tvos` and rebuild.

Keep the tvOS changes in files upstream does not have (`docs/apple-tv-build.md`, `dm/ios/project_tv.yml`, `dm/ios/SourcesTV/`, `scripts/build_tvos_from_nsp.py`), so merges do not conflict; touch upstream's files (`README.md`, `AGENTS.md`, `build_ipa.sh`, …) only where tvOS needs it.

After a merge, the usual breakage is new iOS-only code reaching the tvOS target. What the merge of 2026-11-09 broke, and how it was fixed:

- **New iOS Swift sources.** Upstream added `GameMenu.swift` (the touch gamepad's in-game menu) and `DmHostingController.swift` (orientations). tvOS has neither `UIInterfaceOrientationMask` nor the launcher model they use (`LauncherSettings.swift`, already left out), so the Swift compile failed. `project_tv.yml` leaves both out, and `SourcesTV/TVGameMenu.m` gives `DmGamepad.m` its `dm_game_menu` with no menu (tvOS picks settings before the game starts). A new file under `dm/ios/Sources` goes into `project_tv.yml`'s `excludes` unless it builds for tvOS.
- **NVN shader libraries as one file.** Upstream now packs an NVN game's iOS shader libraries as `shader/ios/b-<chain>.img` instead of the folder `b-<chain>/`; `build_tvos_from_nsp.py` checked only the folder and stopped with `the NSP script finished without game files or shaders` (found on Cuphead). It now takes either, as `build_ipa.sh` does.
- **New frameworks.** `gen_build.py` checks the host's frameworks against the iOS SDK only, so `WebKit` (upstream's web applet, `web_apple.m`, which has no tvOS body) reached the link: `ld: framework 'WebKit' not found`. `build_ipa.sh` with `DM_TVOS=1` now drops every framework the tvOS SDK lacks (today `IOKit` and `WebKit`) and logs `tvOS: <framework> is not in the tvOS SDK, left out of the link`.
