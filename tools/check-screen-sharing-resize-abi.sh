#!/usr/bin/env bash
set -euo pipefail

SDKROOT_PATH="${SDKROOT_PATH:-/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
SDK_TBD="$SDKROOT_PATH/System/Library/PrivateFrameworks/ScreenSharingKit.framework/Versions/A/ScreenSharingKit.tbd"
LIB="/System/Library/PrivateFrameworks/ScreenSharingKit.framework/Versions/A/ScreenSharingKit"

if [[ ! -f "$SDK_TBD" ]]; then
  echo "missing SDK stub: $SDK_TBD" >&2
  exit 2
fi

labels=(
  'CanvasSizes.allowsResizability'
  'CanvasSizes.canvasSize'
  'CanvasSizes.streamSize'
  'CanvasSizes.logicalScale'
  'Capabilities.universalResizability'
  'MirroringSession.liveResizeInProgress'
  'MirroringSession.sceneSizeChangedPublisher'
  'MirroringSession.isResizableStatusPublisher'
  'MirroringSessionState.videoContentSizeChanged'
  'MirroringSessionState.performingInitialHandshake'
  'AppPreferenceKeys.windowScalingPresetDefaultsKey'
  'ControlMessageStreamIdentifiers.sessionAndHIDMessages'
)
symbols=(
  '$s16ScreenSharingKit11CanvasSizesV18allowsResizabilitySbvg'
  '$s16ScreenSharingKit11CanvasSizesV10canvasSizeSo6CGSizeVvg'
  '$s16ScreenSharingKit11CanvasSizesV10streamSizeSo6CGSizeVvg'
  '$s16ScreenSharingKit11CanvasSizesV12logicalScale12CoreGraphics7CGFloatVvg'
  '$s16ScreenSharingKit12CapabilitiesV21universalResizabilityACvgZ'
  '$s16ScreenSharingKit16MirroringSessionP20liveResizeInProgressyySbYaFTq'
  '$s16ScreenSharingKit16MirroringSessionP25sceneSizeChangedPublisher7Combine03AnyI0VySo6CGSizeVs5NeverOGvgTq'
  '$s16ScreenSharingKit16MirroringSessionP26isResizableStatusPublisher7Combine03AnyI0VySbs5NeverOGvgTq'
  '$s16ScreenSharingKit21MirroringSessionStateO23videoContentSizeChangedyACSo6CGRectVcACmFWC'
  '$s16ScreenSharingKit21MirroringSessionStateO26performingInitialHandshakeyACSS_AA11CanvasSizesVSgtcACmFWC'
  '$s16ScreenSharingKit17AppPreferenceKeysO30windowScalingPresetDefaultsKeySSvgZ'
  '$s16ScreenSharingKit31ControlMessageStreamIdentifiersO21sessionAndHIDMessagesSSvgZ'
)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/check.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc < 3) return 2;
  void *h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
  if (!h) {
    printf("0\n");
    return 0;
  }
  void *s = dlsym(h, argv[2]);
  printf("%d\n", s != 0);
  return 0;
}
C
clang "$tmpdir/check.c" -o "$tmpdir/check" -ldl

printf 'Host runtime: %s\n' "$LIB"
printf 'SDK stub:     %s\n\n' "$SDK_TBD"
printf '%-56s %8s %8s\n' "symbol" "runtime" "sdk"
printf '%-56s %8s %8s\n' "------" "-------" "---"
missing_runtime=0
present_runtime=0
for i in "${!symbols[@]}"; do
  sym="${symbols[$i]}"
  label="${labels[$i]}"
  runtime=$($tmpdir/check "$LIB" "$sym")
  sdk=0
  if grep -qF "_$sym" "$SDK_TBD"; then sdk=1; fi
  if [[ "$runtime" == "1" ]]; then present_runtime=$((present_runtime + 1)); fi
  if [[ "$runtime" == "0" && "$sdk" == "1" ]]; then missing_runtime=$((missing_runtime + 1)); fi
  printf '%-56s %8s %8s\n' "$label" "$runtime" "$sdk"
done

printf '\nSummary: runtime_present=%d sdk_only=%d\n' "$present_runtime" "$missing_runtime"
if [[ "$missing_runtime" -gt 0 ]]; then
  echo "Host runtime is older than the Xcode SDK resize ABI surface."
else
  echo "Host runtime exports the checked ScreenSharingKit resize ABI surface."
fi
