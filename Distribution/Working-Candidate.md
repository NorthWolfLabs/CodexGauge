# Working release candidate

Updated October 9, 2026: **TokenTach 1.3.0 (14)** is installed and running on the Mac and iPhone 12 Pro Max, preserving their identities and pairing. Candidate bundles are under `.build/candidate/1.3.0-14/`; the prior Mac installation is recoverable in that directory's `previous-installed/` folder.

Task cards now put phase on its own line, preserve the complete numeric elapsed value, allow context text to wrap and stack metadata at accessibility text sizes. The Mac excludes internal security-scan sessions and their agents, including agents discovered without a loaded parent, instead of publishing temporary directories as “output” tasks. Ordinary CLI tasks in an output directory remain eligible.

Verification: all 123 Mac tests passed (134 parameterized runs), including current/old/missing scan-parent cases. Two UI tests passed on the physical iPhone 12 Pro Max running iOS 27.0.1: the stale clock regression and large-text task layout. Retained screenshots also show long Unicode/project/phase text, agent context and a 72-hour clock. Both Release builds and signed-package checks passed. The normal connected Overview was inspected after installation and no longer showed the internal output tasks. Evidence is under `.build/task-layout/`, including `physical.xcresult`, `mac-orphan.log` and `iphone-14-live.png`. This update was not uploaded to TestFlight.

For the next local build, use `CANDIDATE_BUILD=15 Scripts/package-candidate.sh mac` and `CANDIDATE_BUILD=15 Scripts/package-candidate.sh ios`.

## Initial installation record

Installed October 8, 2026: **TokenTach 1.3.0 (11)** on the Mac and George's iPhone 12 Pro Max, using Xcode 27.0 (27A266a).

The Mac runs `/Applications/TokenTach.app`, built from the current working tree with the adaptive publishing architecture. It shows the ordinary product name and gauge. It retains `com.northwolflabs.CodexGauge.beta` and its existing support folder solely to preserve the installed test app's settings, folder/helper grants, Keychain access and pairings. The previous Mac app bundles are recoverable under `.build/candidate/1.3.0-11/previous-installed/`; containers were not moved or deleted.

The iPhone app retains `com.northwolflabs.CodexGauge` and was installed over its existing CodexGauge app without uninstalling. The phone launched normally and displayed live account allowances and active tasks from the Mac. Its screenshot is `.build/candidate/1.3.0-11/iphone-running.png`.

The relay health response confirmed `publishing=adaptive-events-v1` and `architecture=publisher-driven-push`. This installation did not redeploy or change the live relay.

## Local builds

```sh
CANDIDATE_BUILD=12 Scripts/package-candidate.sh mac
CANDIDATE_BUILD=12 Scripts/package-candidate.sh ios
```

Both use Release optimization. The Mac is signed with the existing North Wolf Labs Developer ID. Local iPhone builds use development provisioning and sandbox APNs; `LOCAL_DEVICE_CANDIDATE` aligns the app's push registration with that signed entitlement. The override applies to the app only; the widget retains its own app-group entitlements. TestFlight packaging retains its production environment.

Saved candidate bundles are under `.build/candidate/1.3.0-11/Mac/` and `iPhone/`. Generated compiler caches from this run were cleared after installation because the Mac ran out of space. These candidate builds were not notarized or uploaded to TestFlight. Device-name entitlement approval is still separate.

## Verification

- Mac and iPhone Release builds succeeded, with matching version/build metadata and preserved identities.
- Both built packages passed their signed-package checks. The iPhone app's signed APNs environment is `development`; its widget has no push entitlement.
- Both identity tests passed, including preserving the test app's storage while removing Beta branding.
- After additional storage became available, the complete isolated companion check passed: all 54 shared companion Swift tests, all 62 relay tests, TypeScript checking, and the Wrangler deployment dry run. The successful retry log is `.build/candidate/1.3.0-11/companion-tests-retry.log`.
- Physical installation and foreground launch succeeded on the iPhone 12 Pro Max; its live Overview was visually inspected. Production APNs, a new TestFlight installation and external Beta App Review were not tested by this local install.

The initial relay test run was interrupted by disk exhaustion. After cache cleanup and additional space became available, the successful retry completed with approximately 60 GiB free on the data volume.
