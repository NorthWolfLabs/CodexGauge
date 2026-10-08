# Missing Live Activity regression — October 7, 2026

## Confirmed failure

The normal saved connection on the physical iPhone 12 had two active tasks,
Follow active tasks enabled, successful notification registration, and a valid
push-to-start token. Its native ActivityKit registry nevertheless contained zero
activities. `Normal-Before.xcresult` failed the actual Lock Screen card assertion.

The previous removal check used an isolated foreground-start harness and did
not establish that the normal account's card returned afterward. Its cleanup
could end unrelated cards when configuring only the fixture's links. Restoring
preferences and relaunching was insufficient evidence of readiness.

## Fix

- Normal foreground snapshots can now recover a missing card using ActivityKit's
  supported foreground request API. This is production code, with no forced
  start argument. Remote APNs starts and updates remain available in background.
- The existing authenticated registration route reserves a short local-start
  window. It checks full viewing access, registration revision, enabled settings,
  fresh active tasks, current native activity IDs and the server's dismissal
  record. Explicit swipe dismissals remain authoritative.
- A young missing token requires two consecutive foreground absence reports at
  least one second apart. A new token registration clears that confirmation.
  This recovers after updates without waiting the ordinary 30-second registry
  grace, while protecting racing activity registrations.
- Recovery attempts are bounded per foreground session. Foreground transitions,
  disabled settings and removed links cancel pending work. Current content and
  eligibility are checked again after awaiting server permission.
- Technical APNs failures now stop automatic delivery retries independently of
  a person's dismissal. Registering a recovered activity clears that block.
- Fixture activity observation and cleanup are scoped to their own feed. The
  debug-only forced-start path was removed. The fixture exercises the production
  foreground recovery path and background APNs updates/end delivery.
- Relay uploads are buffered through the existing size limit before being
  forwarded to the Durable Object. An early scope rejection previously raced
  the streaming request and intermittently returned HTTP 500 instead of 403.

No per-second background polling or namespace migration was added. The new
publisher-driven architecture remains in place. Two hundred metric observations
still perform zero durable writes and create no polling alarms in the local test.

## Verification

- Core: 46 passed.
- Final full relay suite: 62 passed, zero failures/skips. Type check and dry bundle
  passed. Coverage includes young-orphan confirmation, token races, reservations,
  explicit dismissals, inactive/stale evidence, disabled preferences, scope,
  revocation, technical delivery rejection and lifecycle updates/end delivery.
- Signed iPhone build and strict signature verification passed.
- `Normal-Schema.xcresult`: normal saved-account check passed, including a
  35-second background interval. Diagnostics showed permission granted, a new
  native card, update token registered HTTP 200 and one active registry entry.
  Visually inspected captures show the real task's tokens/min changing from
  541.8K to 363.7K while backgrounded. The timer was not the only changing value.
- `Scoped-Lifecycle.xcresult`: passed context/rate/phase changes, metrics-only
  delivery, two task selections, approval, task opening, completion removal,
  later restart and empty-list removal. Native removal captures were inspected.
- `Combined-Final.xcresult`: 2 passed, zero failures/skips, in one installation.
  The final fixture lifecycle passed first, then the saved normal account check
  passed. Its real card survived app relaunch and the 35-second background check.
  Final screenshots were visually inspected: the real task phase changed from
  Thinking to Using a tool, with project/device/account/context/rate and selector
  visible. Fixture completion/empty-state captures contain no fixture card.
  The normal account remains linked, Follow active tasks is on, original alert
  preferences were restored, and the phone app is open for review.

Artifacts: `.build/live-recovery-2026-10-07/`.

### Failed checks retained

The first full relay run had 60 passes and one HTTP 500 on a usage-scope rejection.
The local server log showed a read from an already-completed request stream. The
buffered forwarding fix passed subsequent full runs and their authorization checks.

`Normal-After`, `Normal-Host` and `Normal-Reconnect` failed: regular registration
returned HTTP 200, but the new recovery field received HTTP 400. Fresh cloud feeds
accepted the same field. A later deployment and normal retry succeeded on the
existing feed. The precise cause of this deployment interval's mismatch was not
established; a Mac publisher reconnect alone did not fix it.

`Normal-Final` exposed a separate recent-token grace case: the registry was empty,
and permission was denied with retry requested. The test backgrounded the app
before its then-31-second retry. The two-report confirmation fix above replaces
that delay for a young missing token. The final check includes the normal account
after the fixture in one native installation, rather than relying on teardown.

## Delivery and limits

The final protocol-2 relay version is `ad28c6fc-9058-453e-8837-5dad69b8ae09`.
Health reports `publisher-driven-push`. The development iOS app is installed on
the physical iPhone 12; the Mac publisher was reconnected using its installed
sandboxed app and retained grants. This fix requires no Mac packaging change.

Native runtime coverage is iOS 27 / iPhone 12 Pro Max / Xcode 27. Older iOS
runtimes and all possible APNs scheduling/network delays are not established.
No physical iPhone 17 was used. No Store upload occurred.

The reusable foreground recovery pattern and verification limits are recorded
in macOS-Recipes as `activitykit-foreground-recovery`. The helper typechecked for
iOS 17 using Swift 6 and the installed iOS SDK. Primary reference:
[Apple's foreground Live Activity lifecycle](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
