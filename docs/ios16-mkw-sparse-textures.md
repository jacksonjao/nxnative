# Mario Kart World terrain on the legacy Metal renderer

On the iPad14,6 running iPadOS 16.1, the opening can render before the GPU
starts rejecting submissions. A separate CPU crash was traced to a stale
Metal buffer in the legacy address index and fixed in the index. The
subsequent run still reached the GPU fault and was stuck around 2 FPS; it
did not reach the original CPU crash point at normal speed.

The first failed texture is an NVN unsigned BC6H sparse 2D array, 8192×8192,
68 slices, 12 mip levels. This OS uses an RGBA16Float fallback. Allocating
the whole array densely is impractical even before accounting for other
terrain textures. The newer placement sparse path cannot be copied over:
the legacy API allocates backing tiles itself and cannot map one physical
tile into two live texture addresses.

`make -C dm/gfx/tex/tests check_legacy_sparse_bc6h` verifies the relevant
legacy Metal operations on a Mac with Apple silicon. The test deswizzles
and decodes a synthetic 64 KiB NVN page, maps a 256×256 region of slice 67,
and reads back the RGBA16Float pixels. On the tested GPU this region spans
32 tiles of 64×32 pixels and consumes 512 KiB. It also verifies all six
guest mip tail levels: NVN starts the tail at level 6, while Metal uses
regular tiles for levels 6 and 7 and starts its tail at level 8.

The test covers storage and transfer only. The runtime still needs to
track sparse page updates and preserve shared writable terrain pages.
Confirm the graphics fix on the iPad by entering a race and checking
that submissions complete without faults.
