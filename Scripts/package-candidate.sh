#!/bin/zsh
# Local release-optimized candidates, retaining the installed test app's state.
set -euo pipefail
project_root="${0:A:h:h}"
candidate_version="${CANDIDATE_VERSION:-1.3.0}"
candidate_build="${CANDIDATE_BUILD:-11}"
output="${CANDIDATE_OUTPUT_ROOT:-$project_root/.build/candidate/$candidate_version-$candidate_build}"
platform="${1:-mac}"
mkdir -p "$output"
case "$platform" in
  mac)
    [[ ! -e "$output/Mac/TokenTach.app" ]] || { print -u2 'Mac candidate exists. Choose a new CANDIDATE_BUILD or CANDIDATE_OUTPUT_ROOT.'; exit 1; }
    identity="${DEVELOPER_ID_APPLICATION:-Developer ID Application: North Wolf Labs LLC (ALPX923Y54)}"
    xcodebuild build -project "$project_root/TokenTach.xcodeproj" -scheme TokenTach \
      -configuration Release -destination 'generic/platform=macOS' \
      -derivedDataPath "$output/MacDerivedData" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
      PRODUCT_NAME=TokenTach EXECUTABLE_NAME=TokenTach PRODUCT_MODULE_NAME=TokenTach \
      PRODUCT_BUNDLE_IDENTIFIER=com.northwolflabs.CodexGauge.beta \
      INFOPLIST_KEY_CFBundleDisplayName=TokenTach \
      MARKETING_VERSION="$candidate_version" CURRENT_PROJECT_VERSION="$candidate_build" \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM= \
      OTHER_CODE_SIGN_FLAGS=--timestamp > "$output/mac-build.log" 2>&1 \
      || { tail -50 "$output/mac-build.log"; exit 1; }
    mkdir -p "$output/Mac"
    app="$output/Mac/TokenTach.app"
    ditto "$output/MacDerivedData/Build/Products/Release/TokenTach.app" "$app"
    uv run --no-project python "$project_root/Scripts/check-mac-package.py" "$app" --release --universal
    print "Mac candidate: $app"
    ;;
  ios)
    [[ ! -e "$output/iPhone/TokenTachMobile.app" ]] || { print -u2 'iPhone candidate exists. Choose a new CANDIDATE_BUILD or CANDIDATE_OUTPUT_ROOT.'; exit 1; }
    # Development provisioning uses sandbox APNs even in a Release configuration.
    # Keep the client's registration environment aligned with its signed entitlement.
    xcodebuild build -project "$project_root/Companion/TokenTachMobile.xcodeproj" \
      -scheme TokenTachMobile -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath "$output/MobileDerivedData" -allowProvisioningUpdates \
      MARKETING_VERSION="$candidate_version" CURRENT_PROJECT_VERSION="$candidate_build" \
      COMPANION_RELEASE_ENTITLEMENTS=CompanionPush \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS=LOCAL_DEVICE_CANDIDATE \
      > "$output/mobile-build.log" 2>&1 \
      || { tail -50 "$output/mobile-build.log"; exit 1; }
    mkdir -p "$output/iPhone"
    app="$output/iPhone/TokenTachMobile.app"
    ditto "$output/MobileDerivedData/Build/Products/Release-iphoneos/TokenTachMobile.app" "$app"
    uv run --no-project python "$project_root/Scripts/check-mobile-package.py" "$app"
    print "iPhone candidate: $app"
    ;;
  *) print -u2 'Usage: package-candidate.sh [mac|ios]'; exit 1 ;;
esac
