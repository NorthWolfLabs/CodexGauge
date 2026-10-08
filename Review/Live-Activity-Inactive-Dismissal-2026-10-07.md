# Live Activity removal when no tasks remain

## Subsequent recovery regression

The removal check below did not prove restoration of the normal account's card.
The user subsequently reported missing Live Activities, and a normal saved-account
check confirmed the failure. See [the recovery report](Live-Activity-Recovery-2026-10-07.md)
for the production foreground recovery fix, scoped fixture cleanup, native evidence
and retained failed checks. The isolated forced-start seam described below has
since been removed.

## Change

The former local completion policy kept the card for 60 seconds, and the relay's ordinary end payload requested the same retention. During that interval, the idle content rendered “No active tasks”.

Local updates now end with no replacement content and `.immediate`. The relay sends every end event with a dismissal date before its delivery timestamp. Running tasks and tasks awaiting input or approval remain eligible for monitoring.

This uses Apple's [documented immediate dismissal policy for remote end events](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications). The card is removed when the end event reaches the phone; network and APNs scheduling still determine when that happens.

## Verification

- Companion core: 46 passed.
- Relay suite: 56 passed on the completed rerun, including no-task start rejection and immediate dismissal payload assertions. Type checking and dry bundle passed.
- The first full relay run had 55 passes and one HTTP 500 in the existing device-selection authorization test. The same check returned its expected response on the full rerun. Both logs remain local; this does not establish the cause of that intermittent response.
- Phone build passed after correcting a new test screenshot helper reference.
- The initial physical iPhone 12 run did not find its new card, before any dismissal assertions. The retained result records that failure. Its final screenshot shows Spotlight, so it does not establish whether remote start failed. The test now targets the observed `SBCoverSheetWindow` bounds for native gestures instead of SpringBoard's aggregate bounds.
- A separately opted-in debug harness creates the initial activity through the existing foreground ActivityKit path and omits push-to-start registration only for that isolated harness. This allows background APNs update/end delivery and foreground removal to be checked independently of remote start. Normal and Release startup behavior is unchanged.
- Final physical iPhone 12 check: 1 passed, 0 failed/skipped (`Phone-Dismissal-Bounded-Surface.xcresult`). It verified background context/rate/phase changes, metrics-only delivery, task selection, approval, read-only task opening, background completion removal within the 15-second delivery window, a later activity restarting, and foreground empty-list removal. The whole-card selector was present before both removals; checking disappearance of a title alone cannot pass this test.
- Before/after Lock Screen captures were visually reviewed. After completion and empty-list delivery, the native card is gone; ordinary completion notifications remain. This run bootstrapped the activity locally and does not claim a new remote-start pass.
- The second run failed before checking removal because the Lock Screen window did not yet exist on the Home Screen. The final harness chooses the observed Home Screen or Lock Screen bounds as appropriate. All three native results are retained; only the final run is claimed as passing evidence.

Artifacts: `.build/live-empty-dismissal-2026-10-07/`.

## Delivery

The protocol-2 publisher-driven relay was deployed as version `7afd2ec2-d96b-4129-98aa-08100cf03c9d`. Health still reports `publisher-driven-push`; no namespace migration or polling change was introduced. The Mac apps require no packaging change for this fix.

The updated development app is installed on the physical iPhone 12. Its strict signature check passed. The native teardown restored alert preferences, removed its disposable feed, and relaunched the app normally with the owner's existing connection. Native runtime coverage is iOS 27 on iPhone 12 with Xcode 27. Older supported systems and every network delay pattern were not established by this check. No physical iPhone 17 was used.
