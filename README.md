<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="TokenTach/Branding/TokenTach-Dark.png">
    <img src="TokenTach/Branding/TokenTach-Light.png" width="128" height="128" alt="TokenTach app icon">
  </picture>
</p>

<h1 align="center">TokenTach</h1>

<p align="center">
  A native, read-only menu-bar monitor for Codex allowances and activity.<br>
  Uses the Codex app server and local metadata already available on your Mac—no additional login, API key, or account token required.
</p>

<p align="center"><sub>Independent software from North Wolf Labs. Not affiliated with or endorsed by OpenAI or Apple.</sub></p>

## Compatibility

- Apple Silicon and Intel (`arm64` + `x86_64` Universal 2)
- macOS 14.4 or later
- An installed and signed-in ChatGPT or Codex app, or a compatible Codex executable
- Public releases are validated on Apple silicon, an Intel Mac, macOS 14.4, and the current macOS release line

Intel support begins with TokenTach 1.2.0. TokenTach 1.1.1 and earlier remain Apple-silicon-only releases.

## What it shows

- Every allowance bucket and window returned by Codex, including reset time, remaining percentage, pacing estimates when enough metadata exists, credits, spend controls, and earned resets
- A customizable menu-bar summary with a primary and optional additional allowance, reset timing, an estimated sustainable pace, and optional semantic status colors
- Live tasks on this Mac, including phase, current-turn duration, rolling token rate, token mix, latest context use, response-start latency, and linked-agent count
- Up to 200 recent local root tasks from the previous 24 hours
- Account-wide daily activity, period comparisons, lifetime tokens, streaks, peak day, and longest turn
- Per-event Mac and iPhone notifications for low allowances, task working, task input/approval, task completion, banked resets, and allowance resets
- Account-scoped reset detection and snapshot-based catch-up

Task token rates measure local activity. They are not a task’s share of the account allowance. Tasks that run only on another computer are not visible locally.

Menu-bar customization is available in **Settings > Menu Bar**. The default remains a monochrome gauge and the Codex allowance with the least remaining. Reset timing, an additional allowance, suggested pace, and colors are opt-in. Suggested pace can show either the percentage points available per day or hour, or the remaining target at the end of the current allowance day or hour. Both are local estimates, not separate daily allowances issued by OpenAI.

Warnings Only keeps normal values monochrome and adds yellow or red only when an allowance or its projected usage needs attention. Traffic Light also uses green for a healthy status. Remaining-allowance warnings begin at 20% and become critical at 10%. Usage pace turns yellow when the current pace is projected to use 90–100% by reset, and red when it is projected to run out early. Pacing status is withheld immediately after a reset, when whole-percentage account data is too coarse for a reliable projection. Every warning is explained at the top of the popover and reinforced through its symbol and accessibility text. If a specifically selected allowance temporarily disappears, TokenTach keeps the preference and shows the lowest Codex allowance until it returns; an additional fallback is hidden when it would duplicate the main percentage.

## Installation

1. Download the `universal.dmg` from the repository’s Releases page. The same app runs natively on Apple silicon and Intel Macs.
2. Verify the checksum in `SHA256SUMS`:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Open the DMG and drag TokenTach to Applications.
4. Launch TokenTach. It appears only in the menu bar.

