# Privacy preparation for distribution

This draft records the implementation as reviewed September 30, 2026. Nothing has been submitted to Apple. The final App Store disclosures and privacy manifests must match the distribution binaries and the relay configuration actually offered to users.

## Data disclosures to prepare

The companion relay retains data beyond handling a single request. Optional opt-in publishing does not, by itself, qualify for omitting disclosures. The hashed account identity and device subscriptions support association across observations, so describe the service as pseudonymous rather than anonymous. Apple's [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) explains collection, linkage, and optional-disclosure criteria.

| Current data | Proposed classification to review | Purpose |
| --- | --- | --- |
| Account fingerprint, installation identifier, APNs device and ActivityKit tokens | User ID / Device ID, linked | Combine account allowances, identify linked Macs, deliver alerts |
| Paired phone/tablet names | Other Data Types, linked; review Personal Information if the user includes their name | Identify and remove the user’s paired devices |
| Task titles and project names | Other User Content, linked | Display tasks and identify alerts |
| Task states, token usage, allowance/reset observations, credit balances and plan | Product Interaction / Other Data Types, linked; verify the precise categories against the final form | Display usage and task activity |
| IP address and ordinary network request metadata | Review actual Cloudflare retention/logging before choosing the final category | Service operation and rate limiting |

All proposed collection is for App Functionality. No advertising, third-party analytics, or cross-company tracking is implemented. A full viewing link can expose personal information in task/project names; the usage-only link removes task summaries. Do not claim “data not collected” for a build with the hosted companion enabled. These classifications are a preparation draft, not submitted answers.

## Required-reason API inventory

[Apple's required-reason API reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) supplies the reason codes below. They must describe actual use, not merely silence a scanner.

| Target / use | Category and candidate reason | Source evidence |
| --- | --- | --- |
| iPhone alert and Live Activity preferences | UserDefaults — `CA92.1` | `CompanionPush.swift`, `CompanionLiveActivities.swift`, own app preferences |
| Mac preferences, saved access and notification choices | UserDefaults — `CA92.1` | `SettingsStore.swift`, `ScopedCodexAccess.swift`, `NotificationScheduler.swift` |
| Sandboxed Mac's selected Codex folder metadata | FileTimestamp — `3B52.1` | Selected-folder grants; `LocalSessionMonitor.swift`, `AnchoredFileAccess.swift`, `BoundedFileReader.swift` |
| Mac's own container file metadata, where used | FileTimestamp — `C617.1` | Confirm paths in final target; this reason does not cover arbitrary external folders |
| Mac presentation timing | SystemBootTime — `35F9.1` | `PerformanceSignposts.swift` measures elapsed in-app time; boot timestamps are not uploaded |

Widget snapshots use a file in the App Group and Keychain read credentials, not shared UserDefaults. Do not add the App Group UserDefaults reason just because an App Group entitlement exists. The direct-download Mac's default external-folder access is a different case from the sandbox's explicit folder picker; assess the actual distribution target separately.

## Before publication

Bundle validated `PrivacyInfo.xcprivacy` files per target, including accurate collection declarations. Generate Xcode's aggregate privacy report and inspect SDK/framework manifests as well as first-party sources. Confirm the production APNs environment against the **signed** application's entitlement; do not rely only on the build configuration name. Keep the `.p8` key in Infisical/Worker secrets, outside client builds.

Provide a stable public privacy-policy URL based on `PRIVACY.md`, verify relay logging/retention, and retain the in-app viewing-link replacement and relay-data deletion paths. [App Store Connect requires a privacy-policy URL](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy). Screenshots, minimum-OS/Intel runtime checks, and the Mac helper's App Review compatibility remain separate release gates. No claims of Apple approval are made.
