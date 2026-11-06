These runtime profiles are opt-in for the TonTon Gamebox build. Pass this
directory through `DM_GAMES_DIR` when generating the library host profiles.
Keep the game's separately built framework and shader tables on their existing
verified version and chain.

Mario Kart World 1.0.0 uses conditional clears for its deferred lighting.
Air Gamebox 60.10 restored the title scene by enabling those clears without
changing its framework or shaders. Rendering performance and a full race still
need validation.
