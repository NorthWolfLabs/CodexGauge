# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). CodexGauge uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Refine account and allowance cards, task and activity headers, and current-turn runtime recovery on Mac and iPhone. Deduplicate task rows and restore the Overview working indicator.
- Move Mac pairing into Devices settings with a wrapped QR sheet and individual device removal. Link from iPhone by scanning or pasting without exposing the viewing URL.
- Deliver Live Activity updates through publisher-driven push and durable delivery queues. Recover missing cards, end inactive cards immediately, and let the compact task selector cycle between running tasks.
- Format available credits with at most four fractional digits and no trailing zeros. Use line charts for longer mobile activity ranges, including 1 Year and All.
- Enable App Sandbox on the main Mac and beta targets, retain scoped folder/helper access, add migration and privacy manifests, and provide local Mac App Store archive/export checks. Remove the retired external updater and its rehearsal tooling.

- Add native ActivityKit Lock Screen and Dynamic Island task summaries, with per-Mac APNs start/update/end delivery, waiting-task priority, dismissal handling, and access revocation. Keep delivery ordering separate from Mac observation age and request immediate dismissal when access is removed.
- Add selectable 7/30/90-day mobile token charts and five-minute task throughput charts with explicit gaps after reconnecting.
- Retain tapped chart-day selection, select the correct calendar day after noon, and show isolated throughput observations after reconnection.
- Fix a crash when tapping a real task notification by completing its response delegate on the main actor; verify warm, cold, and repeated notification navigation.
- Show available credit balances beside banked resets on iPhone, in the medium Home Screen widget, and in Mac allowance views. Preserve exact and unlimited balances.

- Open task notifications directly in the linked task’s read-only detail, return allowance notifications to Overview, and show invalid viewing-link errors in the linking form.
- Preserve simultaneous phone subscriptions, enforce the subscriber limit under concurrent requests, and revoke feed access before asynchronous deletion cleanup.
- Send live snapshots in order before push processing, align Swift text limits with the relay’s Unicode rules, and keep APNs payloads within 4 KB without splitting emoji.
- Keep widget refreshes from overwriting newer app data or restoring removed viewing links. Mark stale usage on the widget timeline and clear revoked feeds from live views.
- Isolate phone alert registration failures per Mac, report unlink failures where they occur, and let revoked links be removed.
- Bound WebSocket reads and writes, cancel stalled connections, and keep foreground viewing streams alive with relay-only heartbeats.
- Fit long Unicode task summaries within the relay payload limit, retaining allowances and active tasks before completed history.
- Prioritize tasks needing attention, show complete titles in task details, improve accessibility text-size layouts, and label the activity chart.

- Add a separate full-app sandbox preview with native folder/helper selection, persisted security-scoped access, and no Sparkle dependency. Verify restored real-folder access, fresh allowances and live task-data changes after relaunch; retain grants until readers and helper processes finish using them. Controlled sandbox checks also cover task input, approval, completion, and recovery after restarting the monitor.
- Add a read-only iPhone companion with linked-Mac live usage/task views, Cloudflare relay, APNs alerts, and Home Screen/Lock Screen widgets. Verify real Mac linking and widget layouts on iPhone 17 Pro; retain the last confirmed usage across pending resets.
- Add an isolated Mac sandbox compatibility probe. Installed-helper launch and app-server initialization work with a selected writable fixture; bookmark restoration and filesystem events also work after relaunch. Fix the file reader to honor a scoped directory grant without opening its ancestors. A user-approved check also passed saved sign-in and authenticated allowance access; Store integration and review eligibility remain under investigation.

- Remove the experimental Slack and ntfy integrations, including setup, remote routing, counters, command handling, and Slack artwork. Preserve Apple alert choices and clear retired local integration credentials and queues on launch.
- Add per-event Apple notifications for task working, input/approval, completion, banked resets, and allowance resets alongside low-allowance alerts. Identify tasks by title and saved project name.
- Preserve account-scoped observations, offline catch-up, persistent local-delivery retries, and duplicate suppression. Require an explicit completion event before announcing a finished task.
- Keep notification settings focused on alert choices and thresholds. Request permission in context and check current authorization before delivery.
- Generate light/dark branding, README artwork, and legacy fallback icons from the current Icon Composer source.
- Preserve native Edit menu shortcuts for text inputs.
- Replace the beta suffix with an optional β icon in the gauge slot, using the same renderer in the menu bar and preview. Warning symbols retain their meaning.
- Keep the popover anchored as menu-bar items move, expose its native glass material, and dismiss it when another menu-bar item is clicked.
- Find OpenAI-signed standalone Codex helpers, keep task monitoring independent of helper discovery, and improve disconnected recovery actions.
- Add local beta packaging with separate app identity, preferences, and caches for side-by-side testing.
- Refresh allowances immediately after wake and document snapshot-based reset detection limits.

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
