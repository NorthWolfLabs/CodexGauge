# Contributing to CodexGauge

Thank you for helping improve CodexGauge.

## Before opening a change

- Use an issue for significant product or architecture changes.
- Keep version one read-only and preserve the privacy boundaries in [PRIVACY.md](PRIVACY.md).
- Do not commit real rollout files, credentials, account data, task names, screenshots containing private information, or generated build artifacts.

## Development environment

CodexGauge requires Apple Silicon, macOS 14 or later, and the exact stable Xcode release recorded in [.xcode-version](.xcode-version). Confirm it with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/check-toolchain.sh
```

Build and test with:

```sh
xcodebuild build -project CodexGauge.xcodeproj -scheme CodexGauge \
  -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project CodexGauge.xcodeproj -scheme CodexGauge \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

The first local UI-test run may ask for Accessibility/Automation permission. Release artifacts use the exact recorded Xcode; the macOS 14 compatibility runner uses the newest Xcode that host supports.

## Pull requests

- Add focused tests for behavioral changes and content-free fixtures for telemetry parsing.
- Include before-and-after screenshots for interface changes in light and dark appearance.
- Check keyboard navigation, Reduce Motion, increased contrast, and VoiceOver descriptions.
- Keep Swift 6 concurrency diagnostics clean.
- Update documentation and `CHANGELOG.md` when behavior, privacy, compatibility, or release steps change.

By submitting a contribution, you agree that it is licensed under Apache License 2.0.

## Version and build numbers

Public versions use Semantic Versioning. `MARKETING_VERSION` identifies the release. `CURRENT_PROJECT_VERSION` is an integer and must increase for every distributed build, including release candidates; it is never reused for a different artifact.
