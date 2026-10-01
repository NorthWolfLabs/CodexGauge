# Account and layout refinement — September 30, 2026

The reviewed development update is installed: Mac beta 1.2.0 (10), iPhone 0.1 (2), and the existing development relay. This is not a tagged release, RC or App Store submission. The physical iPhone retained its existing link and shows the real verified account, separate balances and live task rows. The final read-only installed-beta Mac capture passed against the real popover, Limits and Activity views. The native fixture also passed at a measured 780×640.

## Result

- Mac popover and Limits use a separate Account balances block for banked resets and credits. Credit values no longer appear inside weekly allowance. The accessible read-only cells expose title plus exact displayed value.
- Mobile shows verified account email, account type/plan and source Macs even for one account. It hides only the selector when there is one account. Repeated emails and unavailable identities have distinguishable menu labels.
- Overview and Activity filter by account. All accounts sums independent verified accounts after merging duplicate observations from Macs; it excludes unknown identities with a disclosure. Tasks remain grouped by Mac.
- Native mobile task rows use the popover information hierarchy: title/rate, project/model, then phase/context/elapsed. They retain mobile List surfaces, adapt to accessibility text sizes and do not expose remote commands.
- Both platforms offer Today, 7 days, 30 days, 90 days, 1 year and All. Calendar dates use the current timezone. Missing days remain missing, explicit zero remains zero, and future/invalid dates are excluded. Large mobile chart axes use two edge-aligned date labels, compact numeric labels and a wrapping summary. Today has one date tick.
- Account history is bound to verified account identity in persisted caches and in-flight responses. Same-account observations preserve available older days. Actual history timestamps determine precedence; a fresh quota-only response cannot refresh older history or erase metrics/truncation disclosure. Partial history does not support invented full-period comparisons.
- Stale task elapsed freezes at a coherent last observation; invalid/missing timing shows unavailable. Completed detail uses observed completed-turn duration.
- The relay accepts optional bounded email/type/history fields and up to 2000 daily observations. Usage-only links still omit tasks but disclose account email, as documented in Settings and PRIVACY.md.

## Source and build identity

Independent source review approved candidate 8, 138 files, identity:

`3e2f2ffad4d498f13ebe051ffcb27dc9be01048c258ee2ad7ee44d390e0110d5`

Exact bytes and hashes are in `Account-Refinement-2026-09-30/candidate-review-8.tar.gz` and `.json`. The canonical identity hashes sorted file entries serialized with sorted JSON keys and comma/colon separators. Candidate1–7 and the prior baseline manifest are retained.

After that review, only `CodexGaugeUITests/CodexGaugeUITests.swift` gained a read-only installed-beta capture test. Its separate recoverable checkpoint is `capture-harness-9.tar.gz/json`, identity:

`30cb923189090934abcb0898c32c76cf08de764663f46ccb28d6736fcc3b394c`

No application/relay runtime changed for this capture. The Mac was built from candidate3; all later changes were mobile chart UI, mobile version plist expansion, and test harnesses. The iPhone was built from candidate8 with 0.1/build 2. `prepared-artifacts.json` and `installed-evidence.json` record binary hashes, versions, build logs and that linkage. The Mac installed executable and Debug implementation hashes match the prepared artifacts:

- Main executable: `880507a965296160d729489f761f06b00da5ac5291bd21fa84a579842137ea2c`
- Debug implementation: `96acf9b4bf2fcf37f2aff8305b822fd786e3f810fc3190dce8a1504c576ca19d`

The mobile app and widget both expand the existing version build settings; the earlier fixed plist values had ignored the requested build 2. Signature verification passed for both installed candidates. The physical device app inventory reports 0.1/build 2.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Shared Swift core |29 tests pass |`.build/account-core5.log` |
| Relay integration/wire/APNs construction |37 tests pass, typecheck/dry-run pass |same log; no real push secret loaded locally |
| Mac unit suite |110 passed executions, 1 skip, 0 failures |`mac-tests3-summary.json`; trust-host test skips under unsigned unit host |
| Actual native Mac fixture |1 test passes, measured 780×640, exact credit label12.50, all 6 controls hittable |`mac-ui6-summary.json`, screenshots/frame attachment |
| Final mobile light acceptance |6 tests pass |`ui8-summary.json`,22 actual simulator screenshots |
| Final mobile dark acceptance |2 tests pass |`ui9-summary.json`,8 actual simulator screenshots |
| Local expanded wire check |500 days/new fields exact, usage-only task redaction,4 ms live delivery |`.build/account-wire-local.log`, disposable feed removed |
| Development relay wire check |same roundtrip,58 ms live delivery |`.build/account-wire-remote.log`, disposable feed removed |
| Physical iPhone |installed 0.1 (2), launch succeeds, existing link and real verified identity/balances/live task hierarchy visible |`physical-overview-build2.png`, device app inventory/launch logs |
| Installed Mac |signed 1.2.0 (10), executable hashes match, background relaunch succeeds; real popover/Limits/Activity capture passes 1 test, 0 failures |`installed-evidence.json`, `installed-mac-ui7-summary.json` and actual screenshots |

