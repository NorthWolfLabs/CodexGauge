# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). CodexGauge uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
