#!/usr/bin/env python3
"""Lower a single R32Uint fragment atomic-max image for the legacy iOS host.

The runtime supplies an initialized, padded shadow and ordered copyback. Native
Mac shaders and reflection retain their texture atomic ABI. Unsupported image
operations fail closed instead of compiling an unavailable iOS texture method.
"""
import copy
import hashlib
import re

HELPER = '''
static inline uint4 dm_legacy_atomic_max_2d(device atomic_uint* image,
        uint2 xy, uint value, constant uint* layout) {
    if (xy.x >= layout[0] || xy.y >= layout[1] || layout[2] != 1u || layout[3] != 1u)
        return uint4(0u);
    ulong at = ulong(xy.y) * ulong(layout[4]) + ulong(xy.x);
    if (at >= ulong(layout[5])) return uint4(0u);
    uint previous = atomic_fetch_max_explicit(image + at, value, memory_order_relaxed);
    return uint4(previous, 0u, 0u, 0u);
}
'''


def closing(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i
    raise ValueError('Unbalanced call or signature')


def arguments(text):
    parts, start, depth = [], 0, 0
    for i, c in enumerate(text):
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        elif c == ',' and depth == 0:
            parts.append(text[start:i].strip()); start = i + 1
    parts.append(text[start:].strip())
    return parts


def lower(source):
    clean = re.sub(r'//[^\n]*|/\*.*?\*/', ' ', source, flags=re.S)
    if 'dm_legacy_atomic' in clean or re.search(r'\[\[\s*buffer\s*\(\s*29\s*\)', clean):
        raise ValueError('Compatibility parameter names or slot are occupied')
    entries = list(re.finditer(r'\b(fragment|vertex|kernel)\s+(\w+)\s+(\w+)\s*\(', clean))
    if len(entries) != 1 or entries[0].group(1, 2) != ('fragment', 'void'):
        raise ValueError('Only one void fragment entry is proven')
    if re.search(r'\[\[\s*(color|sample_mask|depth)\s*\(', clean):
        raise ValueError('Output or sample-mask ordering is not proven')
    images = list(re.finditer(r'\btexture\w*\s*<[^;]+?access::(?:write|read_write)[^;]*;', clean))
    declaration = re.compile(r'texture2d\s*<\s*uint\s*,\s*access::read_write\s*>\s+(\w+)\s*\[\[\s*id\s*\(\s*(\d+)\s*\)\s*\]\]\s*;')
    matches = list(declaration.finditer(clean))
    if len(images) != 1 or len(matches) != 1:
        raise ValueError('Exactly one unsigned 2D read/write image is required')
    name, aid = matches[0].group(1, 2)
    refs = set(re.findall(r'\b(\w+)\.' + re.escape(name) + r'\b', clean))
    if len(refs) != 1:
        raise ValueError('Image argument ownership is ambiguous')
    image = next(iter(refs)) + '.' + name
    pattern = re.compile(re.escape(image) + r'\.(atomic_fetch_max|get_width|get_height)\s*\(')
    edits, atomics = [], 0
    for match in pattern.finditer(clean):
        end = closing(clean, match.end() - 1)
        args = arguments(clean[match.end():end])
        if match[1] == 'atomic_fetch_max':
            if len(args) != 2:
                raise ValueError('Unexpected atomic operation arguments')
            replacement = f'dm_legacy_atomic_max_2d({image}, {args[0]}, {args[1]}, dm_legacy_atomic_layout)'
            atomics += 1
        else:
            if args != ['']:
                raise ValueError('Only base-mip image dimensions are proven')
            replacement = 'dm_legacy_atomic_layout[' + ('0' if match[1] == 'get_width' else '1') + ']'
        edits.append((match.start(), end + 1, replacement))
    if not atomics:
        raise ValueError('No supported atomic operation')
    remaining = clean
    for start, end, _ in reversed(edits):
        remaining = remaining[:start] + '0' + remaining[end:]
    remaining = declaration.sub('', remaining)
    if re.search(r'\b' + re.escape(name) + r'\b', remaining):
        raise ValueError('Unproven image access, alias or escape')
    out = clean
    for start, end, replacement in reversed(edits):
        out = out[:start] + replacement + out[end:]
    out = declaration.sub('device atomic_uint* ' + name + ' [[id(' + aid + ')]];', out)
    entry = re.search(r'\bfragment\s+void\s+\w+\s*\(', out)
    if entry is None:
        raise ValueError('Lowering removed the fragment entry')
    end = closing(out, entry.end() - 1)
    out = out[:end] + ', constant uint* dm_legacy_atomic_layout [[buffer(29)]]' + out[end:]
    out = out[:entry.start()] + HELPER + '\n' + out[entry.start():]
    return out, {'kind': 'fragment-uint-max-2d-v1', 'image_name': name,
                 'image_aid': int(aid), 'parameter_slot': 29, 'atomic_calls': atomics,
                 'original_sha256': hashlib.sha256(source.encode()).hexdigest(),
                 'lowered_sha256': hashlib.sha256(out.encode()).hexdigest()}


def needed(source):
    return bool(re.search(r"\.atomic_\w+\s*\(", source))


def reflection(source, native, library_sha256):
    """Return an independent iOS record; never mutate the native reflection."""
    if not needed(source):
        if any(b.get('atomic') for b in native.get('bindings', [])):
            raise ValueError('Atomic reflection without a native atomic expression')
        return copy.deepcopy(native)
    lowered, proof = lower(source)
    if native.get('stage') != 'ps' or native.get('msl_entry_kind') != 'fragment':
        raise ValueError('Legacy atomic image requires fragment reflection')
    entry = re.search(r'\bfragment\s+void\s+(\w+)\s*\(', source)
    if not entry or native.get('entry') != entry[1]:
        raise ValueError('Fragment entry and reflection disagree')
    if set(re.findall(r'\[\[\s*buffer\s*\(\s*(\d+)\s*\)', source)) != {'0'}:
        raise ValueError('Only the ordinary argument buffer ABI is supported')
    raster = native.get('raster', {})
    if raster.get('colors') != [] or raster.get('sample_mask', 0):
        raise ValueError('Color or sample-mask output ordering is unsupported')
    out = copy.deepcopy(native)
    found = []; ids = set(); samplers = 0; borders = 0; bits = set()
    bindings = out.get('bindings', [])
    for b in bindings:
        aid, kind, ty = b.get('arg_id'), b.get('kind'), b.get('msl_type', '')
        if type(aid) is not int or not 0 <= aid < 192 or aid in ids or 'array<' in ty:
            raise ValueError('Argument IDs must be unique scalar bindings')
        ids.add(aid)
        limits = {'cbuf': 16, 'tex': 256, 'samp': 256, 'samp_tex': 256, 'samp_id': 4096}
        if kind in limits and (type(b.get('reg')) is not int or not 0 <= b['reg'] < limits[kind]):
            raise ValueError('Unresolved or out-of-range companion register')
        if kind == 'drvcb' and b.get('bank') not in (0, 2):
            raise ValueError('Unsupported driver constant bank')
        if 'border_bit' in b:
            bit, name = b['border_bit'], b.get('msl_name')
            if (kind not in ('samp', 'samp_tex', 'samp_id') or
                    type(bit) is not int or not 0 <= bit < 32 or bit in bits or
                    not isinstance(name, str) or not name.endswith('_w') or
                    sum(x.get('msl_name') == name[:-2] and x.get('kind') == kind and
                        x.get('reg') == b.get('reg') and 'border_bit' not in x for x in bindings) != 1):
                raise ValueError('Unproven border sampler companion')
            bits.add(bit)
        if kind == 'img':
            if b.get('msl_name') != proof['image_name'] or aid != proof['image_aid'] or b.get('atomic') is not True or re.sub(r'\s+', '', ty) != 'texture2d<uint,access::read_write>':
                raise ValueError('Image proof and reflection disagree')
            reg = b.get('reg')
            if type(reg) is not int or not 0 <= reg < 32:
                raise ValueError('Unresolved image register')
            found.append(b)
        elif kind in ('cbuf', 'c1', 'support', 'drvcb'):
            if not ty.startswith('constant ') or b.get('rw'):
                raise ValueError('Only read-only constants may accompany the image')
        elif kind == 'border':
            borders += 1
            if b.get('msl_name') != 'dm_border' or ty != 'constant dm_border_t*' or b.get('rw') or b.get('atomic'):
                raise ValueError('Unproven border constant companion')
        elif kind in ('samp', 'samp_tex', 'samp_id'):
            if ty != 'sampler': raise ValueError('Only scalar samplers are supported')
            samplers += 1
        elif kind == 'tex':
            if not ty.startswith(('texture', 'depth')) or ('access::' in ty and not re.search(r'access::(read|sample)\s*>', ty)) or b.get('rw') or b.get('atomic'):
                raise ValueError('Sampled texture must be read-only')
        else:
            raise ValueError('Unproven image companion binding: ' + str(kind))
    if borders != int(bool(bits)):
        raise ValueError('Border samplers require exactly one read-only border block')
    if len(found) != 1 or samplers > 16:
        raise ValueError('Expected one image and at most sixteen samplers')
    b = found[0]
    proof.update(schema=1, image_reg=b['reg'], pixel_format='R32Uint', library_sha256=library_sha256)
    if not re.fullmatch(r'[0-9a-f]{64}', library_sha256):
        raise ValueError('Missing compiled library digest')
    b.update(kind='img_atomic_2d', msl_type='device atomic_uint*', rw=True)
    b.pop('atomic', None)
    out['legacy_image_atomic'] = proof
    return out
