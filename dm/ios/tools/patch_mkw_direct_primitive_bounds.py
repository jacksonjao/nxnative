"""Generate guarded Metal 3 variants from the exact local direct terrain MSL.

The source shaders are supplied by the user's existing Mario Kart World build.
This opt-in packaging tool does not change the shared shader chain.
"""
import argparse
import hashlib
from pathlib import Path
import re


# Source hash, threadgroup words, index stream byte offset, and packed write.
VARIANTS = {
    '0f972afb8a9dbd9a': (
        '356a99455fbe61927d55affaa4550a3e9b5517c04a0aeee180ba4574e1a05fcb',
        981, 3732, '_1173', '_1177',
    ),
    '11ed01f0618a65a3': (
        '99c6f4916f00d4b20dd3dcf989785c08d34df099ac651d6ce255e6f970ac2d96',
        853, 3220, '_1420', '_1424',
    ),
}


def transform(raw, key):
    expected, capacity, offset, arg, local = VARIANTS[key]
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError(f'{key}: unexpected direct terrain input')
    source = raw.decode()
    header = rf'(void _48\(thread const int& {arg}, [^\n]+\n\{{\n[^\n]*\b{local}\s*=\s*[^\n]+\n)'
    source, count = re.subn(header, rf'\g<1>    if (uint({arg}) >= {capacity * 4}u || uint({local}) >= {capacity}u) return;\n', source)
    if count != 1:
        raise ValueError(f'{key}: missing packed index writer')
    old = f'''    for (uint n = dm_lid; n < np * 3u; n += 32u)
    {{
        uint at = {offset}u + n;
        dm_out.set_index(n, (_35[at >> 2] >> ((at & 3u) * 8u)) & 0xffu);
    }}'''
    new = f'''    for (uint n = dm_lid; n < np; n += 32u)
    {{
        uint at = {offset}u + 3u * n;
        uint3 ix;
        for (uint j = 0; j < 3u; ++j) {{
            uint byte = at + j;
            ix[j] = (_35[byte >> 2] >> ((byte & 3u) * 8u)) & 0xffu;
        }}
        // Keep primitive numbering and all valid geometry. A malformed
        // triangle has no vertex outside the declared Metal mesh output.
        if (any(ix >= uint3(128u))) ix = uint3(0u);
        for (uint j = 0; j < 3u; ++j) dm_out.set_index(3u * n + j, ix[j]);
    }}'''
    if source.count(old) != 2 or '128, 64, metal::topology::triangle' not in source:
        raise ValueError(f'{key}: unexpected mesh output capacity')
    source = source.replace(old, new)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Directory with the two direct .metal inputs')
    parser.add_argument('output', type=Path, help='New directory for the guarded .metal variants')
    args = parser.parse_args()
    variants = {key: transform((args.input / (key + '.metal')).read_bytes(), key)
                for key in VARIANTS}
    args.output.mkdir(parents=True, exist_ok=False)
    for key, source in variants.items():
        (args.output / (key + '.metal')).write_text(source)


if __name__ == '__main__':
    main()
