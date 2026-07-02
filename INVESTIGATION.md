# Investigation Notes

This file holds the private flags and evidence so the README can stay short.

## Verified simulator-wide key

```bash
SBForceAllPhoneAppsToBeResizableOnResizableDisplays=YES
```

Full command:

```bash
DEVICE=<simulator-udid>
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcrun simctl spawn "$DEVICE" defaults write com.apple.springboard \
  SBForceAllPhoneAppsToBeResizableOnResizableDisplays -bool YES
xcrun simctl spawn "$DEVICE" killall SpringBoard
```

Observed behavior:

| Target | App SDK metadata | Key state | Resize result |
| --- | --- | --- | --- |
| Production app | `sdk 26.5` | absent | `min=0x0`, `max=0x0` |
| Production app | `sdk 26.5` | `YES` | `min=375x375`, `max=1280x1280` |
| Minimal demo app built with Xcode 26.5 | `sdk 26.5` | `YES` | `min=375x375`, `max=1280x1280` |
| Patched production app | `sdk 27.0` | absent | `min=375x375`, `max=1280x1280` |

Important scope:

- This is per simulator device. Each UDID has its own SpringBoard defaults.
- This is simulator-wide. It is not scoped to one bundle id.
- It has only been verified on iOS 27 simulators so far.

## Related SpringBoardFoundation strings

Found in the iOS 27 simulator runtime `SpringBoardFoundation.framework`:

```text
SBForceAllPhoneAppsToBeResizableOnResizableDisplays
SBForceAllPhoneAppsToBeResizableOnPad
SBForceNonRaveUIRequiresFullScreenAppsToBeResizable
SBResizableUIRequiresFullScreenApp
ResizableUIRequiresFullScreenApp
FullScreenLetterboxing
```

Only `SBForceAllPhoneAppsToBeResizableOnResizableDisplays` was required in the minimal verified simulator test above.

Earlier attempts using lowercase selector-style names, such as `forceAllPhoneAppsToBeResizableOnResizableDisplays`, did not explain the working path. The effective defaults key uses the `SB` prefix.

## CoreDevice evidence

Device Hub uses CoreDevice capabilities for resize:

```text
com.apple.coredevice.feature.streamresizabilitystate
com.apple.coredevice.feature.resizableappmanagement
```

The tested iOS 27 simulator advertises `resizableappmanagement`. The tested iOS 27 physical iPhone did not. Direct `devicectl device appResize start` on that physical device failed with:

```text
The capability “Resizable App Management” is not supported by this device.
```

So changing Device Hub UI alone is unlikely to enable physical-device resize through Device Hub. macOS Screen Mirroring likely uses a different path.

## App patching evidence

Observed patch matrix:

| Case | Launch | Resize Mode |
| --- | --- | --- |
| Original Xcode 26.x SDK app | Works | Black or `min/max=0` |
| Patched but not re-signed | Fails | N/A |
| Patched and re-signed before install | Works | Works |
| Installed first, then patched in place | Works | Black or `min/max=0` |

Current patcher flow:

```text
copy installed .app
patch IOSSIMULATOR Mach-O LC_BUILD_VERSION sdk to 27.0
ad-hoc codesign
install patched .app with Xcode 27 devicectl
launch
```