The UI cases verify one/two accounts and two Macs, exact Today 188,947 vs combined 188,957, genuine local-feed 400→200 after revoking the second account, single-account selector removal with identity retained, all 6 ranges, selected-day chart totals, invalid-link correction, empty Overview/Tasks, first live observation without refresh, missing identity, stale Today with no manufactured data, and elapsed 0:05:18 remaining unchanged after 2 seconds. Large chart pixels were reviewed in light/dark. No approval/command controls were added.

Screenshots are indexed in `ui8-screenshots.json`, `ui9-screenshots.json` , `mac-ui6-screenshots.json` and `installed-mac-ui7-screenshots.json`. Simulator/native fixture images are explicitly synthetic. The physical overview and three installed-beta Mac screenshots contain real owner data and remain local with mode 0600; they are not public marketing images. The read-only Mac test ran from 19:59:30.093 to 19:59:38.863 Eastern (8.768 seconds); it closed the dashboard and released foreground while leaving the beta running. Xcode startup delayed activation beyond the intended slot deadline; no further foreground actions followed.

Failed intermediate runs remain recorded. UI5/6's large picker failed because the synthesized event was near(45,58), while its visible selected value was near(114,716). The final test scrolls it fully into the visible viewport, asserts bounds and taps the measured point. This is not evidence that the product picker failed to respond to a correct tap. UI6's own post-failure diagnostic subprocess was stopped after waiting approximately 90 seconds so Xcode could finish its result bundle; no simulator/system services were restarted. Earlier corner-resize screenshots were 920×682 and are not claimed as narrow verification. UI6's explicit native-frame fixture establishes 780×640 instead.

## Development deployment and recovery

- Existing endpoint: `https://codexgauge-relay-dev.north-wolf-labs.workers.dev`.
- New version: `91107397-59d0-47fb-8c15-dbd84be49596`.
- Prior version: `7c849ffe-75e3-4765-8b3f-88d4a6d2a93e`. Configuration/bindings remain unchanged; existing APNs secret was retained, not printed or replaced. No migration was added in this pass.
- Prior Mac build 9 is preserved at `.build/dev-beta-account-refinement/installed-before-update.app` and `retired-installed-build9.app`; the earlier first-pass backup also remains. These are recoverable application bytes. User caches/preferences/Keychain links were not reset for installation.
- The baseline manifest records hashes but has no exact pre-pass source archive. The mixed HEAD patch includes earlier dirty work and must not be treated as a clean rollback patch. Current candidate archives preserve exact candidate source, not a reconstructed baseline.
- No unrelated commits/reset, release tag, RC, production endpoint or store submission occurred.
- Owned local relay on 8798 and core fixture on 8794 are stopped. Disposable remote/local feeds were deleted. The dedicated simulator is left on a clearly labeled dark preview; its status override is cleared. Other app/device services were not reset.

Recovery order, if needed; no rollback was performed:

1. Preserve the currently installed build10 bundle at a new path, then quit only CodexGauge Beta. Restore the exact preserved build9 bundle to `/Applications/CodexGauge Beta.app`, verify its deep/strict signature and1.2.0/build9 identity, and relaunch it in the background. Do not delete preferences, Application Support, Keychain entries or phone links.
2. Confirm that the older publisher connects to the current development relay and publishes a fresh compatible snapshot. The current relay accepts the older fields. Restore the publisher before rolling the relay back so it no longer sends the new optional fields/history length to the older strict protocol.
3. If relay rollback is also necessary, restore only the existing development worker to version `7c849ffe-75e3-4765-8b3f-88d4a6d2a93e` through Wrangler's rollback operation. Preserve the APNs secret and Durable Object data; no migration, feed deletion or credential rotation is needed for this code rollback. Verify health and a disposable old-protocol roundtrip afterward. The current mobile app accepts absent optional fields, although email/history coverage may be unavailable from the older publisher.

## Test isolation note

The initial new account-provider tests mistakenly used the default SnapshotCache and could persist synthetic account state to the normal test-host Application Support file. Those runs were stopped. Read-only inspection afterward found real non-fixture observations in both normal and beta caches with fresh timestamps; exact prior bytes were unavailable and a transient fixture write cannot be ruled out. No real cache was deleted/overwritten during investigation. All new provider/persistence tests now use owned temporary cache paths, including legacy/matching persisted-cache and account-switch cases. Installation preserved existing application data. See checkpoint-notes.md for timestamps and limits.

## Explicitly deferred and remaining release gates

Cloud-only Work tracking is explicitly deferred at the user's request until a useful supported source is established. The installed official CLI returned an empty cloud list for this authorization; that does not prove all cloud discovery impossible. The documented CLI fields are coarse task status metadata, not live token/context/tool/compaction telemetry. Public local app-server account schema supports email/type/plan, not a verified handle. No private desktop APIs, stores or credential extraction were added as product dependencies. Capability findings are recorded separately in cloud-capability.json and checkpoint-notes.md.

This pass does not qualify App Store review, older OS/device behavior, spoken VoiceOver, hardware QR scanning, hardware CarPlay or prolonged background notification delivery. It preserves the previously reviewed Live Activity/widget/push implementation. New delivery protocols were not exercised by sending unnecessary real notifications. These remain release gates rather than claims of this development checkpoint.
