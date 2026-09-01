# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). CodexGauge uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-09-01

- Added Universal 2 support so one CodexGauge app runs natively on Apple-silicon and Intel Macs running macOS 14.4 or later.
- Extended local and GitHub release gates to compile and verify both architecture slices, run the Intel slice through Rosetta, and test on a genuine Intel runner when Actions capacity is available.
- Renamed public disk images with a `-universal.dmg` suffix so architecture support is explicit without separate downloads.

## [1.1.1] - 2026-09-01

- Fixed an overnight crash caused by macOS delivering its calendar-day change notification on a background queue at midnight.
- Routed clock, time-zone, calendar-day, and wake notifications safely through the main actor before updating the menu-bar item.

## [1.1.0] - 2026-08-29

- Restored near-live local task updates with a bounded one-second fallback for known live tasks and immediate tail catch-up for large rollouts.
- Made live rates easier to follow with calm integer-only numeric transitions and a continuously flowing, noninteractive Dashboard graph.
- Replaced cliff-edge token windows with time-weighted rates that decay every second during tool use and other pauses, without reporting new token usage.
- Stabilized Activity range selection, made Today summaries range-appropriate, corrected short-range and popover chart geometry, and eliminated an unsupported Charts axis-label configuration.
- Removed manual allowance refresh controls; allowance checks and connection recovery now happen automatically while live task activity continues independently.
- Added native menu-bar customization for allowance selection, optional comparison values, reset timing, usage-amount or remaining-target pace estimates, and accessible semantic status colors.
- Clarified dependent menu-bar settings, repaired invalid color-target combinations, restored native menu-bar contrast, confirmed destructive resets, and made Settings reliably take keyboard focus.
- Prevented unreliable pacing alerts immediately after allowance resets, improved the status symbol’s menu-bar sizing, shortened color guidance, and added a clear explanation for genuine warnings at the top of the popover.
- Streamlined GitHub release downloads to the signed DMG and its checksum while retaining debug symbols, build metadata, and notarization receipts as release-engineering records.
- Made the local Release performance gate produce an isolated ad-hoc-signed app so current macOS versions can execute the harness without changing production signing.

## [1.0.0] - 2026-08-24

- Added native menu-bar allowance monitoring for Apple Silicon Macs running macOS 14.4 or later.
- Added local live-task and recent-task activity, account activity charts, allowance alerts, attention alerts, Settings, Help, and a detailed Dashboard.
- Added privacy-safe local telemetry processing, Developer ID release validation, notarized DMG packaging, and automated release workflows.
- Rebuilt transient popover and Dashboard lifecycles so hidden surfaces release their SwiftUI trees, timers, charts, animations, and temporary state.
- Moved executable trust validation off the main actor and reduced idle session work with event-driven file updates, rotating fallback checks, and deduplicated snapshots.
- Replaced the token-mix chart with a lightweight accessible visualization and tightened gauge, disclosure, chart, Settings-validation, and Reduce Motion behavior.
- Added a strict 25-minute Release-mode performance gate, runtime-log diagnostics, failure traces, and a mounted-DMG smoke test.
- Corrected the app icon's current-macOS sizing by compiling the native Icon Composer source, removed the initial disclosure focus ring from mouse-opened popovers, and restored prerelease-corrupted allowance-alert preferences to the off-by-default 20%, 10%, and 5% presets.
- Disabled Writing Tools for telemetry, path, and numeric surfaces so short-lived popovers do not retain unnecessary Apple Intelligence sessions, and expanded performance samples with resident and maximum-footprint diagnostics plus transparent filtering for isolated kernel-accounting transients.
- Bound every production helper launch to an atomic OpenAI Developer ID launch requirement and raised the minimum system version to macOS 14.4, where Apple introduced that protection.
- Bounded session discovery, writer-lock probing, and JSONL record work before sorting or decoding; anchored local telemetry reads against intermediate symlink replacement; and added forced cleanup for helpers that ignore graceful termination.
