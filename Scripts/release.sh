#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
team_id="ALPX923Y54"
product_name="CodexGauge"
project="$project_root/CodexGauge.xcodeproj"
scheme="CodexGauge"
tag="${RELEASE_TAG:-$(git -C "$project_root" describe --tags --exact-match 2>/dev/null || true)}"
version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project/project.pbxproj" | sort -u | head -n 1)"
build_number="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project/project.pbxproj" | sort -u | head -n 1)"
release_root="${RELEASE_ROOT:-$project_root/.build/release/${tag:-untagged}}"
archive_path="$release_root/$product_name.xcarchive"
export_path="$release_root/export"
app_path="$export_path/$product_name.app"
zip_path="$release_root/$product_name-$tag.zip"
dmg_path="$release_root/$product_name-$tag.dmg"
notary_arguments=()

fail() {
  print -u2 "release: $1"
  exit 1
}

reject_release_diagnostics() {
  local log_file="$1"
  if grep -Ei \
    'Invalid frame dimension|Custom UnitPoint values are not supported|main actor-isolated.*nonisolated|main-thread XCTest|accessibility.*failed|warning:.*(Sendable|actor-isolated|concurr)' \
    "$log_file"; then
    fail "release-blocking warning or runtime fault found in $log_file"
  fi
}

configure_notary_arguments() {
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    notary_arguments=(--keychain-profile "$NOTARYTOOL_PROFILE")
  elif [[ -n "${ASC_API_KEY_PATH:-}" && -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]]; then
    notary_arguments=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
  else
    fail "set NOTARYTOOL_PROFILE, or ASC_API_KEY_PATH, ASC_API_KEY_ID, and ASC_API_ISSUER_ID"
  fi
}

signing_identity() {
  if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    print -r -- "$DEVELOPER_ID_APPLICATION"
    return
  fi
  security find-identity -v -p codesigning \
    | sed -nE 's/.*"(Developer ID Application: .* \(ALPX923Y54\))".*/\1/p' \
    | head -n 1
}

validate_tree() {
  "$project_root/Scripts/check-toolchain.sh"
  [[ -n "$tag" ]] || fail "HEAD must have an exact release tag"
  [[ "$tag" == "v$version" || "$tag" == "v$version"-rc.<-> ]] \
    || fail "tag $tag does not match app version $version"
  [[ -z "$(git -C "$project_root" status --porcelain --untracked-files=all)" ]] \
    || fail "the release tree contains uncommitted files"
  git -C "$project_root" diff --quiet "$tag" -- || fail "the checked-out tree differs from $tag"
  [[ -z "$(git -C "$project_root" ls-files '*.p12' '*.p8' '*.key' '*.mobileprovision')" ]] \
    || fail "signing credentials or profiles are tracked by Git"
  [[ ! -e "$release_root" ]] || fail "$release_root already exists; choose a new RELEASE_ROOT"
  mkdir -p "$release_root"
}

run_tests() {
  mkdir -p "$release_root"
  local started test_log runtime_log
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  test_log="$release_root/tests.log"
  runtime_log="$release_root/runtime.log"
  xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$release_root/Tests.xcresult" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= 2>&1 | tee "$test_log"
  /usr/bin/log show --start "$started" --style compact \
    --predicate 'process == "CodexGauge" OR process == "CodexGaugeUITests-Runner"' \
    > "$runtime_log" || true
  reject_release_diagnostics "$test_log"
  reject_release_diagnostics "$runtime_log"
}

archive_app() {
  local identity
  mkdir -p "$release_root"
  identity="$(signing_identity)"
  [[ -n "$identity" ]] || fail "no private-key-backed Developer ID Application identity exists for $team_id"
  xcodebuild archive \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team_id" \
    2>&1 | tee "$release_root/archive.log"
  reject_release_diagnostics "$release_root/archive.log"
}

export_app() {
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$project_root/Scripts/ExportOptions.plist"
  verify_app_signature
}

