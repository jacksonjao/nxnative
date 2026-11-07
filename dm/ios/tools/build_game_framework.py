#!/usr/bin/env python3
"""Build a TonTon Route C code framework from already rewritten modules.

Inspired by NX2Apple patches 0045–0051 (MIT). This adapter preserves this
fork's signed __TEXT layout and shader chain, rather than relabelling newer
upstream output. Game assets and saves stay outside the framework.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).resolve().parent


def host_sections(path):
    """Read bounded arm64 sections without executing or changing the old host."""
    total = path.stat().st_size
    with path.open('rb') as f:
        header = f.read(32)
        if len(header) != 32 or struct.unpack_from('<I', header)[0] != 0xfeedfacf:
            raise ValueError('reference host must be a thin 64-bit Mach-O')
        if struct.unpack_from('<I', header, 4)[0] != 0x100000c:
            raise ValueError('reference host must be arm64')
        count, length = struct.unpack_from('<II', header, 16)
        if length > total - 32 or length > 16 << 20 or count > length // 8:
            raise ValueError('invalid reference load commands')
        commands = f.read(length)
    at, sections = 0, {}
    for _ in range(count):
        if at + 8 > length:
            raise ValueError('truncated reference load command')
        cmd, size = struct.unpack_from('<II', commands, at)
        if size < 8 or at + size > length:
            raise ValueError('invalid reference load command size')
        if cmd == 0x19:
            if size < 72:
                raise ValueError('truncated reference segment')
            nsect = struct.unpack_from('<I', commands, at + 64)[0]
            if 72 + nsect * 80 > size:
                raise ValueError('truncated reference section table')
            for i in range(nsect):
                p = at + 72 + i * 80
                name = commands[p:p+16].split(b'\0')[0].decode('ascii')
                segment = commands[p+16:p+32].split(b'\0')[0].decode('ascii')
                size_, offset = struct.unpack_from('<QI', commands, p + 40)
                kind = struct.unpack_from('<I', commands, p + 64)[0] & 0xff
                if kind in (1, 0xc, 0x12):
                    continue  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
                if offset > total or size_ > total - offset:
                    raise ValueError('reference section extends beyond the file')
                if size_ and offset < 32 + length:
                    raise ValueError('reference section overlaps load commands')
                if (segment, name) in sections:
                    raise ValueError('duplicate reference section')
                sections[segment, name] = (offset, size_)
        at += size
    if at != length:
        raise ValueError('reference load command count and size disagree')
    return sections


def verify_reference_mod0(reference, module, text, writable, text_end):
    offset, length = text
    w_offset, w_length = writable
    split = (text_end + 0x3fff) & ~0x3fff
    if not 0 < split <= length or w_length > length - split:
        raise ValueError(f'{module}: reference guest section does not match the declared layout')
    # The loader uses a module-relative pointer. Its readonly view of the
    # data range aliases the writable source, not the hole in __TEXT.
    with reference.open('rb') as f:
        f.seek(offset + 4)
        mod0, = struct.unpack('<I', f.read(4))
        if 8 <= mod0 <= split - 8:
            position = offset + mod0
        elif split <= mod0 <= split + w_length - 8:
            position = w_offset + mod0 - split
        else:
            raise ValueError(f'{module}: MOD0 offset outside reference guest image')
        f.seek(position)
        if f.read(4) != b'MOD0':
            raise ValueError(f'{module}: no MOD0 at declared reference guest offset')


def reference_assembly(reference, namespace, modules, output, text_ends):
    if not re.fullmatch(r'[A-Za-z0-9]{2}', namespace or ''):
        raise ValueError('reference-host requires a two-character namespace')
    sections = host_sections(reference)
    lines, flags, proof = [], ['-Wl,-segprot,__TEXT,rwx,rx'], []
    for module in modules:
        for old, new in [(('__TEXT', '__dm'+namespace+module+'img'), ('__TEXT', '__dm'+module+'img')),
                         (('__DM'+namespace+module+'W', '__img'), ('__DM'+module+'W', '__img'))]:
            if old not in sections or any(len(s) > 16 for s in new):
                raise ValueError(f'missing or unsupported reference module {old}')
            offset, length = sections[old]
            if not length or length % 0x4000:
                raise ValueError('reference guest section must have complete 16K pages')
            # .incbin the original signed bytes, including its original holes
            # and padding. Do not regenerate code from a mutable build folder.
            source = str(reference)
            if any(c in source for c in '\n\r"\\'):
                raise ValueError('reference path is unsafe for assembly')
            lines += [f'    .section {new[0]},{new[1]}', '    .p2align 14',
                      f'    .incbin "{source}", {offset:#x}, {length:#x}', '    .p2align 14']
            with reference.open('rb') as f:
                f.seek(offset)
                digest = hashlib.sha256()
                left = length
                while left:
                    block = f.read(min(left, 4 << 20))
                    if not block:
                        raise ValueError('reference section truncated during read')
                    digest.update(block)
                    left -= len(block)
            proof.append(dict(module=module, segment=old[0], section=old[1],
                              bytes=length, sha256=digest.hexdigest()))
        verify_reference_mod0(reference, module, sections['__TEXT', '__dm'+namespace+module+'img'],
                              sections['__DM'+namespace+module+'W', '__img'], text_ends[module])
        flags.append(f'-Wl,-segprot,__DM{module}W,rw,rw')
    output.write_text('\n'.join(lines)+'\n')
    return flags, proof


def build(args):
    title = args.game.upper()
    if not re.fullmatch(r'[0-9A-F]{16}', title):
        raise ValueError('game must be a 16-digit title ID')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', args.min_os):
        raise ValueError('min-os must be a numeric OS version')
    if not args.modules or any(not re.fullmatch(r'[A-Za-z0-9]+', m) for m in args.modules):
        raise ValueError('module names must contain only ASCII letters and digits')
    if len(args.modules) != len(set(args.modules)):
        raise ValueError('duplicate modules')
    patched = args.patched.resolve(strict=True)
    nro = patched / 'nro.tsv'
    if nro.exists() and any(l.strip() and not l.startswith(('#', 'refused\t')) for l in nro.read_text().splitlines()):
        raise ValueError('packed NRO frameworks require a matching NRO loader, not yet supported')
    for module in args.modules:
        for suffix in ['patched.bin', 'fixups.tsv', 'gates.tsv', 'obs.tsv', 'cuts.tsv']:
            if not (patched / f'{module}.{suffix}').is_file():
                raise ValueError(f'missing module input {module}.{suffix}')
    chain_match = re.search(r'^#define DMSH_CHAIN "([0-9a-f]+)"',
                            (ROOT / 'dm/gfx/nvn/dmsh_chain.h').read_text(), re.M)
    if chain_match is None:
        raise ValueError('missing shader chain identity in dmsh_chain.h')
    chain = chain_match.group(1)
    name = f'DmGame{title}.framework'
    out = args.output.resolve()
    if out.exists():
        raise ValueError(f'output already exists: {out}, retained for inspection')
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tonton-game-framework-', dir=out.parent) as temp:
        work = Path(temp)
        fw = work / name
        (fw / 'dm').mkdir(parents=True)
        asm = work / 'embed.S'
        reference_proof = None
        if args.reference_host:
            text_ends = {}
            for module in args.modules:
                with (patched / f'{module}.fixups.tsv').open() as fixups:
                    for line in fixups:
                        fields = line.split()
                        if len(fields) == 3 and fields[:2] == ['#', 'TEXT_END']:
                            text_ends[module] = int(fields[2], 16)
                            break
                    else:
                        raise ValueError(f'{module}: missing TEXT_END in fixups')
            flags, reference_proof = reference_assembly(args.reference_host.resolve(strict=True),
                                                        args.namespace, args.modules, asm, text_ends)
        else:
            if args.namespace:
                raise ValueError('namespace is only used with reference-host')
            flags = subprocess.check_output([sys.executable, str(TOOLS / 'gen_embed.py'),
                                             str(patched), str(asm), *args.modules], text=True).split()
        marker = work / 'marker.c'
        marker.write_text('__attribute__((visibility("default"),used)) const unsigned char dm_game_image_marker = 1;\n')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target',
                        f'arm64-apple-ios{args.min_os}', '-isysroot', sdk, '-dynamiclib',
                        '-fvisibility=hidden', '-Wl,-install_name,@rpath/' + name + '/DmGame',
                        *flags, str(marker), str(asm), '-o', str(fw / 'DmGame')], check=True)
        subprocess.run([sys.executable, str(TOOLS / 'set_text_maxprot.py'), str(fw / 'DmGame')], check=True)
        for module in args.modules:
            for suffix in ['fixups.tsv', 'gates.tsv', 'obs.tsv', 'cuts.tsv']:
                shutil.copyfile(patched / f'{module}.{suffix}', fw / 'dm' / f'{module}.{suffix}')
        manifest = dict(schema=1, title_id=title, name=args.name or title,
                        display_version=args.display_version, package_version=args.package_version,
                        modules=args.modules, nro_count=0, chain='b-' + chain, loader='FR',
                        framework=name, framework_executable='DmGame', image_marker='dm_game_image_marker',
                        min_os=args.min_os, tonton_host_abi='tonton-signed-text-v1')
        if reference_proof:
            manifest['reference_code_sections'] = reference_proof
            # A mutable patched folder is not proof of the live CPU tables.
            # A device migration must bind/read back its tables before signing
            # and explicitly clear this gate. Merely extracting code is unsafe.
            manifest['unbound_resource_tables'] = True
        (fw / 'game.manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        (fw / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='DmGame',
            CFBundleIdentifier='com.tonytan.game.' + title.lower(), CFBundlePackageType='FMWK',
            CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion=args.min_os)))
        # Ad-hoc is a staging signature. The complete app installer must sign
        # nested code with the same device-valid identity as the containing app.
        subprocess.run(['codesign', '--force', '--sign', '-', str(fw)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(fw)], check=True)
        os.rename(fw, out)
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--game', required=True)
    ap.add_argument('--patched', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--modules', nargs='+', required=True)
    ap.add_argument('--reference-host', type=Path,
                    help='migrate exact signed guest sections from an existing combined host')
    ap.add_argument('--namespace', help='original two-character embedded namespace')
    ap.add_argument('--name')
    ap.add_argument('--min-os', default='16.1')
    ap.add_argument('--display-version', default='')
    ap.add_argument('--package-version', default='')
    args = ap.parse_args()
    try:
        print(json.dumps(build(args), ensure_ascii=False, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        ap.exit(1, f'{e}\n')


if __name__ == '__main__':
    main()
