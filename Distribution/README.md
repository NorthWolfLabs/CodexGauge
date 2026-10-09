# Mac App Store packaging

The main `TokenTach` target now uses App Sandbox in Debug and Release. Beta packaging uses that same target. The dashboard, menu bar, allowances, tasks, activity, notifications and Devices settings share the current source; there is no separate Store UI. `TokenTachStorePreview` remains an isolated diagnostic identity.

The signed app permits outbound network connections, user-selected read/write files and app-scoped bookmarks. It contains no external updater or update-feed keys. Choose the Codex data folder and the OpenAI-signed installed helper once in General settings. The existing bookmark implementation retains those grants across launches; a path preference alone does not grant access. The helper needs write access to its own SQLite state. No full-disk or sandbox-exception entitlement is used in Release.

## Local archive and export

```sh
STORE_OUTPUT_ROOT="$PWD/.build/app-store/candidate" Scripts/package-store.sh archive
STORE_OUTPUT_ROOT="$PWD/.build/app-store/candidate" Scripts/package-store.sh export
```

Archive builds Universal 2 from the current source using the main scheme. The signed-package checker verifies effective entitlements, architecture, the bundled privacy and migration manifests, and absence of Sparkle. The local archive is not itself proof of App Store distribution signing.

Export uses `app-store-connect`, `destination=export` and the existing team/bundle ID. It does not upload, submit for review or change the build number. Xcode needs the team's App Store distribution signing assets and provisioning profile. Export allows Xcode to refresh/create the existing team’s signing assets and provisioning profile as needed. It still performs only a local export. The separate `release.sh`/GitHub workflow still creates a sandboxed Developer ID package for direct distribution; that DMG is not an App Store submission.

## Existing app state

The build generates Apple's `container-migration.plist` for the product identity. Stable builds retain `CodexGauge` support files; beta builds retain `CodexGauge Beta` support files. These legacy folder names intentionally survive the product rename. Preferences use `${BundleId}`. macOS performs this migration when it first creates the container. The identity is preserved, and the existing Keychain service is unchanged. The manifest excludes the user's Codex folder and authentication files.

Existing containers are not deleted to rerun migration. Migration, saved grants and Keychain continuity need verification on an actual upgrade as well as a clean installation. A valid Keychain item may still be unavailable if its older signing access rules differ; a distribution-signing check is separate from a local development upgrade.

## Publication gates

`PrivacyInfo.xcprivacy` declares own preferences, selected-folder/container metadata and UI performance timing. Collection declarations cover the optional relay's linked email, pseudonymous identifiers, task/project content and usage data for app functionality, with no tracking. Reconcile these with App Store Connect's final privacy answers and the production relay's actual logging/retention. A public privacy-policy URL, listing assets, export-compliance answers and supported OS/helper runtime coverage remain publication work.

App Sandbox compatibility and a valid package do not establish App Review acceptance of the installed-helper dependency. No Apple upload or submission is part of this conversion.

Sources: [Apple sandbox migration](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container), [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [App Store review guidelines](https://developer.apple.com/app-store/review/guidelines/).
