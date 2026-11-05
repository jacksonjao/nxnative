# GTA V on iPadOS 16

The existing GameBox engine is used on iOS 17 and newer. For iOS 16,
build the UIKit and Metal iOS port as an embedded framework. Start with
upstream gta5-ios-port v1.5.2 (commit
`60b1a226bc46a33da3d84c33007a10b6eb1be7aa`) and apply
`gta-v1.5.2-embedded.patch` there with `git apply`.

Run `python3 reuse_release_shaders.py ORIGINAL_IPA UPSTREAM_CHECKOUT` to
reuse the original release's Metal library and matching reflection data.
From the upstream `app` directory run
`python3 Scripts/prepare_tonton.py --mirror OWNED_GAME_MIRROR`, then
`xcodegen generate --spec project.yml` and build the
`TonTonGTAEmbedded` target for iphoneos. Embed and sign the resulting
framework inside the GameBox app. Existing game and save data remain
under `Documents/Games/gta5/UserData`.

The release-only GameBox touch-layout editor can be updated with
`contrib/tonton/apply_per_title_touch_layout.py RELEASE_SOURCE_ROOT`
against the version of the release source with `TouchLayoutEditor.h`.
The library host must compile using the generated multi-title profile.
