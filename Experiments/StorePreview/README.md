# Full-app sandbox preview

`CodexGaugeStorePreview` is an isolated target in the main Xcode project. It builds the real settings, dashboard, Codex account client, session monitor and companion publisher with App Sandbox enabled. Its identity is `com.northwolflabs.CodexGauge.store-preview`; preferences, support files and companion credentials are separate from the working beta. This is a development investigation, not a submitted or approved Mac App Store build.

## Run

```sh
xcodebuild build -project CodexGauge.xcodeproj -scheme CodexGaugeStorePreview \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/store-preview
open -n '.build/store-preview/Build/Products/Debug/CodexGauge Store Preview.app' \
  --args -showNotificationsSettings
```

Signing defaults to the project's North Wolf Labs Developer ID identity for local testing. Supply another valid identity/team for your own development environment. The Release configuration is also a local preview, not App Store distribution signing.

In General settings, choose the Codex data folder, then an already-installed OpenAI-signed `codex` executable. Hidden files are visible in the pickers; Command-Shift-G accepts a full path. The helper selection retains signature validation and the launch-time code requirement. A folder path in defaults alone never grants access or triggers discovery in this target.

Folder selection needs read/write access because Codex initializes its database there. Helper bookmarks are read-only. Security-scoped bookmarks restore at launch without showing a picker; stale bookmarks are renewed while access is held. Failed restoration asks for selection again. A failed replacement keeps the preceding saved grant. Readers and subprocess termination handlers retain grants for their own lifetime, so switching selections cannot release access while the old helper is shutting down.

Before testing real saved sign-in, obtain explicit permission to grant this separate identity **persistent** access to the real Codex folder. The earlier compatibility probe's temporary grant does not authorize that change in access duration. Do not copy `auth.json` into a fixture. Leave companion sharing off for isolated fixture tests.

## Disposable fixture

```sh
uv run --script Experiments/StorePreview/fixture.py working
```

Select `.build/sandbox-fixture-read-write` in the folder picker. It contains only synthetic data and has no saved sign-in. An account/allowance error is expected for that fixture; it does not establish account connectivity. `fixture.py completed` appends a completion event for the same synthetic task. Do not run the helper with your real `CODEX_HOME` as a substitute for this fixture.

## Evidence and limits

September 29, 2026, Apple silicon, macOS 27.0 (26A428), Xcode 27 (27A266a):

- Signed full-app Debug build launches with App Sandbox, selected-file access, app-scoped bookmarks and outbound network access.
- Before selection it requests a folder and does not discover a helper. Both fixture grants saved through native pickers and restored after quitting and relaunching. The selected bundled helper (`0.158.0-alpha.2.1`) launched from the restored grants.
- Folder and helper buttons are separately exposed in AX. A `LabeledContent` folder row initially omitted its button from AX; using the same caption/HStack structure as the helper row fixed this.
- The Mac unit suite passed 111 tests, with 1 skipped and 0 failures. New tests cover missing grants, no discovery fallback, stale bookmark renewal, failed replacement, release lifetime and direct-build isolation. Focused identity/access checks also passed after the last identity adjustment.
- Universal Release compilation covers `arm64` and `x86_64`; only Apple silicon has been executed. Debug and Release products do not link or embed Sparkle. The shared license text may still be copied as an attribution resource.
- With explicit user approval for persistent real-folder access, General settings reported **Connected to Codex**. A relaunch restored both grants, fetched fresh account allowances with no connection error, loaded real tasks, and observed changes in task metadata. The completed 60-second runtime check ended with 5 tasks, 3 running, 0 awaiting input/approval, and 32 observed task-data changes. This used the same bundled `0.158.0-alpha.2.1` helper as the fixture check; the beta's standalone helper was not separately tested under sandbox. The preview was closed afterward; saved grants remain as authorized. The normal beta was still connected and Publishing.
- September 30: the signed sandbox app passed seven controlled checks using its production session monitor against disposable data inside its own container: initial running, needs input, resumed running, needs approval, completed/excluded from live tasks, catching an event written while stopped, and continuing to tail after restart. Observed local detection times were 0.1–0.4 seconds; these are fixture measurements, not a network latency guarantee. No fixture events were routed to notifications or the companion.
- Dashboard visual inspection still triggers a `SkyComputerUseService` crash (`Array.remove(at:)`); the preview remains running. A single-open `-showDashboard` retry failed too, ruling out repeated dashboard open/close as a necessary trigger. The bounded runtime checks verify the data path independently of that tool's dashboard traversal. Visual dashboard inspection, actual system sleep/wake, and the minimum-OS/Intel runtime matrix remain open.

### Bounded runtime check

The preview target alone compiles `RuntimeVerification.swift`. In Debug, launch with `-sandboxVerification` after choosing the desired folder/helper. It presents a simple native diagnostic window and samples the app's actual `AppState` once a second for 60 seconds. It reports restored-grant flags, account freshness/error flags, task counts, running/waiting counts, and changes in task identity/state/token totals/activity timestamps. Rate decay alone does not count as a task-data change. No task or account identifiers, titles, messages, credentials, or allowance values are written to the report.

The report is also saved as `sandbox-verification.json` in this app's own sandbox home. macOS may prevent another app or shell from reading that container; use the native diagnostic window rather than bypassing container protection. The flag does nothing in Release, and the source is not included in the direct-download/beta target.

### Controlled task transitions

Launch the Debug preview with `-sandboxFixtureTransitions` to run the seven checks above. A native diagnostic window reports each result and elapsed detection time. Each step has an eight-second deadline; the test stops its readers and deletes only its generated temporary fixture afterward. It does not change saved folder/helper grants or feed synthetic tasks into `AppState`. Restarting the reader establishes recovery from a monitoring interruption, not a full system sleep/wake test.

`-showDashboard` opens the dashboard once in Debug builds and is useful for manual inspection without the repeated-open performance scenario.

The store target compiles a no-op updater and has no Sparkle package-product dependency or update feed configuration. Apple's [review guidelines](https://developer.apple.com/app-store/review/guidelines/) require App Store-delivered updates and separately govern reliance on another installed application. Technical sandbox compatibility does not promise review acceptance. The direct-download target retains its existing updater.
