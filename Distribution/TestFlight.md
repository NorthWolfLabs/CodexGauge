# TokenTach TestFlight preparation

Prepared October 8, 2026 with Xcode 27.0 (27A266a), version **1.2.0 (10)** on both platforms.

The repository was copied from CodexGauge with its Git history. The original checkout remains intact. The ignored Infisical project linkage was copied without copying secret files. Projects, targets, Swift modules, app names, widgets, branding resource filenames, documentation and packaging now use TokenTach. The Git remote still points to the existing CodexGauge repository; no remote rename or push was performed.

Bundle IDs intentionally stay `com.northwolflabs.CodexGauge` (Mac and iOS), `com.northwolflabs.CodexGauge.widgets` (extension), and the existing `.beta`/`.store-preview` Mac variants. Team: `ALPX923Y54`. Keychain/app groups, Application Support folders, account hash salt, widget kind and deployed Cloudflare Worker identity are preserved. New links use `tokentach://`; the mobile app also accepts existing `codexgauge://` links.

## Verified local packages

- `.build/testflight/mobile/TokenTachMobile.xcarchive`
- `.build/testflight/mobile/export/TokenTachMobile.ipa`
- `.build/testflight/mac/TokenTach.xcarchive`
- `.build/testflight/mac/export/TokenTach.pkg`

Both archives and App Store Connect distribution exports succeeded. The iOS export was checked for valid signatures, App Store provisioning, production APNs, matching host/extension versions, privacy manifests and preserved app group. The universal Mac archive and exported installer passed the existing sandbox/package/profile checks. These checks establish local package readiness; upload processing and Beta App Review have not been performed.

Validation passed: 121 Mac unit tests (130 parameterized runs), 48 companion core tests, the focused Mac Devices/pairing UI test, the focused iPhone device-name/pairing UI test, and repository checks. The identity compatibility test was rerun after strengthening its rename assertions. Native request screenshots are saved under `.build/device-name-evidence/`.

Device-name access is **not enabled** in these exports. The app works with Apple's generic device name until approval. Entitlement variants are prepared for both Debug and Release; the widget does not request device-name access.

## Rebuild and export

Run from the repository root. Use a fresh output directory and a build number higher than any previously uploaded build for version 1.2.0.

```sh
MOBILE_BUILD=11 MOBILE_OUTPUT_ROOT="$PWD/.build/testflight/mobile-11" Scripts/package-mobile.sh archive
MOBILE_OUTPUT_ROOT="$PWD/.build/testflight/mobile-11" Scripts/package-mobile.sh export

STORE_OUTPUT_ROOT="$PWD/.build/testflight/mac-11" Scripts/package-store.sh archive
STORE_OUTPUT_ROOT="$PWD/.build/testflight/mac-11" Scripts/package-store.sh export
```

The Mac packaging script uses the version/build in `TokenTach.xcodeproj`; update all Mac `CURRENT_PROJECT_VERSION` entries before building a subsequent upload. Mobile app/extension versions are set together by `Scripts/generate-companion-project.rb`; keep that generator and checked-in project consistent. `MOBILE_BUILD` overrides both mobile targets for an individual archive.

After Apple grants device-name access to the existing iOS App ID and the provisioning profile includes it:

```sh
DEVICE_NAME_APPROVED=1 MOBILE_BUILD=12 MOBILE_OUTPUT_ROOT="$PWD/.build/testflight/mobile-device-name-12" Scripts/package-mobile.sh archive
DEVICE_NAME_APPROVED=1 MOBILE_OUTPUT_ROOT="$PWD/.build/testflight/mobile-device-name-12" Scripts/package-mobile.sh export
```

For a direct Xcode build, set `DEVICE_NAME_ENTITLEMENTS_SUFFIX=WithDeviceName` on the mobile app. The export checker verifies that the entitlement is present in both the signed app and its distribution profile when `DEVICE_NAME_APPROVED=1`. Adding a local plist does not grant approval.

## App Store Connect steps

1. Sign in to App Store Connect for North Wolf Labs. Locate the existing app record matching `com.northwolflabs.CodexGauge`; rename its listing to **TokenTach**, checking name availability. If there is no app record, create it with this existing App ID and add the required platforms. Do not register a replacement App ID for a display-name change.
2. Open each archive in Xcode Organizer, select **Distribute App → App Store Connect**, validate, and upload. The prepared IPA can alternatively be delivered with Apple's Transporter. Packaging scripts only export locally.
3. Verify processing succeeds and both platform builds show version 1.2.0 (10). Confirm export compliance against the app's actual cryptography. The apps declare `ITSAppUsesNonExemptEncryption=false` because the clients use Apple's OS networking/security APIs and do not embed custom cryptography.
4. Add a tester feedback email, beta description, review contact and review instructions. A feedback/review contact was not invented in this checkout. Internal testers can be added after processing; external testing requires Apple's Beta App Review.
5. Reconcile App Store privacy answers with `PRIVACY.md` and `Distribution/Privacy-Preparation.md`, including paired device names. Supply a public privacy-policy URL. Hosted companion data is collected for app functionality; it should not be described as “data not collected.”
6. On physical hardware, verify installing over the prior app retains pairings, settings and widgets, then test production APNs alerts and Live Activities from the TestFlight build. The local export check confirms production entitlements; it does not send a production push or verify a TestFlight installation.

The relay URL and Cloudflare service were preserved. No relay deployment, secret migration, TestFlight invitation, App Store Connect metadata edit or Apple upload was performed by this migration.

## Beta metadata draft

**Description:** TokenTach shows Codex allowances and local task activity from your Mac. The iPhone and iPad app displays your linked Macs, account usage, task status, widgets and optional Live Activities.

**What to test:** Link an iPhone or iPad to a Mac; check usage and tasks, account switching, widgets, notifications, Live Activities and reconnecting after the Mac sleeps. Verify existing settings and pairings survive an update from CodexGauge.

**Review instructions:** The Mac app requires an installed, signed-in Codex helper. In Mac Settings, choose the Codex data folder and installed helper using the native file pickers. In Settings → Devices, select Pair iPhone. In the iOS app, open Settings → Link a Mac and scan the QR code or paste the viewing link. The mobile app provides read-only access and cannot run commands or approve tasks. Pairing is optional; an unpaired app displays an empty state. Supply a reviewer-accessible Mac/feed or a review demonstration before external review; do not submit private viewing credentials in public metadata.

## Apple device-name request

See [Device-Name-Request.md](Device-Name-Request.md). The request page currently requires Apple Account sign-in; no entitlement request has been submitted. Apple approval and regenerated provisioning are still required before enabling the prepared entitlement.

Sources: [Apple TestFlight](https://developer.apple.com/testflight/), [preparing an app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [encryption export declarations](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption).
