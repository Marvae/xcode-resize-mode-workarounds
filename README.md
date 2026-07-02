# Xcode Resize Mode Workarounds

Make iOS 26.x SDK simulator apps usable with Xcode 27 Device Hub Resize Mode.

## Recommended: simulator-wide switch

For iOS 27 simulators, this is the fastest path. It does not modify, re-sign, or re-install any app:

```bash
DEVICE=<simulator-udid>
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

xcrun simctl spawn "$DEVICE" defaults write com.apple.springboard \
  SBForceAllPhoneAppsToBeResizableOnResizableDisplays -bool YES
xcrun simctl spawn "$DEVICE" killall SpringBoard
```

Then open Xcode 27 Device Hub and click **Enter Resize Mode**.

Undo:

```bash
xcrun simctl spawn "$DEVICE" defaults delete com.apple.springboard \
  SBForceAllPhoneAppsToBeResizableOnResizableDisplays
xcrun simctl spawn "$DEVICE" killall SpringBoard
```

What this means:

- `simctl spawn` runs the command inside that simulator.
- The setting is per simulator UDID, not global across all simulators.
- It applies at SpringBoard level, so it is not app-specific.
- Verified with a production app and a minimal Xcode 26.5 SDK demo app on iOS 27 simulators.

## App-scoped patcher

Use this if you only want one app to be affected, or you want a restoreable app-level workaround instead of changing simulator-wide SpringBoard behavior.

```bash
./xcode-resize-mode-workarounds.swift patch \
  --device <sim-udid-or-name> \
  --bundle <bundle-id>
```

Restore the original app:

```bash
./xcode-resize-mode-workarounds.swift restore \
  --workdir /tmp/xcode-resize-mode-workarounds-YYYYMMDD-HHMMSS
```

The patcher copies the installed app, changes iOS Simulator Mach-O `LC_BUILD_VERSION` SDK metadata to `27.0`, ad-hoc re-signs it, re-installs it with Xcode 27 `devicectl`, and launches it.

## Xcode scheme post-action

If you want Xcode Run to apply the app-scoped patch after the normal install, add a scheme **Run > Post-action**. Set **Provide build settings from** to your app target.

```bash
PATCHER="/path/to/xcode-resize-mode-workarounds.swift"

"$PATCHER" patch \
  --device "$TARGET_DEVICE_IDENTIFIER" \
  --bundle "$PRODUCT_BUNDLE_IDENTIFIER"
```

## Why patching needs re-sign and re-install

`vtool` changes bytes in Mach-O load commands. Without re-signing, launch can fail with:

```text
Termination Reason: Namespace CODESIGNING, Code 2, Invalid Page
```

Patching the already-installed app in place is also not enough. LaunchServices/MobileInstallation keeps the old SDK metadata until the patched app is installed again.

## Notes

- These are local-development workarounds only.
- Do not use patched output for devices, TestFlight, App Store, or CI release artifacts.
- Physical iOS 27 devices tested so far do not advertise Device Hub's CoreDevice `Resizable App Management` capability.
- More investigation notes and private flags are in [INVESTIGATION.md](INVESTIGATION.md).

## License

MIT
