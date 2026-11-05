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

The legacy renderer now allocates a sparse RGBA16Float array for this
specific layout. It reads only mapped 64 KiB guest pages and queues the
corresponding Metal mappings and uploads ahead of replay. CPU writes
and guest remaps invalidate the cached view; a clean tile is left in
place so a GPU copy into that tile is not overwritten by a later lookup.
The copy does not mirror GPU writes between distinct virtual aliases.

`make -C dm/gfx/tex/tests check_legacy_sparse_bc6h` drives the production
uploader using a synthetic guest page table on an Apple GPU. It reads
back a tile in slice 67 and all six guest mip-tail levels, then exercises
a dirty rewrite, unmap and remap. On the tested GPU a 256×256 guest page
spans 32 tiles of 64×32 pixels; NVN's tail starts at level 6 and Metal's
at level 8. Validate the rendering result separately on iPad by entering
a race and checking that submissions complete without GPU faults.
