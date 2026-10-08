# Relay reset verification — October 7, 2026

## Subsequent missing-card recovery

The normal account lost its Live Activity after the later removal work. The
foreground recovery and fixture isolation were corrected; see [the recovery
report](Live-Activity-Recovery-2026-10-07.md) for the latest deployment and actual
saved-account evidence. The measurements below describe the earlier interval.

## Subsequent inactive-card fix

After the reset verification below, the user reported the retained “No active tasks” card. The app and relay now dismiss on completion/empty state. The iPhone 12 whole-card removal check passed and the phone update is installed. Relay version is now `7afd2ec2-d96b-4129-98aa-08100cf03c9d`; protocol 2 is unchanged. See [the follow-up report](Live-Activity-Inactive-Dismissal-2026-10-07.md) for its native coverage and failed-check history. The measurements below describe the earlier verification interval.

## Verified now

The Cloudflare write limit is no longer blocking the relay. A disposable feed passed initialization, pairing, device-name round trip, publisher acknowledgement, HTTP push batches, fresh context/rate reads, usage-only redaction, and device revocation. Test feeds were removed. Protocol 2 / publisher-driven-push is still deployed at version `34472604-59f5-4d95-bee8-8a58cca18ae5` (October 6, 13:11:42 UTC); this verification did not deploy a Worker or change the architecture.

Thirty cloud WebSocket samples measured median 18.9 ms, p95 23.8 ms, maximum 40.4 ms. These are Mac-hosted publisher/viewer measurements, excluding Codex observation, phone radio, rendering, and Apple delivery scheduling.

The physical iPhone 12 passed remote Live Activity start while backgrounded, context/rate/phase changes, a separate metrics-only update, two task-selection round trips, approval, correct read-only task opening, and completion/card removal. Its normal connection to the installed sandboxed Mac passed Overview, Tasks/current-turn timers, and Activity. Completion notifications passed foreground updates, background delivery, and correct warm/cold/repeated notification taps. The phone's original completed-alert preference was off; that baseline was restored. Follow-active-tasks was already enabled and remains enabled. The app was launched normally afterward. Only the iPhone 12 was used for physical-device operations.

Both installed Mac Release apps reconnected using their existing folder/helper grants. Their signatures, four sandbox capabilities, universal architectures, privacy/migration manifests, and absence of Sparkle/test components passed the package checker. The existing signed Mac App Store installer passed its profile/signing checker again. No Store upload or review submission occurred.

After the user opened the installed Beta dashboard, a native test inspected that existing window without relaunching the app or using the menu-bar click path. Overview, Tasks, Limits, and Activity captures were visually reviewed. `Refine account card` appeared exactly once in Tasks with a visible current-turn timer of 37m 52s, context, token rate, project, model, and current tool phase. The test passed and left the dashboard open on Tasks.

## Fix and review changes

The delayed-confirmation native selector test exposed an old delivery-clock preview: the intent ran, but the new title did not appear within five seconds while confirmation deliberately waited six seconds. The preview and failure restoration now use the current application delivery time while preserving the source observation and stale deadline. The same native test passed two cycles, asserting and capturing the new title and pending selection before confirmation returned. This is a bounded responsiveness check, not proof of zero-frame latency on every device.

The account-order test still asserted the former position. It now verifies that balances precede the account identity, matching the requested account-last design. The push harness now obtains permission through the actual alert preference and checks publisher-side registration; it does not depend on the removed diagnostics button or URL text field. Live Activity checks now assert real context/rate/phase changes, metrics-only delivery, and task switching; timer animation alone cannot pass them. They restore changed preferences afterward.

Final native captures were visually inspected for readable Lock Screen content, compact thread/project/button alignment, pending task selection, real task timers, account hierarchy, alert disclosures, and pairing layout. The Mac QR sheet was inspected in the installed app and its explanatory text wraps.

The reusable timestamp pattern and its verification limits are recorded in macOS-Recipes under `activitykit-selection-preview-clock`. Apple's [timestamped ActivityKit update documentation](https://developer.apple.com/documentation/activitykit/activity/update(_:alertconfiguration:timestamp:)) states that older updates are ignored; the precise internal reason for this old-clock preview's presentation behavior is an inference from the native comparison.

## Completed test results

Artifacts are under `.build/reset-verification-2026-10-07/`; `test-summary.json` records result-bundle counts.

| Check | Result | Evidence |
| --- | --- | --- |
| Mac unit suite | 122 passed, 0 failed/skipped; 128 parameter executions | Mac-Unit.xcresult |
| Companion core | 46 passed | companion-final.log |
| Relay integration/runtime/types/bundle | 56 passed, 0 failed/skipped | companion-final.log |
| Installed main/Beta connection | 1 passed each | Mac-Installed.xcresult; Beta-Installed.xcresult |
| Already open installed Beta dashboard and single current task | 1 passed | Mac-Open-Dashboard.xcresult |
| Account order and delayed selector confirmation | 2 passed | Mobile-Retry.xcresult |
| Account light/dark/accessibility layouts, navigation/pairing/task summary, alerts, Overview working glyph | 4 passed | Mobile-Final-UI.xcresult |
| Final physical background lifecycle and normal Mac connection/preferences | 2 passed | Phone-Final.xcresult |
| Real completion notification delivery/routing | 1 passed | Phone-Push.xcresult |
| Installed package and Store export | Passed | package checkers; store-export.log |

The earlier eight-case mobile run reported six passing cases and two failures in its log, then its result collector stalled. It was stopped; its incomplete result bundle is not claimed as completed evidence. The two failures were corrected and rerun successfully, and the four general UI cases were repeated in a completed bundle. The initial expanded-Island pixel/geometry and Lock Screen fixture cases passed in the retained log; these are separately identified as log evidence.

## Remaining checks and limits

Two additional installed-Beta menu-bar tests failed to reach the dashboard/popover through their click path on the current display setup. Neither reached the duplicate-title or account-layout assertions. Those failures are retained in `Mac-Actual-Tasks-Accounts.xcresult`. The computer-use native connection subsequently returned `native pipe closed before response`, including after reset. The user opened the dashboard, and the alternative native test passed the actual dashboard checks and supplied fresh visual captures at 08:44 EDT. The popover click path itself was not repaired or reverified in this run. This report does not classify the click failures as a proven product defect or dismiss them as a proven test-only defect.

The phone still registers the generic `iPhone` name. The Apple entitlement discussed earlier was not added/approved; this issue is not claimed fixed.

Cloudflare analytics for the verification interval recorded successful SQL writes, but also disconnected HTTP/stream/alarm invocations. It reported no `scriptThrewException` group in that interval. Analytics are delayed/sampled and test creation, lifecycle, revocation, and cleanup distort per-user normalization. `usage-before.json`, `usage-verification.json`, and `usage-final.json` are retained locally. Today's short session does not verify the proposed monthly per-user cost. Representative active-user days and ongoing delivery evidence are still needed.

OS/device coverage here is macOS 27.0.1, Xcode 27, iOS 27 on iPhone 12, and the dedicated iOS 27 simulator. Minimum OS, Intel runtime, every sleep/network-loss pattern, general animation/scroll performance, and App Review acceptance are not established by this run. Missing source telemetry is not replaced with invented context, token rate, or elapsed values.

Physical captures/result bundles can include private account and system-notification content. They remain local; pairing-bearing scratch plans were removed and textual pairing logs were redacted. No personal evidence was copied into the reusable recipe.
