# Current Mac app sandbox conversion — October 6, 2026

## Result

The main CodexGauge target uses App Sandbox in Debug and Release. Beta builds use the same target/source. Installed `/Applications/CodexGauge.app` (1.2.0, build 9), `/Applications/CodexGauge Beta.app` (1.2.0, build 19), and the previously running development copy under `.build/updater-tests` have been replaced with signed sandboxed Release builds. Backups and executable hashes are recorded in `.build/mac-store-conversion/installation.json`.

Current dashboard, menu card, allowances, tasks, activity, notification choices, and Devices UI use the existing current source. The new relay architecture and all preceding UI edits were preserved. Packaging activates the already implemented folder/helper selection and app-scoped bookmarks. External Sparkle updating was removed from the target and packages; Store updates use Apple's distribution system. OpenAI app opening now resolves the installed app with NSWorkspace, including this Mac's `com.openai.codex` identity.

## Signed artifacts

The final local Mac App Store export is `.build/mac-store-conversion/verified-store/export/CodexGauge.pkg`. Its main app is Apple Distribution signed for North Wolf Labs LLC, ALPX923Y54, with the exact CodexGauge application identifier and a valid App Store provisioning profile. The installer is signed with the team's Mac App Store installer certificate. Universal arm64/x86_64 slices, effective sandbox entitlements, privacy manifest, identity-specific container migration manifest, and absence of external updater/tests were verified. SHA-256 is in `store-package-sha256.txt` beside the task artifacts.

Installed local builds are Developer ID signed, with exactly four security entitlements: App Sandbox, outbound networking, user-selected read/write files, and app-scoped bookmarks. They contain no get-task-allow entitlement, sandbox exceptions, test peer, test bundle or Sparkle. The local candidate is not notarized; the Store installer is a separate artifact and was not used for the local installation. No upload or App Review submission occurred. Export allowed Xcode to refresh the existing team's distribution signing/provisioning assets.

## Verification

All results below are in `.build/mac-store-conversion/`. `verified-test-summary.json` records final pass/fail/skip counts.

| Check | Result | Evidence |
| --- | --- | --- |
| Mac unit suite | 122 passed; 0 failed/skipped (128 executions with parameters) | UnitTests-InstallReady.xcresult |
| Actual signed main Release UI | Passed; eight window/panel captures | Main-ReleaseVerifiedUI.xcresult; main-release-screenshots/ |
| Actual signed Beta Release UI | Passed; eight window/panel captures | Beta-ReleaseVerifiedUI.xcresult; beta-release-screenshots/ |
| Real account/tasks after relaunch, main sandbox | Fresh allowances, tasks loaded, no connection error | Main-RealAccountConfirmedUI.xcresult |
| Real account/tasks after relaunch, Beta sandbox | Fresh allowances, tasks loaded, no connection error | Beta-RealAccountConfirmedUI.xcresult |
| Installed main Release, normal launch | Connected with restored grants; external updater absent | Main-InstalledUI.xcresult |
| Installed Beta Release, normal launch | Connected with restored grants; external updater absent | Beta-InstalledUI.xcresult |
| Repository and signed-package checks | Passed | repository-final.log; package checkers |

Captured layouts were visually reviewed. Earlier source UI checks also covered light/dark account/activity screens, native dashboard chrome, notification choices, menu bar settings, and the wrapped QR/device fixture. Current cloud-backed pairing/revocation is outside this quota-limited verification.

The development account/readiness checks run inside a Developer ID signed app with the same four effective sandbox entitlements and no test exceptions. Publishing is suspended only while its opt-in `-verifySandboxMigration` flag is present. These diagnostics are excluded from Release. Xcode's ordinary hosted unit-test app has test entitlements; those tests alone are not evidence of the shipping sandbox. The native synthetic RPC peer exists only in unit-test products, is not shipped, and does not establish the installed helper's sandbox behavior. The real installed bundled OpenAI helper was checked separately.

## Existing state and access

The Beta's first sandbox container preserved all nine baseline preferences before selecting the Codex folder. The explicit folder selection intentionally replaced its empty path preference with the same effective `.codex` folder. Both native folder/helper grants survived relaunch.

The main identity already had an older experimental sandbox container. macOS did not rerun first-container migration: its development check initially preserved 0/2 legacy support files. Through the native picker, selecting only this app's original support folder preserved 2/2 exact frozen baseline hashes. Existing destination files were backed up inside the app's temporary directory. Neither container was deleted; terminal TCC protection was not bypassed. Preference baselines and support hashes remain private local scratch artifacts; authentication files were not copied.

Both products now use the current OpenAI-signed helper bundled in ChatGPT.app. Selecting the older standalone 0.146.0 helper produced an unavailable message; that older-helper configuration is not claimed as verified. The reusable scoped migration pattern and its limits were recorded in macOS-Recipes under `sandbox-container-upgrade`.

## Remaining limits

The Mac runtime checks used Apple silicon, macOS 27.0.1 (26A434), and Xcode 27. Intel was compiled but not run. Minimum supported OS, full sleep/wake behavior, notification delivery, arbitrary older helpers, and distribution-signing Keychain access rules require their own coverage.

The Cloudflare quota is exhausted until the expected October 6, 8 p.m. Eastern reset. Relay protocol-v2 behavior, live push delivery and the new cost estimates were not revalidated here. No relay deployment or iPhone installation was performed by this packaging task.

Store signing and sandbox compatibility do not establish App Review acceptance of the installed-helper dependency. Public privacy-policy URL, listing assets, final App Store privacy/export answers and OS/helper coverage remain publication work. See Distribution/README.md for reproducible archive/export commands and publication gates.
