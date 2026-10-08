#!/bin/zsh
# macOS performs the first-launch migration; the app never bypasses its sandbox.
set -euo pipefail
case "$PRODUCT_BUNDLE_IDENTIFIER" in
  com.northwolflabs.CodexGauge) support_name=CodexGauge ;;
  com.northwolflabs.CodexGauge.beta) support_name='CodexGauge Beta' ;;
  *) print -u2 "No container migration defined for $PRODUCT_BUNDLE_IDENTIFIER"; exit 1 ;;
esac
manifest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/container-migration.plist"
mkdir -p "${manifest:h}"
# Variables below belong to Apple's migration service, not this shell.
cat > "$manifest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Move</key><array>
<string>\${ApplicationSupport}/$support_name</string>
<string>\${Library}/Preferences/\${BundleId}.plist</string>
</array></dict></plist>
EOF
plutil -lint "$manifest"
