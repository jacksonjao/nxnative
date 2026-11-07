These runtime profiles are opt-in for the TonTon Gamebox build. Pass this
directory through `DM_GAMES_DIR` when generating the library host profiles.
Keep the game's separately built framework and shader tables on their existing
verified version and chain.

Mario Kart World 1.0.0 uses conditional clears for its deferred lighting.
Air Gamebox 60.10 restored the title scene by enabling those clears without
changing its framework or shaders. Rendering performance and a full race still
need validation.

The Air 60.60 deployment keeps Mario Kart World's 60 Hz presentation setting
using `0400C3F00006E000/air-pacing.env`. Without `DM_FRAME_LIMIT=game`, the
library's unlimited default makes the renderer use 0 Hz even with
`DM_PRESENT_HZ=60`. This is presentation pacing, not a measured 60 fps.
The captured handheld run used a 1920×1080 source for MetalFX. Handheld mode
and MetalFX alone do not set the game's internal 3D resolution to 720p.
