# Build games for Apple TV

The `tvos` branch of this fork is seedds' nxnative with a tvOS target on top. Each game is built from your own dump, update and `prod.keys`, as for the iPhone. The repository has no game data, keys or prebuilt apps.

## What runs where

| Apple TV | Chip | Memory | NVN games (most Nintendo titles) | Vulkan / OpenGL games |
|---|---|---|---|---|
| 4K (1st generation) | A10X | 3 GB | no: needs Metal 4 | classic presenter, untested |
| 4K (2nd generation) | A12 | 3 GB | no: needs Metal 4 | classic presenter: Super Mario Galaxy boots, not play-tested |
| 4K (3rd generation) | A15 | 4 GB | yes (tested upstream: Super Mario Odyssey, Tears of the Kingdom, Animal Crossing) | yes |
| 4K (4th generation) | A19 | 8 GB | expected to, untested | expected to, untested |

The NVN layer replays on Metal 4 queues (A14 and later). Running NVN games on the A10X and A12 needs a renderer on classic Metal queues, which this branch does not have yet. None of these GPUs has BC texture formats, so the host stores BC textures decompressed (`nvn_mtl.m` `no_bc`; `DM_BC_MAX_DIM=<pixels>` drops the finest mip levels to save memory).

What the tvOS target changes, and why:

- Game files, saves and logs live in `Library/Caches` (tvOS apps keep no Documents). tvOS may purge it when storage is low, so `SourcesTV/TVSaves.m` keeps a copy of the saves in the app's preferences and puts them back.
- Guest memory goes into files when the game's pool is larger than the room to the app's memory limit (about 2.1 GB on tvOS): seedds' `DM_GUEST_FILE`, the same as on iPhone.
- The app opens on a settings screen (`SourcesTV/TVPlayers.m`): language, docked or handheld, and the game's other launcher settings from `dm/launcher.json`, chosen with the Siri Remote or a controller and kept for the next launch. Then **Start game**. In the game, controllers work as on the iPhone; the remote's Back button stays in the game.
- `DM_TV_PLAYERS=<names, comma-separated>` asks who is playing first, with a save folder each.

## Requirements

- An Apple silicon Mac with Xcode, the tvOS SDK and the Metal toolchain; Homebrew `xcodegen`, `zstd` and `glslang`; the .NET 10 SDK; the repository's Python virtual environment (as for the iPhone build, [development.md](development.md)).
- An Apple ID in Xcode (its team ID from **Xcode > Settings > Accounts**).
- An Apple TV in Developer Mode, paired in **Xcode > Window > Devices and Simulators**. Its identifier: `xcrun devicectl list devices`.

## Build and install

```sh
python3 scripts/build_tvos_from_nsp.py "$HOME/Games/Super Mario Odyssey" -k "$HOME/Keys/prod.keys" \
  --team-id TEAM_ID --device APPLE_TV_ID --language es-419 --mode docked
```

The first build of a game extracts it, rewrites its code and builds its shaders (30 to 60 minutes); later builds reuse `<game folder>/<title ID>_build`. Without `--device` the app is built and not installed. With it, the app is installed and the game's RomFS image is copied to the app's `Library/Caches/romfs.img` (several GB over the network). Do not share the built app: it holds rewritten game code.

## Keeping up with seedds

`main` follows `seedds/nxnative` unchanged. `tvos` is `main` plus the commits that make the tvOS target work; to update it, merge `main` into `tvos` and rebuild.
