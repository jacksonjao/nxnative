# Build games for Apple TV

This guide describes the Apple TV route in nxnative-tvOS. Each game needs its own supported profile and its own build from files you dumped from your console. The project does not include commercial game data, title keys, or a universal prebuilt game app.

## What you need

- An Apple silicon Mac with macOS 26.6 or later and Xcode with the tvOS SDK and Metal toolchain installed. The Mac is used to translate game assets, compile, sign, and install the app; the target is Apple TV only.
- Homebrew packages `xcodegen`, `zstd`, and `glslang`, plus the .NET 10 SDK. The setup checker lists missing requirements.
- An Apple ID configured in Xcode. Select a signing team during the build if automatic team detection does not find it.
- An Apple TV in Developer Mode, paired with Xcode at **Window > Devices and Simulators**.
- Your own game dump, optional update and DLC, and your own `prod.keys`. NSP, XCI and their compressed NSZ/XCZ forms are supported by the build pipeline.

## Set up the local tools

Run from the repository root. `TVPORT_DATA` keeps the Python environment and helper data inside this checkout:

```sh
TVPORT_DATA="$PWD/.local-data" python3 tvport/backend.py doctor
TVPORT_DATA="$PWD/.local-data" python3 tvport/backend.py setup
```

Keep game files and keys in folders you control, outside the repository. Place a game's base file, update and DLC together in its folder. The updater and game must belong to the same title.

## Build and install

Find the Apple TV identifier with:

```sh
TVPORT_DATA="$PWD/.local-data" python3 tvport/backend.py devices
```

Then build for that device:

```sh
TVPORT_DATA="$PWD/.local-data" DM_LANG=es-419 python3 tvport/backend.py build \
  "$HOME/Games/YourGameFolder" \
  --keys "$HOME/Keys/prod.keys" \
  --device "$DEVICE_ID" \
  --team "$TEAM_ID" \
  --mode docked \
  --texture-cap 512
```

Set `DEVICE_ID` to the paired Apple TV identifier and `TEAM_ID` to the Team ID shown in **Xcode > Settings > Accounts**. `--team` can be omitted when the backend finds the signing team automatically. Choose `--mode handheld` or `--mode docked` as the game's initial default; the startup menu can change it if that profile offers both.

The first build of a title can take 30–60 minutes because the pipeline extracts and translates its executable, assets and shaders. Later builds reuse generated data in the game's `_build` folder. The signed `.app` is also placed beside the game files; it is specific to that game build and signing setup.

## Apple TV startup settings

At launch, use the Siri Remote or a connected controller to choose the game's language, console mode, and any other settings exposed by its generated `launcher.json`. Choices are saved in the app on the Apple TV. The list is game-specific: options that do not apply to the title or tvOS are omitted.

The startup screen reports whether the active GPU supports Metal 4. The graphics backend chooses its Metal 4 path automatically when available. When a game exposes a Metal 4 pipeline setting, it appears only on Apple TV hardware that reports Metal 4 support. The MetalFX upscaler appears only when both the GPU and MetalFX spatial scaler support the required Metal 4 path. For supported Vulkan games, devices without Metal 4 can use the experimental classic-Metal presentation fallback; other game graphics paths may require Metal 4. Touch haptics are omitted because Apple TV has no touch surface.

The app is built with an A12-compatible instruction baseline, allowing one build to run on A12 and newer chips. Graphics capabilities are checked separately at runtime, so a newer Apple TV can use its supported Metal features without raising the minimum CPU baseline. Vulkan presentation on devices without Metal 4 uses the experimental classic-Metal fallback developed during A12 bring-up. Validate the picture and gameplay on each device before calling a title supported.

## Game support and troubleshooting

Games need a supported 64-bit executable and compatible graphics path. Their system calls, codecs, shader formats, memory use and save behavior vary. A successful extraction or Xcode build is not proof that the game will boot or render correctly. Start with the game's notes under [`dm/games`](../dm/games/README.md), and capture the Apple TV log when reporting a failure.

The first visual bring-up on an Apple TV 4K (2nd generation, A12) used Super Mario Galaxy. Its build recipe and current validation caveat are in the [Galaxy example](apple-tv-galaxy-example.md). That result documents the path and does not limit the fork to Galaxy or A12.

## Keep private build data out of Git

The repository ignore rules cover `.local-data/`, `build/`, game `_build` folders, `.app`, `.ipa`, NSP/XCI/NSZ/XCZ files and common key files. Keep any other extracted game assets or credentials out of commits and public releases.
