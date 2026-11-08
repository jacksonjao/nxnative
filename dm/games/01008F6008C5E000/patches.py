# Exact original instructions verified in the owned Violet 4.0.0 main NSO.
# Reference: Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods; no code-cave writes.
OBS = {"709bfd66115298640155fcc4979dba15": [
    # Same Trinity duration and clock ABI as Z-A; the interval setter is inlined.
    (0x2b7a784, 26, "fd400400", "Violet base-clock record: original ldr d0,[x0,#8]"),
    (0x2b7a868, 27, "39430109", "Violet interval: w20 is the display code, w22 the adaptive clock candidate"),
    (0xcf11ec, 33, "6ea7e406", "Device camera scale in saved S16 after the original LDR"),
    (0x192bd30, 34, "2d408500", "Device HUD rectangle through saved x8; original LDPs retained"),
]}

BINDING = [{"what": 'Violet 4.0 clock and interval observation sites', "now": "build", "goal": "unreviewed", "purpose": 'timing', "why": "Both original instructions, the interval context and the duration table must match this exact build."},
           {"what": 'Violet 4.0 camera and HUD observation sites', "now": "build", "goal": "unreviewed", "purpose": 'rendering', "why": "Exact instructions and offsets are verified only for the registered builds; general matching has not been reviewed."}]
