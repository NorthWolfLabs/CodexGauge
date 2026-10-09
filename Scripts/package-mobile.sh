#!/bin/zsh
# Prepare a local TestFlight archive/export. Upload from Xcode Organizer separately.
set -euo pipefail
root="${0:A:h:h}"
output="${MOBILE_OUTPUT_ROOT:-$root/.build/testflight/mobile}"
archive="$output/TokenTachMobile.xcarchive"
stage="${1:-archive}"
approved="${DEVICE_NAME_APPROVED:-0}"
[[ "$approved" == 0 || "$approved" == 1 ]] || { print -u2 'DEVICE_NAME_APPROVED must be 0 or 1.'; exit 1; }
case "$stage" in
  archive)
    "$root/Scripts/check-toolchain.sh"
    [[ ! -e "$archive" ]] || { print -u2 "Archive exists: $archive. Choose a new MOBILE_OUTPUT_ROOT."; exit 1; }
    mkdir -p "$output"
    git -C "$root" rev-parse HEAD > "$output/source-commit.txt"
    git -C "$root" diff --binary HEAD > "$output/source.patch"
    git -C "$root" status --short > "$output/source-working-tree.txt"
    build_flags=()
    [[ "$approved" == 0 ]] || build_flags+=(DEVICE_NAME_ENTITLEMENTS_SUFFIX=WithDeviceName)
    [[ -z "${MOBILE_BUILD:-}" ]] || build_flags+=(CURRENT_PROJECT_VERSION="$MOBILE_BUILD")
    xcodebuild archive -project "$root/Companion/TokenTachMobile.xcodeproj" \
      -scheme TokenTachMobile -configuration Release -destination 'generic/platform=iOS' \
      -archivePath "$archive" -derivedDataPath "$output/DerivedData" \
      -allowProvisioningUpdates "${build_flags[@]}" > "$output/archive.log" 2>&1 \
      || { tail -60 "$output/archive.log"; exit 1; }
    uv run --no-project python "$root/Scripts/check-mobile-package.py" \
      "$archive/Products/Applications/TokenTachMobile.app"
    print "Archive: $archive"
    ;;
  export)
    [[ -d "$archive" ]] || { print -u2 "Build the archive first: $archive"; exit 1; }
    [[ ! -e "$output/export" ]] || { print -u2 "Export exists: $output/export"; exit 1; }
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/export" \
      -exportOptionsPlist "$root/Distribution/AppStoreExportOptions.plist" \
      -allowProvisioningUpdates > "$output/export.log" 2>&1 \
      || { tail -60 "$output/export.log"; exit 1; }
    build_flags=(--distribution)
    [[ "$approved" == 0 ]] || build_flags+=(--device-name)
    uv run --no-project python "$root/Scripts/check-mobile-package.py" \
      "$output/export/TokenTachMobile.ipa" "${build_flags[@]}"
    print "Validated local TestFlight export: $output/export"
    ;;
  *) print -u2 'Usage: package-mobile.sh [archive|export]'; exit 1 ;;
esac
