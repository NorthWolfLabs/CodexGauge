# Companion simulator acceptance — September 30, 2026

This is the current continuation report. [Earlier development review](2026-09-30.md)
contains historical Mac and physical-phone results; those are not new device
verification of the changes below. This pass uses only the dedicated iPhone 17 Pro
simulator (`98F554DE-F267-4C9C-965A-5B98D180093D`, iOS 27 / Xcode 27).

## Fixes

- Chart taps retain selection after lifting the finger. Calendar-day selection
  uses the tapped day rather than rounding to the closest midnight, which could
  incorrectly select tomorrow after noon.
- A point marks the first observation after reconnecting. Separate line segments
  preserve missing-observation gaps instead of inventing throughput between them.
- Notification response completion runs explicitly on MainActor. The previous
  async Objective-C delegate adapter crashed UIKit during a real APNs banner tap.
- Live Activity delivery timestamps use the current sender time; observation age
  stays in content and stale deadlines. Foreground applications run sequentially
  and reject older observations so queued work cannot regress newer state.
- Revocation and disabling remote Live Activities request immediate dismissal.
  Normal task completion retains its existing 60-second finished-card period.

The existing **development** relay was updated to version
`47737bc8-feb1-4edc-bf54-7105093af0a2` at
`https://codexgauge-relay-dev.north-wolf-labs.workers.dev`. Existing APNs secrets
were preserved. No tagged release, RC, TestFlight, App Store upload, or production
distribution was created.

## Passed checks

| Check | Evidence |
| --- | --- |
| Shared Swift tests | **20 passed**, `.build/simulator-acceptance/core-final.log` |
| Relay tests, types and deployment bundle | **34 passed**, same log |
| Simulator app, extension and UI-test build | `.build/simulator-acceptance/build18.log` |
| Device-target compilation, without signing or installation | `.build/simulator-acceptance/device-final3.log` |
| Chart 7/30/90-day totals and averages, exact selected day, selection reset, invalid-link correction | `CompanionAcceptanceUITests` in `.build/simulator-acceptance/acceptance4.xcresult` |
| Stale task → fresh observation, waiting/completed empty history, usage-only replacement, separated throughput segments | Same acceptance suite; final gap rendering also passed in `acceptance5.xcresult` |
| Two Macs with the same task identifier, warm/repeated/cold URL routes, one-Mac revocation preserving the other | `acceptance4.xcresult` |
| **Actual APNs** task banner tap: warm, cold and repeated; correct task/Mac and read-only completed detail | **1 passed**, `.build/simulator-acceptance/push-normal.xcresult` |
| Medium Home Screen widget placement | **1 passed**, `widget-medium4.xcresult`; installed screenshot visually verifies **63%**, **137 credits**, **7 banked resets**, and reset countdown against a live disposable feed |
| Long Mac/task names and read-only approval detail | **1 passed**, `long-names2.xcresult`; screenshot inspected, full names wrap within the card |
| Whole Live Activity access lifecycle | **1 passed**, `activity-final.xcresult`: off/on, usage-only, dismissal/reconnect, unlink/relink, revocation and later publisher state. Aggregate also has **1 skipped** separately opt-in completion test |
| Background Live Activity start → approval → card-to-task navigation → completion and whole-card disappearance | **1 passed, 0 skipped**, separate `activity-completion-final.xcresult` after enabling its explicit opt-in |
| Running Mac beta signature | `codesign --verify --deep --strict` passed; existing process 75333 remains running |
| Retired integration removal | Slack/ntfy source references remain only in migration and credential cleanup |

The APNs test uses normal persisted pairing: a system cold launch has no XCTest
launch arguments. An intermediate test used a separate test credential service,
so its cold launch opened a different saved profile. That harness failure is
preserved in `push-fixed.xcresult`; the corrected normal-profile test passes.
URL-opening tests are listed separately and are not counted as notification
delegate evidence.

## Inspected screenshots

All fixtures below are synthetic. Export manifests map attachment names to files.

- Cold APNs task detail:
  `.build/simulator-acceptance/push-normal-attachments/0FB3960D-534D-47EC-BD82-779896C094B3.png`.
- Repeated APNs task detail:
  `.build/simulator-acceptance/push-normal-attachments/0B312970-D823-4F87-8B23-2EAC65B9B1D9.png`.
