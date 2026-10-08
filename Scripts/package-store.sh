#!/bin/zsh
# Build/export locally. Upload and App Review submission are separate actions.
set -euo pipefail
project_root="${0:A:h:h}"
output="${STORE_OUTPUT_ROOT:-$project_root/.build/app-store/current}"
archive="$output/CodexGauge.xcarchive"
stage="${1:-archive}"
case "$stage" in
  archive)
    [[ ! -e "$archive" ]] || { print -u2 "Archive already exists: $archive. Choose a new STORE_OUTPUT_ROOT."; exit 1; }
    mkdir -p "$output"
    git -C "$project_root" rev-parse HEAD > "$output/source-commit.txt"
    git -C "$project_root" status --short > "$output/source-working-tree.txt"
    xcodebuild archive -project "$project_root/CodexGauge.xcodeproj" -scheme CodexGauge \
      -configuration Release -destination 'generic/platform=macOS' -archivePath "$archive" \
      -derivedDataPath "$output/DerivedData" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
      > "$output/archive.log" 2>&1
    uv run python "$project_root/Scripts/check-mac-package.py" \
      "$archive/Products/Applications/CodexGauge.app" --release --universal
    print "Archive: $archive"
    ;;
  export)
    [[ -d "$archive" ]] || { print -u2 "Build the archive first: $archive"; exit 1; }
    uv run python "$project_root/Scripts/check-mac-package.py" \
      "$archive/Products/Applications/CodexGauge.app" --release --universal
    [[ ! -e "$output/export" ]] || { print -u2 "Export already exists: $output/export"; exit 1; }
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/export" \
      -exportOptionsPlist "$project_root/Distribution/AppStoreExportOptions.plist" -allowProvisioningUpdates \
      > "$output/export.log" 2>&1
    uv run python "$project_root/Scripts/check-store-export.py" "$output/export/CodexGauge.pkg"
    print "Local App Store export: $output/export"
    ;;
  *) print -u2 'Usage: package-store.sh [archive|export]'; exit 1 ;;
esac
