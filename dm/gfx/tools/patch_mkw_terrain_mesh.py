#!/usr/bin/env python3
"""Repair the verified MKW terrain shadow pair generated for Metal 3.

Apply only to the recorded translation. Takes locally generated MSL as
input and writes a new pair, leaving the game and the input files intact.
"""
import argparse
import hashlib
from pathlib import Path


MESH = '0f972afb8a9dbd9a_b.metal'
PIXEL = '3cafb02cdf0d87fb_b.metal'
MESH_SHA = '943364e44dc818938d00df2788d1ca83013e82260174cb7befa2d6bc5738be3f'
PIXEL_SHA = 'ba74fa9d4434728a5ce4282397b262251b0fb6947d710ab1a44de1b7af00ddc2'


def replace(source, before, after, count):
    if source.count(before) != count:
        raise ValueError(f'unexpected number of sites: {before}')
    return source.replace(before, after)


def read(path, digest):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        raise ValueError(f'unrecognized input: {path.name}')
    return raw.decode()


def repair(mesh, pixel):
    # The guest body stores groups of 32 vertices at 768-byte intervals:
    # four position columns and two UV columns. Primitive words are in a
    # separate stream beginning at byte 3072, not a seventh vertex column.
    mesh = replace(mesh, 'uint b = 36u + (n / 32u) * 224u + n % 32u;',
                   'uint b = 36u + (n / 32u) * 192u + n % 32u;', 4)
    mesh = replace(mesh, 'uint b = 36u + (n / 32u) * 192u + n % 32u;\n        dm_prim_t p;',
                   'dm_prim_t p;', 2)
    mesh = replace(mesh, 'p.p0 = float4(0.0, 0.0, 0.0, 1.0);',
                   'p.p0 = float4(0.0, as_type<float>(_35[768u + n]), 0.0, 1.0);', 2)
    # Adjacent lanes update different bytes of the same packed index word.
    # Every access racing with compare-exchange must be atomic.
    mesh = replace(mesh, 'float _1185 = as_type<float>(_35[int(_1177)]);',
                   'float _1185 = as_type<float>(atomic_load_explicit('
                   '(threadgroup atomic_uint*)&_35[int(_1177)], memory_order_relaxed));', 1)
    # The mesh and pixel entries are each reused in other combinations.
    # Preserve the locations on both sides: a pair-specific varying remap
    # must be selected in the runtime, not patched into these shared entries.
    if pixel.count('m_31 [[user(locn0)]];') != 1:
        raise ValueError('unexpected shared pixel interface')
    return mesh, pixel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mesh', type=Path)
    parser.add_argument('pixel', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    mesh, pixel = repair(read(args.mesh, MESH_SHA), read(args.pixel, PIXEL_SHA))
    args.output.mkdir(parents=True, exist_ok=True)
    for name, source in ((MESH, mesh), (PIXEL, pixel)):
        with (args.output / name).open('x') as output:
            output.write(source)


if __name__ == '__main__':
    main()
