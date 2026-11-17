# iCloud through CloudKit for the packed Mac app (docs/cloudkit-saves.md; dm/ios/Sources/SaveBackend.swift): kept out of pack_app.py, which calls the two functions below.
#   DM_CLOUDKIT_CONTAINER=iCloud.<id>          the container the Mac, iPhone and Apple TV apps share: Info.plist's DMCloudKitContainer, which turns the settings' iCloud choice on
#   DM_MAC_PROVISIONING_PROFILE=<path>         a Mac development profile (a paid Apple developer account) for the app's bundle ID with iCloud (CloudKit) and that container:
#                                              copied to Contents/embedded.provisionprofile; the launcher is signed with the entitlements it allows (--sign must be that account's
#                                              "Apple Development" identity). Without it the app is packed as before, and its settings show why iCloud cannot be chosen
import os, plistlib, re, shutil
from pathlib import Path


def swift_sources(dm):   # pack_app.swift_sources: the settings' Save sync choice and the CloudKit code, with the Mac launcher's other sources (where a checkout has them)
    return [f for f in (Path(dm) / 'ios/Sources/SaveBackend.swift', Path(dm) / 'ios/Sources/SaveBackendSection.swift') if f.is_file()]


def container():
    c = os.environ.get('DM_CLOUDKIT_CONTAINER', '').strip()
    if c and not re.fullmatch(r'iCloud\.[A-Za-z0-9.\-]+', c): raise SystemExit(f'DM_CLOUDKIT_CONTAINER={c}: an iCloud container identifier is iCloud.<reverse DNS>')
    return c


def info(p):   # pack_app.info_plist
    if container(): p['DMCloudKitContainer'] = container()
    return p


def profile_entitlements(path):
    data = Path(path).read_bytes()
    a, b = data.find(b'<?xml'), data.find(b'</plist>')
    if a < 0 or b < 0: raise SystemExit(f'{path}: not a provisioning profile')
    return plistlib.loads(data[a:b + len(b'</plist>')]).get('Entitlements', {})


def sign_args(app):   # pack_app.sign: codesign arguments for the bundle (its launcher), after placing the profile; () when the app is not packed for CloudKit
    prof, c = os.environ.get('DM_MAC_PROVISIONING_PROFILE', '').strip(), container()
    if not prof or not c: return ()
    ent = profile_entitlements(prof)
    ids = ent.get('com.apple.developer.icloud-container-identifiers') or []
    if c not in ids and '*' not in ids: raise SystemExit(f'{prof}: the profile has no iCloud container {c} (it has {ids or "none"})')
    want = {k: ent[k] for k in ('com.apple.application-identifier', 'com.apple.developer.team-identifier') if k in ent}
    want['com.apple.developer.icloud-container-identifiers'] = [c]
    want['com.apple.developer.icloud-services'] = ['CloudKit']
    shutil.copyfile(prof, Path(app) / 'Contents/embedded.provisionprofile')
    out = Path(app).parent / (Path(app).name + '.entitlements')
    out.write_bytes(plistlib.dumps(want))
    print(f'pack_app: iCloud (CloudKit) container {c}, profile {prof}', flush=True)
    return ('--entitlements', str(out))
