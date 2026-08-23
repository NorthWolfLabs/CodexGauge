#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

required=(
  LICENSE NOTICE README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md
  CODE_OF_CONDUCT.md SUPPORT.md PRIVACY.md .xcode-version
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

grep -Fq '* @gcurtis131' .github/CODEOWNERS

if grep -REn 'pull_request_target|workflow_run|repository_dispatch' .github/workflows; then
  print -u2 "A privileged or indirect workflow trigger is not allowed."
  exit 1
fi

if grep -REn 'uses: [^@[:space:]]+@(main|master|v[0-9]+)([[:space:]]|$)' .github/workflows; then
  print -u2 "GitHub Actions must be pinned to immutable commit SHAs."
  exit 1
fi

checkout_count="$(grep -Rh 'uses: actions/checkout@' .github/workflows | wc -l | tr -d ' ')"
non_persisting_count="$(grep -Rh 'persist-credentials: false' .github/workflows | wc -l | tr -d ' ')"
[[ "$checkout_count" == "$non_persisting_count" ]] || {
  print -u2 "Every checkout must disable credential persistence."
  exit 1
}

if grep -REn '(DEVELOPER_ID_P12_BASE64|DEVELOPER_ID_P12_PASSWORD|ASC_API_KEY_P8_BASE64|ASC_API_KEY_ID|ASC_API_ISSUER_ID):[[:space:]]+[^$[:space:]]' .github; then
  print -u2 "A release secret appears to be embedded in source."
  exit 1
fi

zsh -n Scripts/release.sh Scripts/check-toolchain.sh Scripts/check-repository.sh
print "Repository checks passed."
