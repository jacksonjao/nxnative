# iOS 16 / iOS 17 compatibility status

## Published source and compatibility branch

[`ios16-ios17-compat`](https://github.com/widmonstertony/nxnative/tree/ios16-ios17-compat)
is the fork's compatibility branch for ongoing device work. It was renamed
from `ios16-pokemon-za-port` to describe its shared scope: all games, iOS 16.1/17,
legacy GPUs and the optional modern Metal 4 target. Published fixes are
also synchronized to the fork's `main`. Historical snapshots are not
alternative supported releases. The [README game table](../README.md#tonton-gamebox-game-fixes-and-verification)
has the current device evidence.
Start with the [build and installation guide](ios16-ios17.md).

## Upstream integration and resource compatibility

Upstream `372a8d8a0404bd0d0bdc9928a674b0d9c0104b5e` was fetched and fully merged
on 2026-11-01, including the previous full integration through `8ea27784`.
The merged upstream changes include the bounded Need for Speed Bundle 2 reader
and independent mmap/mprotect failure fixtures; the fork retains its alias
exposure checks.
This is a merge, not a rebase or a claim that merely fetching updated the fork.
Use isolated, pinned upstream builds for new releases. Do not update a deployed
game's shader chain merely because the fork's source branches are synchronized.

The full integration preserves signed executable mappings and per-game
frameworks, legacy shader reflection/atomic companions, input semantics,
Chinese settings and exact-build observation IDs. Existing frozen builds and
installed resources retain their original identities. The merged shader chain
is `aefa4b269cfc`: **complete matching resources must be rebuilt per game before
shipping a new host from this source**. Old `ea90` resources cannot be relabelled.
The source merge itself did not replace installed applications.

## Build targets

| Setting | Deployment minimum | Capability boundary |
|---|---|---|
| `DM_IOS_RENDERER=legacy` | iOS/iPadOS 16.1 | Traditional Metal; strict per-game resource checks |
| `DM_LEGACY_TARGET=a10x` | Inherits legacy minimum | Older-GPU companions required; unsupported layered/sampler/image operations block delivery |
| `DM_LEGACY_TARGET=m2` | Inherits legacy minimum | Tested M2 iPad capability selection; not an A10X fallback |
| `DM_IOS_RENDERER=metal4` | iOS/iPadOS 26.0 | Modern backend on compatible hardware; experimental optical-flow interpolation |

Source for other platforms is retained. Later Switch 2 phone and iPad results
are recorded per game in the README; upstream Mac results are not device proof.

## Device evidence and open work — 2026-11-01

The following are user/device observations from this fork, not a blanket list
of supported titles. Installation, shader compilation and successful gameplay
are recorded separately. Older [renderer checkpoints](ios16-compatibility.md)
remain available as historical evidence.

| Game / target | Confirmed evidence | Remaining limits |
|---|---|---|
| Need for Speed / M2 and Air | User confirms gameplay after missing runtime shader resources were delivered | Intermittent scenery artifacts and audio stalls reported; no complete performance/stability pass |
| Pokken / M2 | User confirms picture restored after matching runtime stages were supplied | Broader scenes, A10X and long-run stability not certified |
| Animal Crossing / M2 | User confirms playable | Air executable-image repair installed; post-update gameplay unconfirmed |
| Witcher 3 / M2, iPadOS 16.1 | User now confirms playable after full SDK, shader companion, binding and installed entitlement repairs | 30 FPS and remaining picture anomalies reported; frame timing and rendering still under investigation |
| Arceus / Air | User confirms third-person picture restored in the unified app | Reproducible task-end null-object crash remains open; diagnostic tracing is not a root-cause fix |
| Arceus / A10X, iPadOS 17.7 | Not installed | Two layered vertex and eighteen sampler-limit paths fail the resource audit |
| Z-A / iPhone/iPad | Multiple device packages installed with code/table/save readback | Do not infer all scenes or older-GPU combinations are stable from installation |
| Tsukihime / M2 and Air | Matching resources audited and hosts compiled | Complete resource delivery and gameplay not verified |
| Other newly built titles | Several shader builds completed | Per-device resource audit, signed host/table binding, delivery and user testing still required |

Full-game performance and correctness need the actual game/version/device.
A successful source build, IPA, cover, directory or FPS counter is not a
playability result. Broad frame-rate removal is still being validated against
each game's simulation clock; no stable 120 FPS is promised.

## Non-Switch runtimes in TonTon

GTA uses a separate native engine, not the Nintendo conversion pipeline.
The current Dawn integration requires iOS 17 or newer; an iOS 16 renderer port
is still open. Air engine packaging does not establish complete data delivery.

Full Red Alert 2 and Yuri's Revenge are being integrated through a separate
static x86 recompilation/Win32 compatibility route. Both native engine
frameworks compile for iOS 16.1. M2 non-game probes verify memory, fonts,
storage and framework loading without calling the game entry. SDL lifecycle,
return-to-library, input, suspend/resume and full campaigns still need work.
The existing browser/Wine route can start but has severe performance problems;
it is not presented as the finished native solution.

## Validation scope

The full upstream merge passed 110 tool/iOS Python test files (1,020 cases),
37 graphics Python files (189 cases), the production host suite and 284 real
legacy GPU checks. Optional dependency skips remain. Five-profile unified-host
Xcode builds passed for both deployment targets, iOS 16.1 and modern Metal 4.
Those are unsigned synthetic fixtures without commercial assets; they were not
installed or presented as working game releases. The five-game regression
harness was attempted but blocked by missing local game builds, so no complete
five-game gameplay result is claimed.

Screen XBAY layout and Backbone printed-letter semantics are preserved.
Keyboard J=A / K=B / U=X / I=Y and Return=A / Backspace=B are retained; hardware
keyboard/controller presence hides touch controls. Chinese labels preserve
underlying configuration values. Frame generation is experimental image optical
flow, not native MetalFX frame interpolation. Game assets, extracted code,
shader libraries, keys, saves and signing credentials are not distributed here.