verify_app_signature() {
  [[ -d "$app_path" ]] || fail "exported app is missing"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  [[ "$(lipo -archs "$app_path/Contents/MacOS/$product_name")" == "arm64" ]] || fail "the app is not arm64-only"
  local details entitlements
  details="$(codesign -dvvv "$app_path" 2>&1)"
  [[ "$details" == *"Authority=Developer ID Application: North Wolf Labs LLC ($team_id)"* ]] \
    || fail "the app is not signed with the North Wolf Labs Developer ID identity"
  [[ "$details" == *"TeamIdentifier=$team_id"* ]] || fail "the signature has the wrong team identifier"
  [[ "$details" == *"Runtime Version"* ]] || fail "the hardened runtime is missing"
  [[ "$details" == *"Timestamp="* ]] || fail "the Developer ID signature has no secure timestamp"
  entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
  [[ "$entitlements" != *"com.apple.security.app-sandbox"* ]] || fail "App Sandbox is unexpectedly enabled"
  [[ "$entitlements" != *"com.apple.security.get-task-allow"* ]] || fail "the release app is debuggable"
  while IFS= read -r nested; do
    codesign --verify --strict --verbose=2 "$nested"
  done < <(find "$app_path/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.dylib' -o -name '*.bundle' \) -print)
}

notarize_app() {
  configure_notary_arguments
  ditto -c -k --keepParent "$app_path" "$zip_path"
  xcrun notarytool submit "$zip_path" "${notary_arguments[@]}" --wait --output-format json \
    | tee "$release_root/app-notarization.json"
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute --verbose=4 "$app_path"
}

package_dmg() {
  local identity staging
  identity="$(signing_identity)"
  [[ -n "$identity" ]] || fail "Developer ID identity disappeared before DMG signing"
  staging="$(mktemp -d "$release_root/dmg-staging.XXXXXX")"
  ditto "$app_path" "$staging/$product_name.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "$product_name" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
  codesign --force --timestamp --options runtime --sign "$identity" "$dmg_path"
  rm -rf "$staging"
}

notarize_dmg() {
  configure_notary_arguments
  xcrun notarytool submit "$dmg_path" "${notary_arguments[@]}" --wait --output-format json \
    | tee "$release_root/dmg-notarization.json"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
}

write_artifacts() {
  ditto -c -k --keepParent "$archive_path/dSYMs" "$release_root/$product_name-$tag-dSYMs.zip"
  local xcode_version sdk_version commit
  xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')"
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  commit="$(git -C "$project_root" rev-parse HEAD)"
  cat > "$release_root/build-manifest.json" <<EOF
{
  "product": "$product_name",
  "version": "$version",
  "tag": "$tag",
  "build": "$build_number",
  "commit": "$commit",
  "architecture": "arm64",
  "deploymentTarget": "14.0",
  "xcode": "$xcode_version",
  "sdk": "$sdk_version",
  "team": "$team_id"
}
EOF
  (cd "$release_root" && shasum -a 256 \
    "$dmg_path:t" \
    "$product_name-$tag-dSYMs.zip" \
    app-notarization.json \
    dmg-notarization.json \
    build-manifest.json \
    > SHA256SUMS)
}

verify_release() {
  verify_app_signature
  xcrun stapler validate "$app_path"
  xcrun stapler validate "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
  spctl --assess --type execute --verbose=4 "$app_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
  (cd "$release_root" && shasum -a 256 -c SHA256SUMS)
}

run_all() {
  validate_tree
  run_tests
  archive_app
  export_app
  notarize_app
  package_dmg
  notarize_dmg
  write_artifacts
  verify_release
  print "Release artifacts: $release_root"
}

case "${1:-all}" in
  validate) validate_tree ;;
  test) run_tests ;;
  archive) archive_app ;;
  export) export_app ;;
  notarize-app) notarize_app ;;
  package) package_dmg ;;
  notarize-dmg) notarize_dmg ;;
  artifacts) write_artifacts ;;
  verify) verify_release ;;
  all) run_all ;;
  *) fail "unknown stage '$1' (validate, test, archive, export, notarize-app, package, notarize-dmg, artifacts, verify, all)" ;;
esac
