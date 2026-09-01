#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

required=(
  LICENSE NOTICE README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md
  CODE_OF_CONDUCT.md SUPPORT.md PRIVACY.md .xcode-version
  Performance/Budgets.json Performance/README.md
  Scripts/release.sh Scripts/check-toolchain.sh Scripts/performance-check.sh
  Scripts/performance-probe.swift
  CodexGauge/AppIcon.icon/icon.json
  CodexGauge/AppIcon.icon/Assets/01-dial.svg
  CodexGauge/AppIcon.icon/Assets/02-track.svg
  CodexGauge/AppIcon.icon/Assets/03-progress.svg
  CodexGauge/AppIcon.icon/Assets/04-needle.svg
  CodexGauge.xcodeproj/xcshareddata/xcschemes/CodexGauge.xcscheme
)
for required_file in "${required[@]}"; do
  [[ -f "$required_file" ]] || { print -u2 "Missing required repository file: $required_file"; exit 1; }
done

tracked_artifacts="$(git ls-files | grep -E '(^|/)(DerivedData|TestArtifacts|xcuserdata)/|\.(xcresult|xcarchive|dmg|p12|p8|mobileprovision|keychain-db|profraw|profdata)$' || true)"
[[ -z "$tracked_artifacts" ]] || { print -u2 "Generated or sensitive files are tracked:\n$tracked_artifacts"; exit 1; }

project_file="CodexGauge.xcodeproj/project.pbxproj"
object_version="$(sed -nE 's/^[[:space:]]*objectVersion = ([0-9]+);/\1/p' "$project_file")"
preferred_object_version="$(sed -nE 's/^[[:space:]]*preferredProjectObjectVersion = ([0-9]+);/\1/p' "$project_file")"
[[ -n "$object_version" && "$object_version" == "$preferred_object_version" ]] || {
  print -u2 "The Xcode project format ($object_version) does not match its stable preferred format ($preferred_object_version)."
  exit 1
}

marketing_versions="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$project_file" | sort -u)"
[[ "$(print -r -- "$marketing_versions" | wc -l | tr -d ' ')" == 1 ]] \
  && print -r -- "$marketing_versions" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { print -u2 "MARKETING_VERSION must be one consistent semantic version."; exit 1; }
grep -Fq "## [$marketing_versions]" CHANGELOG.md \
  || { print -u2 "CHANGELOG.md has no release section for $marketing_versions."; exit 1; }

build_numbers="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$project_file" | sort -u)"
[[ "$(print -r -- "$build_numbers" | wc -l | tr -d ' ')" == 1 ]] \
  && print -r -- "$build_numbers" | grep -Eq '^[1-9][0-9]*$' \
  || { print -u2 "CURRENT_PROJECT_VERSION must be one consistent positive integer."; exit 1; }

grep -Eq 'MACOSX_DEPLOYMENT_TARGET = 14\.4;' "$project_file"
grep -Fq 'ARCHS = "$(ARCHS_STANDARD)";' "$project_file"
if grep -Eq 'ARCHS = arm64;' "$project_file"; then
  print -u2 "The application target must use Standard Architectures for Universal 2 releases."
  exit 1
fi
grep -Eq 'ENABLE_HARDENED_RUNTIME = YES;' "$project_file"
grep -Eq 'ENABLE_APP_SANDBOX = NO;' "$project_file"
grep -Eq 'ENABLE_CODE_COVERAGE = NO;' "$project_file"
grep -Eq 'INFOPLIST_KEY_LSUIElement = YES;' "$project_file"
grep -Eq 'public\.app-category\.developer-tools' "$project_file"
grep -Eq 'Copyright © 2026 North Wolf Labs LLC' "$project_file"
if grep -A4 'membershipExceptions = (' "$project_file" | grep -Fq 'AppIcon.icon'; then
  print -u2 "The Icon Composer source must be included in the application target."
  exit 1
fi

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

public_release_block="$(sed -n '/gh release create/,/--draft/p' .github/workflows/release.yml)"
[[ "$public_release_block" == *'CodexGauge-$RELEASE_TAG-universal.dmg'* ]] \
  || { print -u2 'The public release must include the versioned Universal 2 DMG.'; exit 1; }
[[ "$public_release_block" == *'$root/SHA256SUMS'* ]] \
  || { print -u2 'The public release must include SHA256SUMS.'; exit 1; }
if print -r -- "$public_release_block" | grep -Eq 'dSYMs|notarization\.json|build-manifest\.json|INTERNAL-SHA256SUMS'; then
  print -u2 "Internal release records must not be published as GitHub Release assets."
  exit 1
fi

grep -Fq 'universal_architectures=(arm64 x86_64)' Scripts/release.sh
grep -Fq 'macos-15-intel' .github/workflows/ci.yml
grep -Fq 'macos-15-intel' .github/workflows/release.yml
grep -Fq 'Universal 2' README.md

jq -e '.sampleSeconds == 300 and .warmupSeconds == 60 and (.scenarios | length == 5)' Performance/Budgets.json >/dev/null
zsh -n Scripts/release.sh Scripts/check-toolchain.sh Scripts/check-repository.sh Scripts/performance-check.sh
print "Repository checks passed."