To inspect Apple’s signature and notarization result:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/TokenTach.app
spctl --assess --type execute --verbose=4 /Applications/TokenTach.app
```

TokenTach immediately searches for a usable Codex helper. Use **Settings > General** only if automatic discovery cannot find it or your Codex data folder is nonstandard.

## Architecture

One AppKit-owned application lifecycle manages the status item, popover, Settings, Help, and Dashboard windows. SwiftUI provides the interface, Charts, gauges, forms, and accessibility behavior.

`CodexAppServerClient` keeps a newline-delimited JSON-RPC subprocess connection to the installed helper. Account identity and aggregate activity update at connection and every 15 minutes; allowance polling uses the selected 1, 5, 15, 30, 60, or 120-second cadence. Allowance-change notifications coalesce into an allowance-only refresh.

`LocalSessionMonitor` uses FSEvents plus a one-second bounded safety check for known live tasks. It incrementally tails bounded JSONL records, watches writer locks, rotates lightweight checks across inactive files, folds linked agents into root tasks, and retains all live tasks plus up to 200 recent root tasks from the prior 24 hours. The popover shows four recent tasks; the Dashboard starts with ten and reveals ten more per action.

Provider protocols and an injectable clock keep account, local-session, notification, date-range, freshness, and pacing behavior testable.

Menu-bar countdowns are updated by a local one-shot timer only when their displayed hour or minute changes. They do not trigger account requests or add a one-second polling loop.

## Privacy

TokenTach has no analytics or account login of its own. The development iPhone companion can send a bounded usage/task snapshot to an explicitly configured Cloudflare relay. It does not retain prompts, answers, reasoning, command output, tool contents, raw email, or Codex credentials. It derives a local account fingerprint from helper-provided account identity for reset comparisons.

Preferences, notification deduplication keys, the latest account snapshot, and configured reset-monitor state are persisted. Raw task identifiers and detailed telemetry remain in memory; pending task alerts retain their titles and project names until delivery. Salted task-identifier hashes and event timestamps support alert deduplication. Task alerts include their task names and associated project names in Notification Center. See [PRIVACY.md](PRIVACY.md) for the complete boundary.

## Build and test

The required stable toolchain is recorded in [.xcode-version](.xcode-version). The project intentionally fails release validation under a different Xcode build.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/check-toolchain.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build -project TokenTach.xcodeproj -scheme TokenTach \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO

for architecture in arm64 x86_64; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project TokenTach.xcodeproj -scheme TokenTach \
    -destination "platform=macOS,arch=$architecture" ARCHS="$architecture" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
done
```

An Apple-silicon development Mac can execute both test commands; Xcode runs the `x86_64` test process through Rosetta. An Intel development Mac runs the `x86_64` tests and can still compile the Universal 2 archive. UI tests require macOS Accessibility/Automation permission for Xcode’s test runner. CI performs them on clean Apple-silicon and Intel runners. The macOS 14 compatibility job records and uses the newest Xcode supported by that runner; release artifacts are built only with the exact toolchain in `.xcode-version`.

Every local release also runs a deterministic 25-minute Release-mode resource gate. Quit other TokenTach instances before running it:

```sh
./Scripts/performance-check.sh
```

The committed budgets require a closed app to average under 1% CPU and remain below 100 MB physical footprint, with separate limits for visible and expanded surfaces. See [Performance/README.md](Performance/README.md) for scenarios, measurements, and diagnostic artifacts.

The application target uses macOS 14.4, hardened runtime, no App Sandbox, `LSUIElement`, and the Standard Architectures setting. Release archives contain exactly the native `arm64` and `x86_64` slices. The checked-in Icon Composer source is compiled with the asset catalog so current macOS releases use the native layered icon and older supported releases receive Xcode's compatibility representation.

The main Mac target and beta packages now use App Sandbox, the current shared UI/features, persisted user-selected Codex folder/helper access, and no external updater. [Mac App Store packaging](Distribution/README.md) describes local Universal 2 archive/export, signed-package checks and migration of each identity's own app state. The Store export uses App Store Connect signing; Developer ID DMGs remain a separate distribution option. Nothing has been uploaded or submitted to Apple.

The earlier [sandbox probe](Experiments/SandboxCompatibility/README.md) and [full-app preview](Experiments/StorePreview/README.md) verified authenticated account access, restored grants and controlled local task transitions on their recorded OS/helper configuration. Those historical checks do not automatically verify the current relay architecture, supported OS/helper matrix or App Review acceptance.

## Troubleshooting

### Usage is unavailable

Open ChatGPT and confirm that you are signed in. TokenTach keeps trying automatically. If it cannot find Codex, choose the helper in Settings; a manually selected helper is launched and initialized before TokenTach accepts it.

Helper discovery supports the ChatGPT/Codex application bundles and OpenAI-signed standalone helpers in `~/.codex/packages/standalone/current/bin/codex`, `~/.local/bin/codex`, and common Homebrew locations. Every candidate is signature-validated before launch. Local task monitoring runs independently of helper discovery; the disconnected popover presents recovery actions, and local task data remains accessible in the Dashboard.

### A task is missing