- Exact selected day, 100 tokens:
  `.build/simulator-acceptance/attachments4/C13C1591-AD0E-49E5-9629-86684EBF4052.png`.
- Throughput with two separate observed segments:
  `.build/simulator-acceptance/attachments5/985A1712-95F6-4CF1-BD44-E3712E771E11.png`.

- Installed medium widget, distinct live fixture values:
  `.build/simulator-acceptance/widget-medium4-attachments/F8BBC5B9-8FAE-4A1D-85A9-F796F395B797.png`.
  Gallery/placement automation passed; WidgetKit retired the rendering extension’s
  accessibility process, so content assertions use explicit screenshot review.
  The image is an installed Home Screen widget, not a gallery preview.

- Long-name detail:
  `.build/simulator-acceptance/long-names2-attachments/6FC6E179-5C92-4C39-9B03-79277F204E51.png`.
- Native activity before access removal:
  `.build/simulator-acceptance/activity-final-attachments/69014D5A-AF91-463C-B2D5-4F2CA342315C.png`.
- Native card fully gone after remote revocation:
  `.build/simulator-acceptance/activity-final-attachments/62E2F7C6-7F42-4BFF-8614-252A52CE3F59.png`.

- Background APNs approval card:
  `.build/simulator-acceptance/activity-completion-final-attachments/FC923F57-A544-4EDE-999B-6D4A0B0AB18B.png`.
- Native card opens its read-only task:
  `.build/simulator-acceptance/activity-completion-final-attachments/57DAA678-31EC-4567-B0B9-3EF70840277F.png`.

## Live Activity verification status

The strengthened lifecycle test queries the **whole native card by its Mac name**.
An earlier task-title query incorrectly considered an idle “No active tasks” card
removed. Its old removal screenshot is not passing evidence for whole-card
dismissal. Native dismissal/toggle transitions from that earlier run remain useful
diagnostics, but final removal requires the strengthened test.

The first strengthened rerun could not start a card. The simulator's
`liveactivitiesd` log explicitly reports:

> Push-to-start budget exceeded … not starting activity

The recorded budget was −4, with re-evaluation scheduled at **18:10:47 UTC**.
See `.build/simulator-acceptance/activity-daemon.log` and
`activity-full-card.xcresult`. This is a directly observed OS delivery limit,
not an inference from a missing screenshot. No budget, security, or notification
settings were modified to bypass it. An accepted APNs request is not a visible
card assertion.

After the recorded natural recovery, the strengthened access test **passed** all
whole-card transitions, including revocation while backgrounded and absence after
a later publisher update. Initial and revoked screenshots were visually inspected.
The separately opt-in completion check then **passed without skips**, including
background approval, card-to-task navigation, and disappearance of the entire
ended card after its normal retention period. No simulated push injection was used.

The two reusable recipes (`user-notification-explicit-completion` and
`activitykit-whole-card-removal`) have standalone helpers that typecheck against
the simulator SDK. Their runtime claims are bounded to this tested OS/SDK.

## Limits and review gates

- No physical-phone interaction, installation, or testing in this continuation.
- Current Mac visual review was not repeated: native automation timed out. Its
  existing beta is still running and passes signature verification.
- Actual Mac sleep/wake, disrupted mobile networking, long background soaks,
  minimum-supported-OS and genuine Intel runtime coverage remain release gates.
- WidgetKit/APNs scheduling remains system-managed; no one-second background
  update guarantee is claimed.

The notification completion fix also has a bounded reusable recipe in the
macOS-Recipes catalog: `user-notification-explicit-completion`, including a
standalone Swift helper, failing-before/passing-after evidence, and OS/SDK limits.

Primary references: [Apple chart selection](https://developer.apple.com/videos/play/wwdc2023/10037/),
[Apple notification response completion](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:didreceive:withcompletionhandler:)),
and [Apple ActivityKit push lifecycle](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

## Final review state

The dedicated simulator has the latest development app and is left in isolated
`-companionDemo` mode. Normal-profile synthetic widget/push links were removed;
the installed widget’s live-data screenshot is retained as evidence. Remote
disposable feeds were deleted by test teardown. The dedicated loopback fixture
process tree was stopped and port 8798 has no listener. The existing Mac beta
remains running; no other simulator, physical device, application, network or
security configuration was changed. Whitespace and strict Mac signature checks
passed. Hardware/background-soak and distribution gates above remain open.
