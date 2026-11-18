# iCloud through CloudKit for the Apple TV app (docs/cloudkit-saves.md; dm/ios/Sources/SaveBackend.swift): kept out of prepare_project.py, which calls setup() below.
#   DM_CLOUDKIT_CONTAINER=iCloud.<id>   the container the Mac, iPhone and Apple TV apps share: Info.plist's DMCloudKitContainer, which turns the settings' iCloud choice on,
#                                       and Gen/DmTV.entitlements asking for it. Xcode must then sign with a paid Apple developer team whose profile for the bundle ID has
#                                       iCloud (CloudKit) and that container; without it the app is prepared as before, and its settings say why iCloud cannot be chosen
import os, plistlib, re
from pathlib import Path


def setup(gen):   # → (the lines for project.yml's info properties, the lines for its target settings); empty without DM_CLOUDKIT_CONTAINER
    c = os.environ.get('DM_CLOUDKIT_CONTAINER', '').strip()
    if not c: return '', ''
    if not re.fullmatch(r'iCloud\.[A-Za-z0-9.\-]+', c): raise SystemExit(f'DM_CLOUDKIT_CONTAINER={c}: an iCloud container identifier is iCloud.<reverse DNS>')
    ent = Path(gen) / 'DmTV.entitlements'
    ent.write_bytes(plistlib.dumps({'com.apple.developer.icloud-container-identifiers': [c], 'com.apple.developer.icloud-services': ['CloudKit']}))
    print(f'iCloud (CloudKit): container {c}, {ent}')
    return f"\n        DMCloudKitContainer: '{c}'", '\n      CODE_SIGN_ENTITLEMENTS: Gen/DmTV.entitlements'