Confirm that the task ran on this Mac during the past 24 hours. Remote-only tasks cannot be discovered from local files. Unlinked internal work may appear as background Codex work.

### Data is stale

TokenTach retains the last successful account snapshot while offline or signed out and clearly marks it stale. The refresh loop uses bounded backoff rather than retrying continuously.

### Notifications do not appear

Enable Mac notifications independently for each event in **Settings > Notifications**: allowance low, task working, task needs input or approval, task completed, banked reset added, and allowance reset. Enabling an alert requests permission only when needed; macOS controls delivery permissions. Preferences are kept if permission is denied, and current authorization is checked before scheduling. iPhone alert choices are independent and configured in the companion app.

Each allowance threshold is sent once per reset cycle. Working alerts follow observed running-state transitions. Input/approval and completion alerts require an exact local event; an idle task alone does not count as completed. Existing task history is silently baselined. Task messages include titles and saved project names when available, and omit workspace paths, prompts, and answers. Existing alert choices migrate; task-working and task-completed alerts start off.

Monitoring uses the configured allowance refresh cadence and Codex change events while the Mac is awake, including when locked. It refreshes after waking. Reset monitoring starts with a silent baseline and reports detectable changes after reconnecting only when account continuity can be established. Snapshot comparisons cannot reconstruct every intermediate reset; usage-only reset detection requires a confirming sample.

## Authentic releases

For the working release candidate, run `Scripts/package-candidate.sh mac` and `Scripts/package-candidate.sh ios`. These build Release configurations named **TokenTach**, with the normal gauge and no Beta label. `CANDIDATE_VERSION`, `CANDIDATE_BUILD`, and `CANDIDATE_OUTPUT_ROOT` control versioning and output under `.build/candidate/`. The Mac candidate retains the existing test app's `.beta` identity and storage so permissions and pairings survive. The locally provisioned iPhone candidate uses sandbox APNs, with its registration environment matched to the signed entitlement. App Store/TestFlight builds continue to use production APNs. See [the installed candidate record](Distribution/Working-Candidate.md).

The older `Scripts/package-beta.sh` remains available for explicitly labeled, side-by-side beta packages. It builds a Universal 2 **TokenTach Beta.app** and DMG under `.build/beta/`. Neither local packaging workflow tags, publishes or notarizes a release.

Beta builds use `com.northwolflabs.CodexGauge.beta`, separate preferences and Application Support files. By default, **β** replaces the normal gauge icon; Menu Bar settings can switch it back to the gauge or hide the icon. The preview uses the same icon renderer, and warning symbols still appear when needed. Both apps read the existing Codex sign-in. Stable builds keep their existing storage locations.

Official downloads are published through this repository's GitHub Releases page. Starting with version 1.2.0, the `-universal.dmg` contains both Apple-silicon and Intel slices; a separate architecture-specific download is unnecessary. Each release also contains a `SHA256SUMS` file for that download. Debug symbols, build records, and notarization receipts are retained separately as release-engineering records. Private signing and publication procedures are intentionally not documented in this public repository.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md), [SECURITY.md](SECURITY.md), and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

TokenTach is licensed under [Apache License 2.0](LICENSE).

## iPhone companion (development)

`Companion/TokenTachMobile.xcodeproj` contains the native iPhone/iPad app and Home Screen/Lock Screen widgets. Local TestFlight archives and distribution exports are supported; see [TestFlight preparation](Distribution/TestFlight.md). No build has been uploaded from this migration. The Mac keeps collecting data; the phone only views it. There is no command, approval, or task-control endpoint.

The Overview combines allowances and active tasks, Tasks groups work by Mac, and Activity shows aggregate usage. Running tasks and explicit requests for input or approval are active; completed tasks waiting for a follow-up are not. Several linked Macs with the same helper-provided account ID share one allowance observation—the newest available—not a sum. Distinct accounts remain separate. If account identity is unavailable, installations remain separate rather than guessing. Both foreground screens and widgets retain the last observation and indicate freshness.

Available credits appear alongside banked resets in Overview and in the medium Home Screen widget. The Mac popover and Limits dashboard also show the balance. Displayed balances use at most four fractional digits with trailing zeros removed; the underlying observation retains its precision. Unlimited balances remain explicit, and a missing credit observation is not treated as zero. Mobile Activity offers Today, 7 Days, 30 Days, 90 Days, 1 Year and All ranges with selection and averages. Longer ranges use line charts. Each task detail has a five-minute throughput chart built from observations received while the phone is connected. Reconnection gaps remain gaps rather than invented samples.

