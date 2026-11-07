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
