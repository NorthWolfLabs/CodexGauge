#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

required=(
  LICENSE NOTICE README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md
  CODE_OF_CONDUCT.md SUPPORT.md PRIVACY.md RELEASING.md .xcode-version
  Scripts/release.sh Scripts/check-toolchain.sh
  CodexGauge.xcodeproj/xcshareddata/xcschemes/CodexGauge.xcscheme
)
for required_file in "${required[@]}"; do
  [[ -f "$required_file" ]] || { print -u2 "Missing required repository file: $required_file"; exit 1; }
done

tracked_artifacts="$(git ls-files | grep -E '(^|/)(DerivedData|TestArtifacts|xcuserdata)/|\.(xcresult|xcarchive|dmg|p12|p8|mobileprovision|keychain-db|profraw|profdata)$' || true)"
[[ -z "$tracked_artifacts" ]] || { print -u2 "Generated or sensitive files are tracked:\n$tracked_artifacts"; exit 1; }

project_file="CodexGauge.xcodeproj/project.pbxproj"
grep -Eq 'MACOSX_DEPLOYMENT_TARGET = 14\.0;' "$project_file"
grep -Eq 'ARCHS = arm64;' "$project_file"
grep -Eq 'ENABLE_HARDENED_RUNTIME = YES;' "$project_file"
grep -Eq 'ENABLE_APP_SANDBOX = NO;' "$project_file"
grep -Eq 'ENABLE_CODE_COVERAGE = NO;' "$project_file"
grep -Eq 'INFOPLIST_KEY_LSUIElement = YES;' "$project_file"
grep -Eq 'MARKETING_VERSION = 1\.0\.0;' "$project_file"
grep -Eq 'public\.app-category\.developer-tools' "$project_file"
grep -Eq 'Copyright © 2026 North Wolf Labs LLC' "$project_file"
grep -Eq 'membershipExceptions = \(' "$project_file"
grep -Eq 'AppIcon\.icon' "$project_file"

if grep -REn '(DEVELOPER_ID_P12_BASE64|ASC_API_KEY_P8_BASE64):[[:space:]]*[^$[:space:]]' .github Scripts; then
  print -u2 "A release secret appears to be embedded in source."
  exit 1
fi

zsh -n Scripts/release.sh Scripts/check-toolchain.sh Scripts/check-repository.sh
print "Repository checks passed."