**Settings → Live Activities → Follow active tasks** enables native ActivityKit cards on the Lock Screen and Dynamic Island. On first use, iOS may ask you to allow Live Activities on the Lock Screen card. Accept that prompt to enable background updates; ordinary notification permission is separate. One activity summarizes each active Mac, prioritizing tasks needing input or approval and showing working/waiting counts. Tapping opens the read-only task detail. The relay sends ActivityKit start/update/end pushes; iOS 17.2+ supports remote starts, while iOS 17.0/17.1 requires the app to start an activity in the foreground. State transitions are sent promptly. Foreground Live Activity updates are coalesced by the app; background numerical changes are published at most once per minute. Phase changes are coalesced to five seconds. Phase changes use prompt delivery no more than every thirty or sixty seconds respectively, with a prompt freshness update at least every two minutes while observations continue. APNs and ActivityKit scheduling are controlled by Apple, so these are not one-second delivery guarantees. Live Activity observations become stale after 180 seconds; disconnected Macs never receive fabricated fresh timestamps. See [Apple's ActivityKit push documentation](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

User dismissal suppresses a Mac's activity until its active tasks have cleared. Switching Live Activities off and on explicitly resets that choice. Unlinking, replacing viewing access, or disabling Live Activities ends the local cards. Usage-only links cannot register task Live Activities. ActivityKit payload/access-control tests pass. Real APNs start → needs approval → end was verified with the simulator app backgrounded on September 30, 2026. The same background start → approval → end lifecycle also passed on the physical iPhone 17 Pro after accepting the separate Always Allow prompt. Tapping the native card also opened the correct read-only task and Mac; see the development review for test details and remaining limits. `CompanionLiveActivityUITests` is an opt-in real-APNs check (`COMPANION_LIVE_ACTIVITY_TEST=1`); physical runs additionally require `COMPANION_LIVE_ACTIVITY_PHYSICAL_TEST=1`. It uses a disposable feed and a separate test Keychain service, then restores the normal app on the phone.

The Hono relay in `Companion/Relay` uses one hibernating Cloudflare Durable Object per Mac feed and one small inbox per push device. WebSocket snapshots go directly to foreground viewers, without waking push receivers. A full snapshot is checkpointed at most once every five minutes; opening a viewer also requests a fresh frame from the Mac. Widgets fetch the latest available snapshot when iOS grants a timeline refresh. A connected Mac gets up to 1.5 seconds to replace a stale checkpoint for that read; offline reads return dated data immediately.

The relay tells an adaptive Mac publisher when viewers, paired devices, or enabled push subscribers appear or disappear. With no consumers, routine publishing stops; opening a viewer or requesting a widget snapshot immediately requests fresh telemetry. Foreground snapshots publish important state/phase changes immediately and coalesce changing numbers to five seconds. With no foreground viewer, a paired Mac sends only a five-minute snapshot checkpoint. Hibernation-safe heartbeat replies do not invoke the snapshot handler. Feed reads are cached for the object's lifetime, and device last-seen writes are coalesced to five minutes.

Compact HTTP push batches publish important task transitions promptly, coalesce phase changes to five seconds, and send changing context/token metrics at most once per minute. Unchanged idle state does not poll, and installations without enabled push subscribers send no push batches. An active card gets a freshness publication within two minutes; each acknowledgment can request an earlier one-shot follow-up when a deferred phase or prompt freshness update is due. Numerical traffic does not postpone that deadline. A local bounded journal retains important transitions until the relay accepts them. Receiver databases retain notification baselines, registrations, lifecycle state, and important deliveries; routine measurements are replaceable memory and accepted low-priority metric pushes require no write or receipt RPC. A regular Worker sends APNs after the coordinator returns, so Apple network latency does not hold a Durable Object open. Start/end, important task-state updates and alert deliveries use a durable leased outbox with bounded retries; alarms exist only while that outbox has work. Account alerts still deduplicate across Macs. Notification expiry is one hour; starts expire after three minutes, and stale measurements are never made fresh by retrying. A crash can repeat a latest-value update; APNs acceptance does not guarantee presentation. Neither a sleeping Mac nor an offline relay can provide fresh task state.

Protocol 2 replaces the original relay namespaces and requires the new Mac publisher plus re-pairing phones. Existing phone viewing/push endpoints remain compatible. The October 2026 trial should compare billed duration, rows written, requests, and errors over complete days with the same number of active Macs and phones; see [the relay trial record](Review/Relay-Cost-Trial-2026-10-06.md).

For local development:

```sh
cd Companion/Relay
vp install
vp run dev
# In another terminal, with this relay on port 8789:
vp node --experimental-strip-types tests/fixtures.ts
```

Open the companion project in Xcode and run the `TokenTachMobile` scheme in an iPhone simulator. The `-companionDemo` launch argument shows fixed preview data; `-companionRelayDemo` shows two synthetic Mac feeds from `http://127.0.0.1:8789`. These are DEBUG-only fixtures, not real accounts. The relay test suite uses the same port (override with `RELAY_URL`). Run `vp run typecheck`, `vp run test`, and `swift test --package-path Companion` from the appropriate directories. `Scripts/generate-companion-project.rb` regenerates only the companion Xcode project. For a repeatable isolated core/relay check, run `./Scripts/check-companion.sh` from the repository root. This also runs Foundation WebSocket deadline/cancellation tests against a disposable loopback fixture; it does not open app windows or run UI tests. The [simulator acceptance review](Review/Simulator-Acceptance-2026-09-30.md) records the latest fixes and runtime verification; the [development review](Review/2026-09-30.md) retains earlier evidence and distribution gates.

Normal linking starts in **Mac Settings → Devices → Pair iPhone…**. On the iPhone, open **Settings → Link a Mac** and scan the code, or use **Paste Link** after copying it on the Mac. The app validates the link without exposing its URL in an editor. Paired devices appear in the Mac's Devices settings and can be removed individually. Each Mac has independent random publisher and viewing credentials. Credentials live in Keychain; the app and widget share read credentials through their Keychain access group. The relay also accepts existing usage-only links, which omit task/project names. Simulator linking tests must use ad-hoc signing (`CODE_SIGN_IDENTITY=-`), not `CODE_SIGNING_ALLOWED=NO`, so the Keychain group is available.

The development relay is deployed at `https://codexgauge-relay-dev.north-wolf-labs.workers.dev`; Mac builds use that address for new pairings, with sharing off until connected. The iOS app shares the stable Mac bundle ID, `com.northwolflabs.CodexGauge`; its widget uses `com.northwolflabs.CodexGauge.widgets`. Mac beta builds retain their separate `.beta` identity. The mobile project uses automatic signing and separate app-group and push entitlements. Device push delivery and Home Screen/Lock Screen widget appearance have been checked as described below. The main Mac target is sandboxed; distribution signing and App Review acceptance remain separate publication gates. Use `Scripts/package-mobile.sh` for a local TestFlight archive/export. Upload is a separate step described in [TestFlight preparation](Distribution/TestFlight.md).

APNs uses a server-side `APNS_PRIVATE_KEY` Worker secret. Keep the complete multiline `.p8` contents in Infisical; never put the key in source control or either client app. The Team ID, Key ID, and app bundle ID are ordinary relay configuration. After linking this repository to your Infisical project, deploy with `uv run --script Scripts/deploy-companion-relay.py --secret-env <environment-slug>`. The script fetches only that secret, validates it, gives Wrangler a permission-restricted temporary file, and removes the file afterward. Infisical environment names are independent of Apple's sandbox/production push environments. App builds and tests do not require the key; a future deployment workflow can retrieve it through Infisical OIDC instead of duplicating it in GitHub secrets. Apple provider tokens are reused for 50 minutes before refresh.

The authenticated relay `test-notification` endpoint remains available for integration diagnostics; the current phone Settings screen exposes alert preferences rather than a test button. Test requests distinguish Apple acceptance from confirmed on-device display, are limited to one every 30 seconds per device, and require a current viewing subscription. Invalid device registrations are retired instead of retried; temporary delivery failures use the bounded retry queue. The relay uses Workers' supported manual redirect mode and never follows a redirect with Apple credentials.

Real APNs acceptance, a visible test banner, and an automatic task-completion notification while the app was backgrounded were verified on the Apple-silicon iOS 27 simulator on September 29, 2026. This is separate from physical-device provisioning and delivery verification. The opt-in `CompanionPushUITests` uses a disposable cloud feed and no real task content; enable `COMPANION_LIVE_PUSH_TEST=1` in its test runner environment to run it. Routine UI tests skip that external integration check.

The small Home Screen widget was installed through the simulator's widget gallery and visually verified with synthetic usage data. Enable `COMPANION_WIDGET_TEST=1` to run that opt-in UI check on a dedicated simulator; it changes the Home Screen layout. When a known reset time passes before fresh data arrives, the widget keeps the last confirmed percentage and shows “Reset awaiting confirmation.”

On September 29, 2026, the development app was installed on an iPhone 17 Pro running iOS 27. Cloud WebSocket updates and the read-only overview/task screens passed device checks. APNs accepted the test push, and the user confirmed receiving two test notifications on the paired Apple Watch. The automated iPhone-banner assertions did not pass; that is not a notification-delivery failure. The precise phone/Watch routing during the test was not established. An active Focus icon alone is not evidence that notifications were silenced, and the user's Personal Focus allows alerts. Apple's [notification forwarding documentation](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding) explains that an iPhone push can appear on the phone or Watch. Keep user-confirmed Watch receipt separate from automated iPhone-banner verification.

The physical phone was also linked to the running Mac beta using its viewing link. Live usage and task data appeared, the link survived termination and relaunch, and the small Home Screen widget displayed the Mac’s actual usage. The opt-in `COMPANION_PAIRED_DEVICE_TEST=1` check preserves that link and reuses an existing visible widget; adding one requires an empty area on the current Home Screen. Phone alert types are selected independently under Settings → Alerts.

Circular, rectangular, and inline Lock Screen widgets were placed in the physical iPhone’s wallpaper editor and visually checked against real linked-Mac usage on September 29, 2026. The rectangular reset countdown now fits a nearly week-long interval without truncation. Edits were canceled to preserve the existing wallpaper and widget arrangement. `COMPANION_LOCK_WIDGET_TEST=1` enables the placement/screenshot check, with `COMPANION_LOCK_WIDGET_STYLE` set to `circular`, `rectangular`, or `inline`. This opt-in check is specific to the recorded iPhone 17 Pro/iOS 27 wallpaper arrangement (Calendar, Weather, Fitness below the large clock); do not run it against an arbitrary personal layout. Screenshot attachments require visual inspection. A real task-completion banner was also observed on the physical phone during this verification, independently of the earlier test-push assertions.

For initial device setup, pair/trust the Mac, enable Developer Mode, and register the phone through Xcode's Signing & Capabilities if its profiles do not yet include it. A misleading command-line “No Accounts” error can accompany missing provisioning even when Xcode is signed in.

### Icon artwork

`TokenTach/AppIcon.icon` is the source for the current app icon. macOS renders its Default (blue) or Dark (black) appearance; the `.icns` resource is a static Default fallback. `TokenTach/Branding` contains the matching 1024px PNG exports for this README and other branding. The legacy asset catalog is generated from this same source.

Regenerate exports with `Scripts/export-branding.sh` using Xcode 27’s Icon Composer tool and ImageMagick. The export pins design generation 27 and losslessly compresses the branding PNGs below 2 MB, retaining transparency. Normal source builds use the checked-in PNGs and do not need either export tool. Review both appearances when changing the source icon.

### Companion review checks

Task-alert taps open the linked task’s current read-only detail. Allowance-alert taps return to Overview. An unavailable task is labeled as such instead of retaining an old navigation value. Invalid viewing links open the linking form with an error so they can be corrected.

The isolated check script also validates Swift-produced Unicode JSON against the relay schema, concurrent phone subscriptions, burst update ordering, feed deletion/recreation, and APNs payload size. A [headless relay latency probe](Performance/README.md#companion-relay-latency) measures transport without opening apps or sending push notifications. Installed development builds, runtime evidence, and remaining acceptance checks are listed in [the development review](Review/2026-09-30.md).
