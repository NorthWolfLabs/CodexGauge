# Pre-commit cleanup — October 8, 2026

## Scope

Reviewed the accumulated Mac/iPhone account, task, pairing, chart and Live Activity refinements, publisher-driven relay delivery, and sandbox packaging changes before committing.

Removed the unreachable Sparkle updater, its settings/menu actions, dependency lockfile, attribution and rehearsal tools; handlers for the retired advanced pairing controls; unused mobile test-notification UI state; the unused relative-age formatter; and helpers/tests belonging to the retired Live Activity alarm design. Kept active compatibility endpoints, durable retry alarms, deployment migrations, scoped-access implementations and opt-in native verification harnesses.

## Tracking

Source, test fixtures, generated relay interface types, packaging configuration/scripts, and textual review summaries belong in Git. Build products, Python caches, logs, screenshots, checkpoint archives and account-specific analytics remain local and ignored. The new `Scripts/check-tracked-files.py` checks indexed blobs, including object modes, file sizes, local artifact paths and likely private credentials. CI installs uv explicitly before running it. Disposable fixture checks accepted source, rejected a staged synthetic credential and nested capture, and confirmed that unstaged edits do not change the index under review.

## Final verification

Evidence is local under `.build/precommit-2026-10-08/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Shared companion core | 48 passed | `core-final.log` |
| Relay types, integration/runtime tests and dry bundle | 59 passed; zero failed/skipped | `companion-check.log` |
| Mac unit suite and native account/pairing/notification UI | 121 unit tests plus 3 UI tests passed; zero failed/skipped | `Mac-Final.xcresult` |
| Mobile credits/long-range lines, single-point dark chart, alerts/disclosures, Overview glyph reuse, navigation/pairing/task summary | 5 passed; zero failed/skipped | `Mobile-Final.xcresult` |
| Universal Mac Release build and signed sandbox package | Passed; updater and test components absent | `mac-release.log`; `Scripts/check-mac-package.py` |
| Isolated Store Preview Debug build | Passed | `store-preview-build.log` |
| Simulator and physical iPhone 12 test builds | Passed | `mobile-build.log`; `phone-build.log` |
| Repository/index hygiene and staged whitespace checks | Passed | `repository-final.log`; `git diff --cached --check` |

Fresh captures were visually inspected for Mac light Overview/dark Limits, wrapped QR instructions/actions, mobile 1-year lines, clean alert settings, hidden-URL pairing and the Overview working indicator. Captures remain local. The initial cleanup build found one remaining updater menu call; it was removed before the successful final Mac run. The index-fixture harness initially needed forced removal of its own newly staged disposable file; its corrected full run passed.

## Verification limits

This pass used macOS 27.0.1/Xcode 27 and the dedicated iOS 27 simulator. The physical iPhone 12 was a build destination; its most recent actual installed-account/background-card check is recorded in the credits review. No physical iPhone 17 was used. No app installation, relay deployment, Store export/upload or publication was performed during cleanup. Existing App Review, minimum-OS/Intel runtime, general performance and representative cost-measurement limits remain as documented in the earlier reports.
