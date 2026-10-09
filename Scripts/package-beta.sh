#!/bin/zsh
# Local side-by-side candidate packaging; never tags, publishes, or notarizes.
set -euo pipefail

project_root="${0:A:h:h}"
beta_version="${BETA_VERSION:-1.3.0}"
beta_build="${BETA_BUILD:-10}"
beta_label="${BETA_LABEL:-$beta_version-rc.1}"
output="${BETA_OUTPUT_ROOT:-$project_root/.build/beta/$beta_label}"
product_name="TokenTach Beta"
bundle_id="com.northwolflabs.CodexGauge.beta"
identity="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: .* \(ALPX923Y54\))".*/\1/p' | head -n 1)}"
identity="${identity:--}"
signing_flags=()
[[ "$identity" == - ]] || signing_flags=(--timestamp)
[[ ! -e "$output" ]] || { print -u2 "Output already exists: $output. Choose a new BETA_OUTPUT_ROOT."; exit 1; }
mkdir -p "$output"

if ! "$project_root/Scripts/check-repository.sh" > "$output/repository-check.log" 2>&1; then
  print -u2 "Production repository checks did not pass; details are in $output/repository-check.log. Continuing local candidate packaging."
fi
xcodebuild -version > "$output/toolchain.txt"
git -C "$project_root" rev-parse HEAD > "$output/source-commit.txt"
git -C "$project_root" status --short > "$output/source-working-tree.txt"

xcodebuild build \
  -project "$project_root/TokenTach.xcodeproj" -scheme TokenTach \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$output/DerivedData" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  PRODUCT_NAME="$product_name" EXECUTABLE_NAME=TokenTachBeta PRODUCT_MODULE_NAME=TokenTach \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  INFOPLIST_KEY_CFBundleDisplayName="$product_name" \
  MARKETING_VERSION="$beta_version" CURRENT_PROJECT_VERSION="$beta_build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS="${signing_flags[*]}" > "$output/build.log" 2>&1

app="$output/$product_name.app"
ditto "$output/DerivedData/Build/Products/Release/$product_name.app" "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle_id" ]]
codesign --verify --deep --strict --verbose=2 "$app"
uv run python "$project_root/Scripts/check-mac-package.py" "$app" --release --universal
architectures="$(lipo -archs "$app/Contents/MacOS/TokenTachBeta")"
[[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]]
codesign -dvv "$app" > "$output/signature.txt" 2>&1

cat > "$output/READ ME.txt" <<EOF
TokenTach Beta $beta_label (build $beta_build)

Drag TokenTach Beta.app into Applications, then open it. It can run alongside
TokenTach.app. The beta uses β in place of the normal gauge icon by default.
Menu Bar settings can switch back to the gauge or hide the icon; the preview
matches these choices. Warning symbols still appear when needed.

The beta has its own preferences, Notification Center permission, login item,
snapshot cache, and notification-monitor state. It reads the same
existing Codex sign-in and local task data after you select the Codex folder
and installed helper in General settings. Access is remembered on this Mac.
Its prior beta state migrates into its own sandbox container; stable settings
are not migrated into the beta.

Choose local alerts in Settings > Notifications. Leave the beta running while
the Mac is awake to catch future task, banked reset, and allowance events.
Both apps can stay running; disable duplicate local notifications as needed.

Local candidate, not notarized or published. Signing identity: $identity
Built from the working tree recorded alongside this file, using toolchain.txt.
This is not a completed production release or a macOS compatibility-matrix run.
EOF

staging="$output/dmg-staging"
mkdir "$staging"
ditto "$app" "$staging/$product_name.app"
cp "$output/READ ME.txt" "$staging/READ ME.txt"
ln -s /Applications "$staging/Applications"
dmg="$output/TokenTach-Beta-$beta_label-universal.dmg"
if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
  /usr/sbin/diskutil image create from --format UDZO --volumeName "$product_name" "$staging" "$dmg"
else
  hdiutil create -srcfolder "$staging" -volname "$product_name" -format UDZO "$dmg"
fi
codesign --force "${signing_flags[@]}" --sign "$identity" "$dmg"
codesign --verify --verbose=2 "$dmg"
(cd "$output" && shasum -a 256 "${dmg:t}" > SHA256SUMS)
print "Beta app: $app"
print "Beta DMG: $dmg"
