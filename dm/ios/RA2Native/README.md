# Native Red Alert 2 platform adapter

These helpers are the beginning of an iOS 16.1+ port for M2 iPad and iPhone Air
of the native static recompilation route. They do not add a playable game to
TonTon yet. The existing BoxedWine engine is a separate implementation.

The reviewed engine is `sp00nznet/redalert2-recomp` at
`4ecdea4dd12729696d5fe0a4296c49202695bc3e`, with `sp00nznet/pcrecomp` at
`ef3f0da6e08a8eb7a3f869273f3df071ca8d7373`. Game executables, lifted game C,
retail assets and saves must remain outside the repository. Keep the licenses
and corresponding source requirements of each linked dependency with builds.

`prepare_runtime_overlay.py` checks the two affected source files against that
pcrecomp commit and writes an independent overlay. It never changes the
toolkit. Compile its `gdidc.c` and `kernel32.c` **instead of** those two toolkit
files, and also compile `IOSPlatform.m` with ARC and Foundation/CoreText.
All other HLE source files remain unchanged.

`MainBridge.c` supplies the native entry symbol while the reviewed desktop
entry is renamed to `ra2_desktop_main`. It checks the UIKit main thread,
arguments, and configured writable settings directory, and calls
`SDL_SetMainReady` before the engine. It rejects the desktop recorder's
subprocess option and `--args` files, which the desktop entry expands before
option parsing and could otherwise use to bypass that guard. Tests compile the
production bridge with a stub engine; they never enter the commercial game.
This is an entry guard, not the complete TonTon lifecycle
or save-file integration.

The font adapter asks CoreText for a readable system font file, preserving
game-registered fonts. It supports Latin Windows-family substitution and a
Chinese fallback without spawning `fc-match`, downloading fonts, or copying
system font assets. Failure to obtain a readable file is explicit (`NULL`).

Before entering the native engine on the UIKit main thread:

1. Call `SDL_SetMainReady()` when using TonTon's custom UIKit entry point.
2. Call `ra2_ios_set_user_directory` with this game's writable UserData path.
3. Stop on configuration failure. Do not redirect writes into the signed bundle.

The settings path helper does not copy or migrate existing game saves. A full
port still needs the game's file-write paths, touch input, lifecycle handling,
and a reliable way back to the library. The desktop main function is not yet
an application integration API.

For the private iOS SDL2 build, `prepare_touch_overlay.py` generates a reviewed
replacement for `SDL_uikitview.m`; compile it with this directory on the include
path and the original UIKit source directory on the quote include path. Replace
only that object in a copy of the SDL2 archive used by the two Red Alert
frameworks. The overlay maps taps to left click, drags to box selection, and
stationary two-finger taps to right click at their midpoint. It passes actual
mouse and trackpad input to the original SDL path. This affects neither the
BoxedWine fallback nor Switch games. Device gesture usability still needs review.

Device evidence on M2 / iPadOS 16.1 so far: dynamic 4 GiB guest address-space
reservation and heap checks, native framework loading and entry resolution,
and actual CoreText file discovery plus FreeType Latin/Chinese text raster.
No game entry was invoked by those probes. Air device compatibility and game
performance remain unverified. A successful C lift or link does not establish
semantic correctness of every game function or campaign playability.
