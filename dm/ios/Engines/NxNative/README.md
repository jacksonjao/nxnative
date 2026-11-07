# Patches for pinned iOS engine lineages

The signed iPhone and iPad engines can use different base sources and shader
chains. Apply these patches to the source identified here. Keep the engine's
existing generated shader resources; a launcher update should not change their
chain or replace the game's saved data.

## Mario Kart World: file-backed texture uploads (Air 60.59)

The [mkw-neo upload gate](https://github.com/MenAtCafe/mkw-neo/commit/00d76d51560d)
avoids wiring a large file-backed guest pool when only a packaged texture in
that pool needs an upload. The Air variant checks the live guest reservation
and stages only uploads that would otherwise wire at least 64 MiB and eight
times the texture's size. Wrapped pools, small pools, non-packaged textures
and other titles retain the original path. This retains the 60.56 compute
archives for both Mario Kart World and Pokémon Legends: Z-A.

Apply `mkw-air-file-backed-texture-uploads.patch` to the Air 60.56 renderer
with its chunked guest-file host (865cc35-derived), not to the shared engine
whose host lacks file-backed guest memory. Source SHA-256 before patching:

- `dm/host/hle_svc.c`: `51f35785f230a7c3727f9f4ab7e4b839cd5633ff6c368e9a1b80a2e6dca50044`
- `dm/gfx/nvn/nvn_mtl.m`: `2e311373518793777787f96d233c748a8fbb0fca8a17d3bc8d68e172d02ae40c`

## Ocarina of Time: opening movie on Metal 3 (M2 60.60)

The opening video's decode kernel writes a private RGBA8 target which the
legacy path created without shader-write usage. Promote the exact decoder
output before encoding its dispatch. Scale that decoded frame into the
original movie destination and omit the matched 13 reconstruction dispatches
only when the replacement render pass was successfully encoded. Other
sequences retain the ordinary path. The independent engine keeps shader chain
`70fa6008c58d`; all six guest sections and its sealed shader companions are
byte-identical.

The installed M2 build was checked against the same opening. The opening
video is now visible; GPU median over the first reported 300 frames was
1.93 ms versus 76.50 ms on the preceding build. This does not establish 3D
gameplay performance or completeness.

Apply `ocarina-m2-opening-movie.patch` to the pinned 60.57 Ocarina Metal 3
renderer. Source SHA-256 before patching:

- `dm/gfx/nvn/nvn_mtl_legacy.inc`: `4a5bf9dfb5e825d1ac9e1122c7a53fdd841346a0d47f88ae54100accafcc0c4a`

## Ocarina of Time: offline play-report service (M2 60.61)

After the opening video reached end of stream, the game opened `prepo:u`
directly and aborted with `0xe15` when the service was absent. Admit that name
to the existing in-process HIPC responder only in the Ocarina framework.
The responder does not send telemetry or touch saved data. The Metal 3
renderer, sealed shader chain and all six guest sections stay unchanged.

Apply `ocarina-m2-offline-play-report.patch` to the pinned Ocarina 60.60
engine's `dm/host/hle_sf.c`, whose SHA-256 is
`4e37968a18e54f1a00b4bb516665aaa6973cb96cb8d14f83e608b953cd99b6f4`. Relink just the Ocarina framework;
the shared iOS engine does not use this patch.

## Ocarina of Time: offline play report (Air 60.60)

The signed Air 60.59 launcher reached end of stream and aborted with result
`0xe15` when the game opened `prepo:u`. The newer upstream engine intercepts
PlayReport::Send and completes it locally. This older launcher instead
serves that name through its existing offline responder, limited to
program `0400486024DEC000`. No report is sent. The game frameworks, shader
chain and save handling are unchanged.

Apply `ocarina-air-offline-play-report.patch` to `dm/host/hle_sf.c` in the
pinned Air launcher. The original SHA-256 is `4e37968a18e54f1a00b4bb516665aaa6973cb96cb8d14f83e608b953cd99b6f4`.

## Air Gamebox: native graphics settings for data-only games

Apply `air-native-quality-defaults.patch` to the 60.60 Air menu sources
(`main.m` and `GameSettings.h`). Games delivered with a signed Switch
framework but without `launcher.json` can now inherit the library's handheld
and MetalFX defaults and override either setting per game. The framework is
checked before using the fallback; native PC ports stay on their own paths.
Handheld mode is named as such because it does not promise 720p. The patch was
compiled and linked into the candidate mixed-engine shell; install and
gameplay validation are pending.
