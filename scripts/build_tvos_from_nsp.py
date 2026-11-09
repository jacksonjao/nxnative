#!/usr/bin/env python3
"""Build a Switch game you own into an Apple TV app, and optionally install it.

  python3 scripts/build_tvos_from_nsp.py "<NSP folder>" -k prod.keys --team-id <TEAM> [--device <Apple TV ID>] [--language es-419] [--mode docked]

Steps: build_ipa_from_nsp.py prepares the game (extraction, rewritten code, shaders; the long step, once per game), dm/ios/tools/build_ipa.sh
with DM_TVOS=1 generates the Apple TV project (dm/ios/project_tv.yml), xcodebuild compiles and signs it, and with --device devicectl installs
it and copies the game's RomFS image into the app's Library/Caches. The app opens on its settings screen (dm/ios/SourcesTV/TVPlayers.m):
language, docked or handheld and the game's other launcher settings, chosen with the Siri Remote or a controller and kept for the next launch.

Apple TV GPUs have no BC texture formats: the host stores BC textures decompressed (nvn_mtl.m no_bc). NVN games need Metal 4 (A15 and later);
Vulkan games also run on older GPUs through the classic presenter. Exit code: 0 on success, 1 on any failure.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TITLE_RE = re.compile(r'^([0-9A-Fa-f]{16})_build$')
CACHES = 'Library/Caches'


def fail(msg: str) -> None:
    print(f'[RED] {msg}', file=sys.stderr)
    sys.exit(1)


def run(argv, **kw) -> None:
    print('$ ' + ' '.join(str(a) for a in argv), flush=True)
    if subprocess.run([str(a) for a in argv], **kw).returncode:
        fail(f'{Path(str(argv[0])).name} failed')


def chain() -> str:
    m = re.search(r'#define DMSH_CHAIN "(.*)"', (REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    return m.group(1) if m else ''


def build_dir(folder: Path):
    """The NSP script's build folder (<title ID>_build), its package (patched_<package>) and title ID, once it has run."""
    for b in sorted(p for p in folder.iterdir() if p.is_dir() and TITLE_RE.match(p.name)):
        patched = sorted(p for p in b.glob('patched_*') if p.is_dir())
        if patched:
            return b, patched[-1].name[len('patched_'):], TITLE_RE.match(b.name).group(1)
    return None, None, None


def prepared(build: Path, package: str) -> bool:
    shaders = build / 'shader/ios'
    libs = (shaders / f'b-{chain()}/inputs.tsv', shaders / 'vk/vk_shaders.metallib', shaders / 'gl/gl_shaders.metallib')
    return (build / 'extract' / package / 'RomFS.img').is_file() and any(p.is_file() for p in libs)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('folder', type=Path, help='the game folder: base NSP / XCI, update and DLC')
    ap.add_argument('-k', '--keys', type=Path, help='prod.keys (needed for the first build of a game)')
    ap.add_argument('--team-id', required=True, help='Apple developer team ID (Xcode > Settings > Accounts)')
    ap.add_argument('--device', help='the Apple TV to install on (xcrun devicectl list devices); without it the app is only built')
    ap.add_argument('--bundle-id', help='default: org.nxnative.<title ID>.tv')
    ap.add_argument('-l', '--language', default='', help='the game language the settings screen starts with, e.g. es-419, es-ES, en-US')
    ap.add_argument('--mode', choices=['docked', 'handheld'], default='docked', help='the console mode the settings screen starts with')
    ap.add_argument('--show-fps', action='store_true')
    a = ap.parse_args()
    folder = a.folder.expanduser().resolve()
    if not folder.is_dir():
        fail(f'no such folder: {folder}')
    env = dict(os.environ, PATH=os.pathsep.join([str(Path(sys.executable).parent), os.environ.get('PATH', '')]))   # the engine's python3 calls take this interpreter

    build, package, tid = build_dir(folder)
    if not (build and prepared(build, package)):
        cmd = [sys.executable, REPO / 'scripts/build_ipa_from_nsp.py', folder, '--prepare-xcode', '--keep-extracted', '--gpu', 'none', '--romfs', 'separate',
               '--allow-other-metal', '--progress', 'lines', '--team-id', a.team_id]
        if a.keys:
            cmd += ['-k', a.keys]
        if a.language:
            cmd += ['-l', a.language]
        run(cmd, cwd=REPO, env=env)
        build, package, tid = build_dir(folder)
        if not (build and prepared(build, package)):
            fail('the NSP script finished without game files or shaders for this game (see its log)')

    bundle = a.bundle_id or f'org.nxnative.{tid.lower()}.tv'
    project, derived = build / 'tvos-xcode', build / 'tvos-derived'
    romfs = build / 'extract' / package / 'RomFS.img'
    penv = dict(env, GAME=tid, W=str(build), PATCHED=str(build / f'patched_{package}'), ROMFS=str(romfs), MSL_IOS=str(build / 'shader/ios'), AOC='',
                DM_TVOS='1', DM_COPY_ROMFS='NO', DM_SHOW_FPS='1' if a.show_fps else '0', DM_BUNDLE_ID=bundle, DM_TEAM_ID=a.team_id,
                DM_XCODE_PROJECT_DIR=str(project), DM_XCODE_DERIVED_DATA=str(derived), FONT_PY=sys.executable)
    if a.language:
        penv['DM_LANG'] = a.language
    derived_profile = build / 'profile'
    if (derived_profile / tid / 'game.tsv').is_file():   # a version the profile was not brought up on (the NSP script's derived profile)
        penv.update(DM_GAMES_DIR=str(derived_profile), DM_GAMES_FIRST='1')
    icon = build / 'extract' / package / 'icon.jpg'
    if icon.is_file():
        penv['DM_ICON'] = str(icon)
    run(['bash', REPO / 'dm/ios/tools/build_ipa.sh', '--prepare-xcode'], cwd=REPO, env=penv)

    # The settings screen starts in the requested mode; the player's choice there is kept for later launches
    settings = project / 'Gen/dm/launcher.json'
    if settings.is_file():
        data = json.loads(settings.read_text())
        for s in data.get('settings', []):
            if s.get('env') == 'DM_OPMODE':
                s['default'] = '0' if a.mode == 'handheld' else '1'
        settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')

    schemes = sorted(p.stem for p in (project / 'DmIOS.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
    if not schemes:
        fail(f'the generated project has no scheme ({project})')
    run(['xcodebuild', '-project', project / 'DmIOS.xcodeproj', '-scheme', schemes[0], '-configuration', 'Release',
         '-destination', f'platform=tvOS,id={a.device}' if a.device else 'generic/platform=tvOS',
         '-derivedDataPath', derived, '-allowProvisioningUpdates', 'build'], cwd=REPO)
    app = derived / 'Build/Products/Release-appletvos/DmIOS.app'
    print(f'app: {app}')
    if a.device:
        run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', a.device, app])
        print(f'Copying the game files ({romfs.stat().st_size / 2**30:.1f} GB) to the Apple TV: a few minutes over the network', flush=True)
        run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', a.device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
             '--source', romfs, '--destination', f'{CACHES}/romfs.img'])
    print('done')


if __name__ == '__main__':
    main()
