# User-assigned device-name entitlement request

Status on October 8, 2026: **prepared; not submitted**. Apple's request page requires account sign-in. The existing app still receives the generic name unless Apple has granted this entitlement and the installed profile contains it.

- Product: TokenTach (formerly CodexGauge), iPhone and iPad companion
- Developer: North Wolf Labs LLC
- Team ID: `ALPX923Y54`
- iOS bundle ID: `com.northwolflabs.CodexGauge`
- Entitlement: `com.apple.developer.device-information.user-assigned-device-name`
- [Apple request form](https://developer.apple.com/contact/request/user-assigned-device-name/)
- [Apple's criteria](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.device-information.user-assigned-device-name)

## Request text

TokenTach is a Mac Codex usage monitor with a native iPhone/iPad companion. Its core mobile feature is pairing a user's phone or tablet with their own Macs to view usage and task status. A user may pair multiple iPhones and iPads with the same Mac.

We request access to the user-assigned iOS device name so users can recognize their own paired devices. The mobile app shows the current device name in the Link a Mac screen. At pairing time it sends that name to our Cloudflare-hosted relay, and the Mac app displays it in Settings → Devices → Paired Devices beside connection status and a Remove action. Distinct names let users identify which of their own phones/tablets is connected and revoke the intended device's viewing access. The feature is available to all users of the mobile app without a paid tier.

We read `UIDevice.current.name` only for this visible pairing workflow. It is a display label, not an identifier. A separate random UUID and random viewing credential identify/authenticate each pairing. The name is bounded to 80 UTF-16 units. We do not use it for tracking, fingerprinting, analytics or advertising. We do not include it in push-notification payloads or share it with advertising networks, analytics vendors or third-party SDKs. Cloudflare hosts the relay solely for storage and syncing between the user's paired devices.

The Mac displays paired device names and permits removing a device. Unpairing deletes its paired-device record from that Mac's relay feed. The mobile app remains usable with a generic device name if the entitlement is unavailable.

## UI evidence

The native Mac Devices UI test passed and captures the paired-device list and pairing sheet using synthetic fixture data. The native mobile UI test passed and captures Link a Mac, including the current device name and explanation of its use. Evidence is exported under `.build/device-name-evidence/` and is deliberately excluded from Git. Descriptive copies are `mac/Mac-paired-devices.png`, `mac/Mac-pairing-sheet.png`, and `phone/Link-a-Mac-device-name.png`.

These are screenshots of the running native UI, not design mockups. Fixture screenshots demonstrate the user-visible feature; they are not proof of Apple approval or a physical-device entitlement check. Review the attachments before submission and retain any additional screenshots Apple requests.

Run the focused checks again if the pairing UI changes:

```sh
xcodebuild test -project TokenTach.xcodeproj -scheme TokenTach \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenTachUITests/TokenTachUITests/testDevicesSettingsAndWrappedPairingSheet

xcodebuild test -project Companion/TokenTachMobile.xcodeproj -scheme TokenTachMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CompanionUITests/CompanionUITests/testPairingShowsDeviceNameAndAccessExplanation
```

After approval, enable the prepared entitlement variants using the commands in [TestFlight.md](TestFlight.md), refresh provisioning, and verify on a physical iPhone/iPad that its Settings → General → About → Name matches the mobile pairing screen and Mac paired-device row.
