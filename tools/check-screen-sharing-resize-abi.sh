#!/usr/bin/env bash
set -euo pipefail

SDKROOT_PATH="${SDKROOT_PATH:-/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
SDK_TBD="$SDKROOT_PATH/System/Library/PrivateFrameworks/ScreenSharingKit.framework/Versions/A/ScreenSharingKit.tbd"
LIB="/System/Library/PrivateFrameworks/ScreenSharingKit.framework/Versions/A/ScreenSharingKit"

if [[ ! -f "$SDK_TBD" ]]; then
  echo "missing SDK stub: $SDK_TBD" >&2
  exit 2
fi

symbols=(
  '$s16ScreenSharingKit11CanvasSizesV18allowsResizabilitySbvg'
  '$s16ScreenSharingKit12CapabilitiesV21universalResizabilityACvgZ'
  '$s16ScreenSharingKit16MirroringSessionP20liveResizeInProgressyySbYaFTq'
  '$s16ScreenSharingKit16MirroringSessionP25sceneSizeChangedPublisher7Combine03AnyI0VySo6CGSizeVs5NeverOGvgTq'
  '$s16ScreenSharingKit16MirroringSessionP26isResizableStatusPublisher7Combine03AnyI0VySbs5NeverOGvgTq'
  '$s16ScreenSharingKit21MirroringSessionStateO23videoContentSizeChangedyACSo6CGRectVcACmFWC'
  '$s16ScreenSharingKit17AppPreferenceKeysO30windowScalingPresetDefaultsKeySSvgZ'
)
labels=(
  'CanvasSizes.allowsResizability'
  'Capabilities.universalResizability'
  'MirroringSession.liveResizeInProgress'
  'MirroringSession.sceneSizeChangedPublisher'
  'MirroringSession.isResizableStatusPublisher'
  'MirroringSessionState.videoContentSizeChanged'
  'AppPreferenceKeys.windowScalingPresetDefaultsKey'
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

printf '%-52s %8s %8s\n' "symbol" "runtime" "sdk"
printf '%-52s %8s %8s\n' "------" "-------" "---"
for i in "${!symbols[@]}"; do
  sym="${symbols[$i]}"
  label="${labels[$i]}"
  runtime=$($tmpdir/check "$LIB" "$sym")
  sdk=0
  if grep -qF "_$sym" "$SDK_TBD"; then sdk=1; fi
  printf '%-52s %8s %8s\n' "$label" "$runtime" "$sdk"
done
