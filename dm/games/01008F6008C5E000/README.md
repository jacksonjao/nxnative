# Pokémon Violet (`01008F6008C5E000`)

Base game 1.0.0 (v0), SDK 13.3.5, Game Freak's Trinity engine on NVN.
Pokémon Scarlet's twin ([0100A3D008C5C000](../0100A3D008C5C000/README.md)):
the same `sdk` (`3644a676…`) and `subsdk0` (`d0f13015…`, Nintendo's movie
module) builds, byte for byte; only `main` is a build of its own
(`959ed651…`, Scarlet's is `ca44e7dd…`). Everything in Scarlet's note about
the engine, memory, shaders, pipeline preparation and its open items holds
here; this note gives only what differs or was checked again. The profile is
Scarlet's with Violet's title, name, IPA name, build row and shader tables.
Playable on the Mac: language, look and name selection, the academy settings,
the opening, the Paldea flyover, getting up in the bedroom, walking, camera
control, the main menu and autosave, and reloading that save. iPhone testing
is pending; no IPA has been built yet.
Only 1.0.0 is registered. The NSP folder also holds update 4.0.0
(`v786432`), so build with `scripts/build_ipa_from_nsp.py <NSP folder> -k
<prod.keys> -p v0` (add `--platform mac` for a Mac build); without `-p` the
builder takes the newest version and derives a profile without these checks.

## What it needs

The same keys as Scarlet's profile, for the same reasons
([Scarlet, Memory](../0100A3D008C5C000/README.md#memory)): the alias region
for the host's StandardAllocator cap, `mem_map_limit on` for the startup
probe of all allocatable memory, `depth_mode zero` for the game's
near = 0 depth mode, and `pad_layout full`. The 62 MB node-area cut and the
alignment of large regions come with the `sdk` build (`dm/tools/sdk_patches.py`
and the SDK-wide rule). No host code is keyed to either game's `main`.

No `patches.py`.

## Files and shaders

- The base NSP extracts cleanly: 24 RomFS files, 6,369.2 MB, with the same
  layout as Scarlet's (`arc/data.trpfs` is the `romfs_marker`). The supplied
  DLC is a licence-only NSP, as for Scarlet.
- Shaders: 30,142 (14,999 vertex, 15,057 pixel, 86 compute; 40 in `main`),
  the same as Scarlet's. The split's tables (`shader_map.tsv`,
  `shader_facts.tsv`, `shader_pairs.tsv`, `pso_pairs.tsv`) have the same data
  rows as Scarlet's, byte for byte; only the map's header note differs. The
  prewarm list is Scarlet's (it names shaders by content key).
- Chain `b3ca4b7c621f`: all 30,142 translate and compile for the Mac, with no
  undecoded bindings. Each shader's cache key covers the profile, so Violet's
  build translates every shader again; with `DMSH_PREFILL` naming Scarlet's
  Mac library root, 19,949 Metal libraries were filled from Scarlet's build.
  The offline pipeline prebuild built 24,481 bases from 24,487 pairs
  (6 left to the draws, 0 failed) in 28 minutes.

## Performance

- On the Mac, with the build's pipeline archive: 30 fps as on the Switch
  (frame time p50 33.33 ms, p95 under 34 ms) through character selection, the
  opening and the bedroom; resident memory up to 4.7 GB, GPU allocations about
  1.6 GB. The only red line is the conservative-raster dilation diagnostic,
  as on Scarlet.
- **Open, not reproduced:** one frame of the first gameplay run took 42.5 s
  (frame 12,047, 454 s in), with 71 ms of submit and present and 11 ms of GPU
  time in it: the process waited rather than worked. It followed a covered
  window and a drawable resize to 2560x1440 in the same run, and overlapped
  another session's game host. Three later reload runs (frames 1,500 to 8,700)
  show nothing like it: worst frame 271 ms, worst p95 34.6 ms.

## Mac routes

- The work folder's `run/boot.sh <name> [seconds] [VAR=value ...]` runs the
  build headless with its own host copy (`build/vihost`), the build's pipeline
  archive (`DM_PSO_ARCHIVE`, the `_build/run/pso_archive` the NSP script
  prebuilt; without it a run from another folder prebuilds 24,487 pairs again
  before the first frame) and `DM_PRESENT_LINK=0`. Without the latter, a
  window covered mid-run presents about once a second and the game ran at
  about 12 fps.
- A fresh save reaches the bedroom with Scarlet's route: `DM_KBD=Taylor` and
  `DM_KEYS="f300:A,f600:LUp+LLeft~0.3,f660:A,f1000:A,f1300:A*90/90,f10300:LDown~2"`.
  It picks a different look than on Scarlet. The flyover plays around present
  frame 6,000, the get-up prompt around 9,900, and the player stands in the
  bedroom from about 10,600.
- `run/save_ref` is the autosave from that route; it loads at the desk. Then
  `DM_KEYS="f300:A*5/150"` gets up; the left stick walks, the right stick
  turns the camera, X opens the main menu.
- **Observed, not a fault:** holding the right stick toward the wall by the
  bed turns the camera into the wall: about 90 frames (3 s) are black (the void
  behind the room set) with the wall's lit edge at the right, while the
  "Now saving" overlay keeps drawing, and the camera comes back when the
  player moves. This looks like the game's own camera collision; it has not
  been compared with a Switch.

## Open

- iPhone gameplay, device memory and touch controls are untested; no IPA has
  been built. Build its iOS shaders with Scarlet's iOS libraries as prefill
  (`DMSH_PREFILL=<Scarlet Mac root>=<Scarlet iOS root>`) when they are on
  disk.
- Update 4.0.0 (`v786432`) is in the NSP folder but not registered. Scarlet's
  4.0.0 copy was damaged ([Scarlet, Files and builds](../0100A3D008C5C000/README.md#files-and-builds));
  whether Violet's is intact has not been checked.
- Outdoor exploration and battles have not been validated, as on Scarlet.
- [Conservative rasterization](../../../docs/reference/rendering.md#conservative-rasterization-remains-unimplemented)
  is unimplemented, as on Scarlet.

## Found on this game

Nothing new: the findings are Scarlet's ([Found on this game](../0100A3D008C5C000/README.md#found-on-this-game)).

## iOS 16/17 fork observations

# Pokemon Violet

Current preparation: owned update 4.0.0, main build `709bfd66115298640155fcc4979dba15`, SDK 13.3.13, plus two add-on licences. The RomFS/code survey is complete; no playable profile is registered here. The provisional profile, shader work, IPA and gameplay/device validation remain open.

Two exact-build observation sites adapt the camera and HUD to the actual window. Reference: the author's [Violet ultrawide source patch](https://github.com/Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods). The camera observation follows the original `LDR S16,[x19,#0x190]` and multiplies its saved scalar lane by `device aspect / (16/9)`. The HUD observation redirects saved x8 before the original two LDP instructions, using thread-local storage instead of changing the original table. There are no runtime executable writes or borrowed code caves. The source patch's separate NOP at `main+0x1526d64` is not carried over: its role is unverified, and the owned binary has a live stack store there.

The saved-frame layout was checked against `entry.S`: Q registers begin at byte 256, with NZCV/FPSR/FPCR after byte 768. Callback tests cover 76:35, 683:512 and 4:3, verify exact module/gate guards, and verify every other GPR/SIMD/flags byte stays unchanged. Instruction-level rewrite and actual device display validation must pass before declaring fullscreen complete.

Frame timing, 120 fps, internal resolution scaling and interpolation are still open. The shared input surface keeps every native button and keyboard direction; compilation does not certify game compatibility.

### Air update 4.0.0: startup after the shared fonts load

The Air startup log reached the standard shared font and then aborted at
`nn::bluetooth::InitializeBle` when the SDK tried to open the Horizon `bt`
service. This matches [nxnative issue #207](https://github.com/seedds/nxnative/issues/207).
The host backports the offline BLE hooks from `62be7fa`: scans find no
accessory and events never fire. Pokémon GO Plus + is unavailable; this
does not use the iPhone Bluetooth radio. All 15 hook names were found in
the existing Violet framework. The signed Air update keeps the original
game frameworks and assets; entering the title screen is still unverified.

### M2 iPad update 4.0.0

On iPadOS 16.1, the 60.83 game framework keeps the existing signed guest
code and the installed ROM. It binds to the legacy Metal shader chain
`b-a3a5cfdab59c`, whose 35,937 base shader libraries were validated before
delivery. The two shared fonts and the chain's uniform tables are installed
with the packed library. The same offline BLE fix that unblocks startup on
Air is linked into the iPad host.

The renderer also reads raster companion sources and the legacy image-atomic
validation copy from the loose shader directory. The base shader image alone
does not provide those paths. The pre-repair run loaded the shader image
and reached the save mount, but rejected affected render pipelines.


The 60.83 M2 test opened the title, entered the starting bedroom and
accepted controller input, but models were stretched across the scene.
Violet's capture shader uses the same reflected 64-byte vertex argument at
slot 14 as Z-A. The 60.84 renderer binds that argument when the shader
declares it. The signed update replaced only the host and was installed in
place on iPadOS 16.1; the existing ROM and save inventory were verified
before and after. The isolated test save was mounted on 60.84, but the app
left the foreground before a new gameplay frame could be checked.

The 60.84 log also showed the verified Violet 2D image-atomic shader still
being rejected at draw time. The 60.85 candidate allows only its already
validated read-only border constants through the runtime guard. Texture
format and alias checks remain in effect. This candidate was built and
signed; hardware verification is pending.

### M2 iPad: uncapped render timing candidate

Violet 4.0.0 (main build `709bfd66115298640155fcc4979dba15`) has separate
controls for the presentation interval and the game clock. The timing
candidate leaves rendering uncapped with `DM_FRAME_LIMIT=unlimited` and
`DM_PRESENT_INTERVAL=game`; `DM_VIOLET_FPS_MODE=dynamic` makes the engine
consume measured active frame time instead of a fixed duration each frame.
`DM_VIOLET_TIMING=1` enables diagnostics and live A/B changes; `game`
restores the original timing table. Existing ROM, shaders and saves do not
need to be transferred again. This requires a host with the timing callback
and a 4.0.0 game framework rewritten with both timing gates.

The 60.86 device update and the per-game timing settings were verified in
place. The original instructions and duration table are checked before arming.
Local tests exercise variable 30, 60, 86 and 120 fps, verify that the
consumed game clock tracks active elapsed time, and cover an absent gate,
a paused channel and restoration of the original table. Actual movement,
jump height, animations and battle timing on M2 still require device
verification. A [fixed 60 fps mod was reported to alter jump height](https://github.com/seedds/nxnative/issues/436).
