# CodexGauge

CodexGauge is a native, read-only menu-bar monitor for Codex allowances and activity. It uses the Codex app server and local Codex metadata already available on your Mac, so it does not require another login, API key, or account token.

CodexGauge is an independent North Wolf Labs project and is not affiliated with or endorsed by OpenAI or Apple.

## Compatibility

- Apple Silicon only (`arm64`)
- macOS 14.4 or later
- An installed and signed-in ChatGPT or Codex app, or a compatible Codex executable
- Public releases are validated on macOS 14.4 and the current macOS 26 release line

Intel Macs are not supported.

## What it shows

- Every allowance bucket and window returned by Codex, including reset time, remaining percentage, pacing estimates when enough metadata exists, credits, spend controls, and earned resets
- The limiting Codex allowance in the menu bar
- Live tasks on this Mac, including phase, current-turn duration, rolling token rate, token mix, latest context use, response-start latency, and linked-agent count
- Up to 200 recent local root tasks from the previous 24 hours
- Account-wide daily activity, period comparisons, lifetime tokens, streaks, peak day, and longest turn
- Optional allowance and privacy-safe task-attention notifications

Task token rates measure local activity. They are not a task’s share of the account allowance. Tasks that run only on another computer are not visible locally.

## Installation

1. Download the DMG from the repository’s Releases page.
2. Verify the checksum in `SHA256SUMS`:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Open the DMG and drag CodexGauge to Applications.
4. Launch CodexGauge. It appears only in the menu bar.

To inspect Apple’s signature and notarization result:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/CodexGauge.app
spctl --assess --type execute --verbose=4 /Applications/CodexGauge.app
```

CodexGauge immediately searches for a usable Codex helper. Use **Settings > General** only if automatic discovery cannot find it or your Codex data folder is nonstandard.

## Architecture

One AppKit-owned application lifecycle manages the status item, popover, Settings, Help, and Dashboard windows. SwiftUI provides the interface, Charts, gauges, forms, and accessibility behavior.

`CodexAppServerClient` keeps a newline-delimited JSON-RPC subprocess connection to the installed helper. Account identity and aggregate activity update at connection and every 15 minutes; allowance polling uses the selected 1, 5, 15, 30, 60, or 120-second cadence. Allowance-change notifications coalesce into an allowance-only refresh.

`LocalSessionMonitor` uses FSEvents plus a three-second safety check. It incrementally tails bounded JSONL records, watches writer locks, folds linked agents into root tasks, and retains all live tasks plus up to 200 recent root tasks from the prior 24 hours. The popover shows four recent tasks; the Dashboard starts with ten and reveals ten more per action.

Provider protocols and an injectable clock keep account, local-session, notification, date-range, freshness, and pacing behavior testable.

## Privacy

CodexGauge has no analytics, backend, updater, or telemetry upload. It does not model or retain prompts, answers, reasoning, command output, tool contents, email, credentials, or authentication tokens.

Only preferences, notification deduplication keys, and the latest account snapshot are persisted. Task identifiers and telemetry remain in memory. Notification Center receives generic attention text without task names. See [PRIVACY.md](PRIVACY.md) for the complete boundary.

## Build and test

The required stable toolchain is recorded in [.xcode-version](.xcode-version). The project intentionally fails release validation under a different Xcode build.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/check-toolchain.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build -project CodexGauge.xcodeproj -scheme CodexGauge \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project CodexGauge.xcodeproj -scheme CodexGauge \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

UI tests require macOS Accessibility/Automation permission for Xcode’s test runner. CI performs them on clean runners. The macOS 14 compatibility job records and uses the newest Xcode supported by that runner; release artifacts are built only with the exact toolchain in `.xcode-version`.

Every local release also runs a deterministic 25-minute Release-mode resource gate. Quit other CodexGauge instances before running it:

```sh
./Scripts/performance-check.sh
```

The committed budgets require a closed app to average under 1% CPU and remain below 100 MB physical footprint, with separate limits for visible and expanded surfaces. See [Performance/README.md](Performance/README.md) for scenarios, measurements, and diagnostic artifacts.

The application target uses macOS 14.4, hardened runtime, no App Sandbox, `LSUIElement`, and an arm64-only Release architecture. The checked-in Icon Composer source is compiled with the asset catalog so current macOS releases use the native layered icon and older supported releases receive Xcode's compatibility representation.

## Troubleshooting

### Usage is unavailable

Open ChatGPT, confirm that you are signed in, and choose Refresh. In Settings, **Check again** reruns discovery. A manually selected helper is launched and initialized before CodexGauge accepts it.

### A task is missing

Confirm that the task ran on this Mac during the past 24 hours. Remote-only tasks cannot be discovered from local files. Unlinked internal work may appear as background Codex work.

### Data is stale

CodexGauge retains the last successful account snapshot while offline or signed out and clearly marks it stale. The refresh loop uses bounded backoff rather than retrying continuously.

### Notifications do not appear

Check **Settings > Notifications**. If permission is denied, use **Open Notification Settings**. Each allowance threshold is sent once per reset cycle. A task attention alert is sent only for an exact local input or approval request.

## Authentic releases

Official downloads are published through this repository's GitHub Releases page. Release artifacts are signed by North Wolf Labs LLC, notarized by Apple, and accompanied by SHA-256 checksums. Private signing and publication procedures are intentionally not documented in this public repository.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

CodexGauge is licensed under [Apache License 2.0](LICENSE).
