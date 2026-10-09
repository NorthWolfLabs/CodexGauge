# Comprehensive codebase review

October 8, 2026. Review of the working tree in `/Users/george/NorthWolfLabs/TokenTach`, based on commit `259c159` plus the substantial existing uncommitted changes, including the TokenTach rename. This is a report only. No application, test, configuration, or release implementation was changed for this review.

## Assessment

The repository has substantial defensive engineering: bounded readers, anchored file access, helper-signature validation, account-continuity checks, capability-scoped relay access, negative authorization tests, notification persistence, and explicit freshness models. Its automated checks pass. However, several limits intended to keep monitoring inexpensive discard information instead of deferring work. That can leave tasks missing, permanently working, or without token usage. Those are core product failures, and the current tests do not catch them.

The other major concerns are companion revocation/deletion behavior, lifecycle races around asynchronous work, and differences between what the release/documentation machinery promises and what it actually verifies. The code generally anticipates outages, but some recovery paths lose the very state needed to recover correctly.

This report contains 60 findings: 7 P1, 35 P2, and 18 P3, including bugs, reliability risks, missing product behavior, and maintainability concerns. The numbering is for discussion, not a claim that every finding deserves a separate change. Several share a root cause and should be addressed together.

### How to read the findings

- **P1:** Prioritize before broader distribution; affects core telemetry, meaningful privacy controls, or the release path.
- **P2:** User-visible correctness or reliability defect, or an important verification gap.
- **P3:** Product completeness, efficiency, documentation, or maintainability concern.
- **Reproduced:** A bounded local probe demonstrated the behavior using production source or the actual library/tool involved.
- **Source-confirmed:** The implementation establishes the behavior, but the full user-facing scenario was not exercised.
- **Risk/design gap:** A concrete missing invariant or product decision; frequency or production impact remains unmeasured.

P1 does not mean an exploited security vulnerability. This was a broad engineering review, not a penetration test or a release certification.

## Validation performed

| Check | Result |
| --- | --- |
| Mac hosted unit suite | 121 tests passed, 130 parameterized test executions; one signature-dependent test skipped |
| Companion shared Swift suite | 54 tests passed |
| Relay suite | 62 tests passed |
| Relay TypeScript check and Wrangler dry-run bundle | Passed |
| iPhone app and widget simulator build | Passed |
| Mac Release Universal 2 build | Passed; executable contains `x86_64` and `arm64` |
| Repository checks | Passed |
| Synthetic parser, subprocess, outbox, session-lifetime, and schema probes | Exposed the failures described below |

The Mac checks ran on Apple silicon, macOS 27.0.1, Xcode 27.0 build 27A266a. The Universal build proves compilation of both architectures, not execution on an Intel Mac.

Local evidence is available in [Mac test output](/tmp/tokentach-review-mac-tests.log), [companion checks](/tmp/tokentach-review-companion.log), [mobile build](/tmp/tokentach-review-mobile-build.log), [Universal build](/tmp/tokentach-review-universal.log), and [repository checks](/tmp/tokentach-review-repository.log). The synthetic probes and their output are under [/tmp/tokentach-review-probes](/tmp/tokentach-review-probes). These temporary artifacts are not committed and are not durable release records.

I reviewed the Mac application and native windowing code, local parsers and account client, notification/reset logic, shared companion models and storage, iOS app and widgets/Live Activities, relay authorization/delivery/persistence, tests and fixtures, project settings, packaging/CI scripts, experiments, and user/distribution/privacy documentation. Historical review documents were treated as historical evidence, not proof that the current tree still has their verified behavior.

I did not run the UI suites, the 25-minute resource gate, an Instruments soak, physical-device pairing/APNs/TestFlight, minimum-supported-OS execution, genuine Intel execution, or team-signed helper enforcement. No production relay state, personal Codex history, signing configuration, or notification settings were changed. Memory observations below are deliberately narrower than a claim that the app is otherwise leak-free.

## Local monitoring and helper lifecycle

### 1. Concurrent initialization launches multiple helper processes

**P1 · Reproduced.** [CodexAppServerClient.swift:202](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CodexAppServerClient.swift:202)

`ensureInitialized` suspends while validating and initializing the process without sharing an in-flight initialization task. Actor isolation does not prevent another caller entering during those awaits. The second caller can launch another helper and replace shared process, generation, pipe, and reply-routing state while the first call is still pending. Overlapping identity/activity/allowance requests during connection or recovery are enough to encounter this.

A synthetic helper that delays its initialization response by 500 ms succeeded with one identity request. Two requests 100 ms apart launched two children; neither completed before the probe stopped the client two seconds later. This demonstrates a lifecycle race, not merely extra startup work. A stop during validation also needs protection against a later continuation launching a process.

**Direction:** Make initialization single-flight, give each connection ownership of its transport state, and validate the connection generation after every suspension. Test concurrent first requests, stop during validation, and reconnect while old callbacks are pending.

### 2. The record budget permanently discards valid telemetry

**P1 · Reproduced.** [LocalSessionMonitor.swift:740](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:740)

After parsing 10,000 records, `parseLines` clears all remaining complete lines. The file offset already includes those bytes, so a later pass does not recover them. This can discard completion, approval, token, and subsequent turn-start events from an otherwise valid file that is well below the byte-size limits.

The probe compared a short rollout with the same rollout containing 10,000 small reasoning records before completion. The short file became `recent`; the dense file stayed `running`, with no completion timestamp. No malformed input or huge individual record was necessary.

**Direction:** Keep a resumable parse cursor and retained bounded backlog, or advance the file offset only through consumed records. A work budget should defer valid records rather than silently remove them. Verify lifecycle and token equivalence across different record densities and read boundaries.

### 3. A missing optional upstream field drops the entire token event

**P1 · Reproduced.** [LocalSessionMonitor.swift:1377](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1377), [decode failure handling:748](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:748)

The synthesized token-usage decoder requires `cache_write_input_tokens`. Upstream explicitly gives that field a default, allowing older records without it. TokenTach instead rejects the enclosing event, and `try?` makes the rejection invisible. This is especially relevant to existing on-disk histories and helper-version differences. See the upstream [Codex protocol definition](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs).

With otherwise identical synthetic usage, adding `cache_write_input_tokens: 0` produced 100 total tokens; omitting it produced zero. The repository's own performance workload omits it too, as discussed in finding 51.

**Direction:** Decode backward-compatible counters with appropriate defaults, distinguish unavailable observations from real zeroes, and maintain fixtures from multiple supported Codex schema versions.

### 4. Unread sessions are pruned before the startup backlog is processed

**P1 · Reproduced.** [processing budget:369](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:369), [maintenance scheduling:212](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:212), [pruning:1224](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1224)

Discovery creates sessions before their contents have supplied a real `lastActivity`. The initial processing pass has a 16 MiB budget. Sessions beyond that budget can still have their initial distant-past activity when the three-tick pruning pass runs, before the inactive-session rotation reaches them. They are removed as old despite containing recent activity. Rescan scheduling has the same underlying problem: discovery is not proof that a session has been read.

A synthetic directory with eight recent valid rollouts, roughly 3 MiB each, retained only six tasks after about 200 accelerated maintenance ticks. All eight files contained completion events. The remaining two were not merely delayed; they had disappeared from tracking.

**Direction:** Represent unread/discovered state explicitly, process the backlog fairly, and prune only after establishing activity age or another trustworthy retention criterion.

### 5. File replacement can preserve the previous file's state indefinitely

**P2 · Reproduced.** [LocalSessionMonitor.swift:505](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:505), [read guard:532](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:532)

The tailer resets on a smaller file, but does not track file identity. Replacing a rollout atomically with a same-sized or larger file makes the existing offset point into a different file. Earlier bytes in the replacement are never replayed. An unchanged size can make the replacement look completely unchanged.

The probe read a 218-byte file containing a start, then atomically replaced it with a 219-byte file containing completion. After repeated fallback checks, the task was still `running` and completion remained absent.

**Direction:** Track an anchored file identity, reset parsing state on replacement, and test same-size replacement, larger replacement, truncation, and replacement during reads. Preserve the existing symlink protections.

### 6. Discovery limits can exclude new work without a resumable scan

**P2 · Source-confirmed.** [LocalSessionMonitor.swift:271](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:271), [filesystem event handling:234](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:234)

Recursive discovery stops after 5,000 enumerated entries, without ordering recent directories first or retaining a continuation. A long-lived Codex home can consume that allowance on older directories/files before current sessions are reached. The lock-based direct lookup helps some live sessions, but does not cover every filename/version or unlocked recent task. Separately, processing only the first 512 paths from an event batch loses overflow paths unless another mechanism happens to rediscover them.

**Direction:** Prefer recent date partitions, retain scan progress, and turn event overflow into an explicit rescan request. Expose incomplete discovery rather than presenting a partial task list as exhaustive. Test large old histories with a small amount of new work at the end of enumeration.

### 7. Title indexing favors old records and can lose retained names

**P3 · Source-confirmed.** [LocalSessionMonitor.swift:1200](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1200), [title pruning:1229](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1229)

The title index reads the first 20,000 records. Later appended names or renames never apply after that point. Pruning then removes titles for currently untracked sessions, while the modification-date shortcut prevents rereading an unchanged index if one of those sessions becomes relevant again. Files above 16 MiB are skipped altogether without a visible coverage warning.

**Direction:** Incrementally consume appended records, retain a bounded map with deliberate eviction, and preserve access to the newest records. Test a rename beyond the record cap and a resumed task whose title was previously pruned.

### 8. Approval state does not clear when ordinary work resumes

**P2 · Source-confirmed.** [LocalSessionMonitor.swift:810](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:810), [tool output handling:842](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:842), [effective state:1055](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1055)

A recognized approval request sets `.needsApproval`. Reasoning, assistant output, ordinary tool results, and token events set activity/work-observed fields but do not clear that explicit state. `effectiveState` returns it before examining subsequent work. Unless Codex emits another turn start or completion, the UI and companion can continue asking for approval after work has resumed.

Input requests at least have a matching call-ID exit path; approval handling has no comparable resolution. This finding concerns the event types the parser already accepts, not a claim that every Codex build emits identical approval records.

**Direction:** Model approval resolution explicitly and define which authoritative work events end the waiting phase. Test request → approval → tool execution → output within one turn.

### 9. Aborted turns produce successful-looking completion events

**P2 · Source-confirmed.** [LocalSessionMonitor.swift:796](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:796), [AlertMonitor.swift:175](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:175)

`turn_aborted` and `task_aborted` share the same branch as normal completion and populate `completionEventAt`. That timestamp drives the completed notification and companion terminal state. A user cancelling work can therefore receive “Task completed,” with no retained distinction between successful finish and interruption.

**Direction:** Preserve terminal outcome separately from whether a task is active. Decide whether cancellation deserves its own notification, a neutral “ended” label, or no alert. Do not infer success from the mere presence of a terminal event.

### 10. Old task state can stay active while a healthy Mac keeps it looking fresh

**P2 · Source-confirmed; partial probe.** [LocalSessionMonitor.swift:1055](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1055), [CompanionLiveState.swift:39](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionLiveState.swift:39), [snapshot conversion:104](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionLiveState.swift:104)

Once an explicit start/input/approval has been observed, loss of a writer lock and lack of new evidence do not move it to an unknown/stale lifecycle state. It remains active until a terminal event or retention pruning. A missing completion after a helper crash is a normal way to reach this. The probe confirmed that a start from two hours earlier, without a writer lock, remained `running`; it does not establish how often real Codex rollouts omit their terminal event.

Some Mac/phone views correctly show observation age. Live Activity expiration, however, is based on the overall snapshot timestamp. Fresh Mac publications can keep an old task's “Working” presentation and elapsed timer fresh even though `taskObservedAt` is old.

**Direction:** Separate feed health, task-observation freshness, and lifecycle outcome. Preserve “last known working” without inventing completion, and use task freshness when presenting live activity.

### 11. A new turn inherits the previous turn's output and latency

**P2 · Source-confirmed.** [LocalSessionMonitor.swift:784](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:784)

The start branch clears duration and latest-call usage but leaves `latestOutput` and `latestLatency` from the previous turn. Until new usage/latency data arrives, the current task can display an old output count or response-start latency as if the new turn already produced it. These fields are also exported to companion metrics.

**Direction:** Reset turn-scoped metrics together on an authoritative start, or attach each metric to the turn that produced it. Verify the interval between a second turn's start and its first response.

### 12. Request timeouts leave a hung initialized helper eligible for reuse

**P2 · Source-confirmed.** [CodexAppServerClient.swift:424](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CodexAppServerClient.swift:424), [initialization shortcut:202](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CodexAppServerClient.swift:202)

A timed-out request is removed and failed, but the initialized connection/process is not invalidated. If the helper remains alive while no longer answering, the next retry uses the same connection. App-level backoff changes when the next request occurs; it does not repair that transport. Recovery can require an external process exit or user intervention.

**Direction:** Define connection health independently of process liveness. After an appropriate timeout policy, close the generation, fail its remaining requests, and initialize a fresh helper with bounded backoff. Avoid restarting on every isolated application-level error.

## Notifications and event semantics

### 13. The notification outbox can grow past its own persistence limit and stop draining

**P2 · Reproduced limit; source-confirmed wedge.** [AlertMonitor.swift:57](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:57), [enqueue:208](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:208), [drain guard:235](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:235)

Pending events have no overall count/age budget, but the file store rejects state larger than 512 KiB. New task-phase events normally have different keys, so coalescing does not prevent growth during repeated delivery failures. Once persistence fails, `storageError` prevents draining. Delivery cannot shrink the queue because the oversized queue must first save successfully.

A synthetic state with 1,000 permitted-size task/project summaries encoded to 610,753 bytes and was rejected. The complete thousand-event delivery scenario was not run; the persistence/drain dependency establishes the deadlock. Ordinary notification-permission denial does not cause this backlog, because that path deliberately acknowledges the event.

**Direction:** Bound pending state before persistence, expire/coalesce superseded events, and provide a recovery path that can reduce an oversized queue. Surface persistence failure to the user.

### 14. Delayed Mac notifications lose catch-up context and can announce obsolete phases

**P2 · Source-confirmed.** [NotificationScheduler.swift:34](/Users/george/NorthWolfLabs/TokenTach/TokenTach/NotificationScheduler.swift:34), [AlertMonitor.swift:194](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:194)

The monitor records `isCatchUp`, `since`, `observedAt`, and the task's attention status, but local delivery ignores those fields. A delayed alert is worded like a current event. The queue also has no task-phase expiry/supersession policy, so “working” or “needs input” can arrive after completion when delivery recovers. Approval-specific context is reduced to the generic attention title.

The relay at least adds an observation interval for catch-up and bounds pending delivery lifetime; the Mac path should have an equally explicit contract.

**Direction:** Include delayed-observation context, retain approval/input distinctions, and suppress old intermediate phases when a newer terminal state is known.

### 15. Local task notifications depend on successful account validation

**P2 · Source-confirmed; product coupling.** [AlertMonitor.swift:160](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:160), [AppState.swift:171](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift:171)

`observeTasks` returns unless the account-related monitor is validated; account failures suspend it. Local file telemetry can continue working while the helper is unavailable, signed out, or failing allowance requests, yet task notifications stop too. That is surprising for an independently available local feature.

The account-continuity guard is valuable and should not simply be removed. The issue is that account reset evidence and installation-local task events share the same availability gate.

**Direction:** Give local task routing its own trustworthy identity/lifecycle boundary and expose separate account and task-monitor health. Test local completion while account fetching is unavailable.

### 16. Notification clicks only look for ChatGPT at fixed paths

**P2 · Source-confirmed.** [NotificationScheduler.swift:205](/Users/george/NorthWolfLabs/TokenTach/TokenTach/NotificationScheduler.swift:205)

The notification action is “Open ChatGPT” and searches only `/Applications/ChatGPT.app` and a home-relative equivalent. A supported Codex-only installation gets a silent no-op. The home-relative lookup also uses `NSHomeDirectory`, which is the sandbox container in the sandboxed app, not necessarily the user's actual Applications folder.

The main application already has a more capable opening path. Maintaining a second path has allowed behavior to diverge.

**Direction:** Route notification opening through the same supported-app resolver as the rest of the app, and provide a useful fallback when the originating app cannot be located.

### 17. Mac and phone alerts implement different meanings for the same event categories

**P2 · Source-confirmed.** [relay alerts.ts:55](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/alerts.ts:55), [ResetMonitor.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/ResetMonitor.swift), [AlertMonitor.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift)

The relay hardcodes a 10% low-allowance crossing, recognizes allowance resets only when the prior deadline has passed, and recognizes banked resets by count increases. The Mac supports configurable thresholds and richer reset evidence, including cases where deadline/count comparison is insufficient. Thus a user selecting corresponding categories on two devices can receive different events from the same account transition.

**Direction:** Write down a shared event contract and test the same transition fixtures against Swift and TypeScript. If the phone intentionally has narrower semantics, explain that in its controls instead of making similarly named options imply equivalence.

## Companion privacy, recovery, and resource ownership

### 18. Users cannot revoke a copied pairing link or delete their relay feed

**P1 · Source-confirmed.** [CompanionSettingsView.swift:9](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionSettingsView.swift:9), [CompanionPublisher.swift:114](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:114), [relay management routes:246](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts:246)

The relay implements rotation/deletion operations, but the shipped Mac controls expose only sharing on/off, pairing, and removal of individual devices. The publisher has no user-facing path to invoke link rotation or feed deletion. Turning sharing off intentionally leaves the stored snapshot readable.

Removing a paired device correctly revokes that device's issued credential. It does not revoke the original QR/link reader capability. Anyone who retained that capability can read directly or pair again; removing an entry from the device list is not sufficient recovery from a leaked QR code.

[PRIVACY.md:36](/Users/george/NorthWolfLabs/TokenTach/PRIVACY.md:36) describes replacing links, and [line 40](/Users/george/NorthWolfLabs/TokenTach/PRIVACY.md:40) names “Disconnect and delete relay data,” but neither action is available in the current interface.

**Direction:** Expose rotation and deletion with precise effects, clear local credentials/cache as appropriate, and verify old master links, per-device credentials, sockets, and subscriptions after each operation. This is a missing privacy control, not a failure of the existing individual-device authorization check.

### 19. Receiver data survives removal of its final subscription

**P1 · Source-confirmed.** [receiver account persistence:72](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/receiver.ts:72), [registration:131](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/receiver.ts:131), [revocation:218](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/receiver.ts:218)

Receiver objects persist `account:<id>` records, including account identity information, and a `device` registration containing APNs data. Revocation removes the subscription, Mac snapshot, and Live Activity record, but does not remove retained account records or the device registration when no subscriptions remain. There is no general empty-receiver deletion path matching the privacy policy's promise. Account baselines can also accumulate as accounts change.

A short-lived sanitized end-push job is reasonable during revocation. It does not justify indefinite retention of unrelated account/device state after cleanup finishes. The only separate invalid-token cleanup is not equivalent to last-subscription deletion.

**Direction:** Define receiver reachability and retention explicitly. Remove unreferenced account baselines, and delete remaining receiver state after its final permitted cleanup delivery expires or completes. Test actual durable storage keys after removing the last Mac.

### 20. Usage-only sharing exists in the protocol but cannot be selected in the product

**P3 · Source-confirmed.** [CompanionPublisher.swift:92](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:92), [link construction:144](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:144), [pairing interface:54](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionSettingsView.swift:54)

A usage-only credential is generated and sent to the relay, and the relay/phone understand the scope. The Mac only constructs the full viewing link, however, so the user cannot choose the more limited sharing mode described in Help and the privacy documentation. The device list can display “Usage only” for a state the normal pairing flow cannot create.

**Direction:** Offer a scope choice when pairing/copying a link and state exactly which identity information remains shared. Alternatively, remove the unimplemented product promise until the control exists.

### 21. Sparse relay checkpoints can roll a completed task back to working

**P2 · Source-confirmed; restart scenario not run.** [index.ts:410](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts:410), [snapshot retrieval:348](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts:348)

The live snapshot is durable only once every 300 seconds, regardless of whether a frame changes a task from running to completed. If the Mac publishes completion, then sleeps/disconnects before the next checkpoint, losing the Durable Object's in-memory instance leaves the persisted working snapshot. A later viewer can see older active work reappear.

The bounded refresh-on-read helps when a publisher is connected. It cannot recover a newer observation from an offline Mac. The independent push receiver can know about completion without making the feed's snapshot endpoint durable.

**Direction:** Keep inexpensive sampling for rapidly changing rates, but checkpoint important semantic transitions and newer terminal states. Test instance reconstruction after completion with no publisher available.

### 22. The phone accepts older snapshots and can commit a cancelled decode

**P2 · Source-confirmed.** [CompanionStore.swift:254](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionStore.swift:254)

The receive loop checks cancellation before `await decodeEnvelope`, then assigns the decoded snapshot without rechecking cancellation, the current link/capability, or whether the snapshot is newer than the one already displayed. Decoding is explicitly concurrent, so removing/replacing a link can happen during the suspension. An old connection can then put data back after the removal or a scope change. Separately, reconnecting to an older relay checkpoint can overwrite newer phone state.

The widget fetch/cache path already contains stronger merge protections; the foreground store needs its own equivalent invariants.

**Direction:** After decoding, verify cancellation and connection ownership, require the exact current capability, and enforce observation ordering. Test a delayed decode racing removal, full-to-usage replacement, and an older reconnect frame.

### 23. Forgetting a Mac is blocked by APNs registration and network availability

**P2 · Source-confirmed.** [CompanionStore.swift:180](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionStore.swift:180), [CompanionPush.swift:137](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionPush.swift:137)

Removal first awaits push unlinking, then unpairing, and only then removes local data. Push unlinking can wait for an APNs token and fail before the paired-device revocation path is reached. A phone with unavailable push registration, an offline connection, or a permanently retired relay can therefore be unable to forget the Mac locally.

Remote revocation matters, but it should not make local credential and cached-data removal impossible. The UI's single failure message obscures which part remains unfinished.

**Direction:** Separate local forgetting from durable pending remote cleanup. Let users remove local access immediately, retain only the minimum credential needed for retry if appropriate, and accurately state whether server-side revocation is complete.

### 24. Pairing retries can consume device slots and leave old credentials active

**P2 · Source-confirmed.** [CompanionStore.swift:128](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionStore.swift:128), [pair creation:150](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionStore.swift:150)

Each pairing attempt generates a new device ID and token before making the request, but persists the resulting link only after success. If the relay commits the pairing and the response is lost, a retry creates a different device rather than recovering the existing one. Repetition can fill the 16-device limit with entries the phone no longer knows how to clean up.

Replacing a prior pairing also uses best-effort `try?` removal. Failure there can leave the previous credential/subscription active without a durable cleanup record.

**Direction:** Persist a pending pairing transaction and reuse its identity on retry. Make replacement cleanup recoverable, and test response loss after server commit as well as failure after the new credential has been saved.

### 25. Live Activity dismissal is a one-shot best-effort write

**P2 · Source-confirmed.** [CompanionLiveActivities.swift:261](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionLiveActivities.swift:261)

When ActivityKit reports dismissal/end, the phone sends one `try?` registration update and then removes its token/observer/update state. Failure loses the user's dismissal intent. The relay's recovery logic can subsequently treat the missing activity as something to recreate rather than something the user intentionally dismissed.

This is particularly relevant to dismissal while temporarily offline. Other registration paths have retry behavior, so the asymmetry is easy to overlook.

**Direction:** Persist pending dismissal/end intent until acknowledged, reconcile it before any restart request, and test dismissal during network failure followed by foreground recovery. Keep automatic endings distinct from explicit user dismissal.

### 26. Task-cycling requests create delegate-backed URLSessions without invalidating them

**P2 · Source-confirmed ownership defect; Foundation behavior reproduced.** [CompanionLiveState.swift:238](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionLiveState.swift:238), [session factory:44](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionStorage.swift:44)

Every task-selection request creates a fresh `URLSession` with a delegate, starts a byte stream, and then drops the session reference. It neither reuses the session nor invalidates it. Delegate-backed sessions have an explicit invalidation lifecycle; completing a request is not a substitute.

A local Foundation probe completed a request and released its owner: the session remained alive. Explicit invalidation allowed it to disappear. That establishes the ownership problem in this pattern on the review Mac; it is not a measurement of accumulated iPhone/extension memory in production.

**Direction:** Reuse an owned session or finish/invalidate each disposable session on every exit path. Verify repeated successful, failed, and cancelled task selections with weak-reference lifetime checks and a device memory profile.

### 27. The WebSocket limit can reject the publisher that would replace an old publisher

**P2 · Source-confirmed.** [index.ts:366](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts:366)

The global 16-socket check runs before old publisher sockets are closed. With 15 viewers and an existing/stale publisher, a replacement publisher gets 429 instead of replacing its predecessor. Sixteen viewers can also consume every slot even though publishing is required to make them useful. The 16 paired-device allowance does not reserve any transport capacity for the Mac.

**Direction:** Reserve publisher capacity and apply replacement logic before admission accounting. Keep a separate viewer limit and test a full feed during publisher reconnect.

### 28. Accepted numeric data can crash the phone's detail view

**P2 · Schema acceptance reproduced; trapping conversion source-confirmed.** [protocol.ts:28](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/protocol.ts:28), [CompanionHome.swift:409](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionHome.swift:409)

The relay permits any finite nonnegative `fiveMinuteRate`. A probe with `1e100` passed `snapshotSchema.safeParse`. The phone formats that field with `Int(value)`, which traps when the Double is outside Int's range. A frame can therefore satisfy the relay's schema and still be unsafe for its consumer. The Swift decoder also does not independently implement the relay's full validation contract.

This requires a malformed/hostile publisher or relay; it is not unauthenticated remote execution. The app also supports configured relay URLs, so the consumer should not rely solely on a trusted default server.

**Direction:** Establish safe numeric ranges in the wire contract, validate again at the Swift boundary, and use nontrapping formatting/conversion. Include extreme finite values, unreasonable timestamps, duplicate identifiers, and partial optional metrics in cross-language fixtures.

### 29. Some size limits are checked only after an unbounded read

**P2 · Source-confirmed.** [CompanionPublisher.swift:75](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:75), [push response:184](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:184)

The push journal uses `Data(contentsOf:)` before checking its 32 MiB size. The push response uses `session.data(for:)` before checking for 4 KiB. Neither limit bounds the allocation or bytes received; it only rejects after consumption. A corrupted oversized local file or unexpectedly large response can consume memory well beyond the stated limit.

Other parts of this repository already use bounded file reads and bounded streaming responses correctly, making these exceptions unnecessary.

**Direction:** Check anchored metadata and perform bounded reads for the journal; stream the response with a byte limit and cancellation. Test one byte over the limit and a response that keeps streaming.

### 30. Journal encoding and atomic disk writes run on the UI actor

**P2 · Risk/design gap; latency unmeasured.** [CompanionPublisher.swift:166](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:166), [CompanionPushJournal:429](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionModels.swift:429)

The main-actor publisher synchronously encodes and atomically writes its entire journal. The journal can retain up to 128 reduced snapshots; persistence occurs during observation/acknowledgment processing, not just at shutdown. A prolonged outage and large task-summary payloads make the cost substantially different from the common one-snapshot case. Account history and most metrics are stripped from these journal entries, which helps, but does not remove synchronous serialization and disk work. Startup restoration also decodes on this path.

I did not measure a UI stall, so this is not a claimed frame-time regression. It is a concrete placement of potentially multi-megabyte CPU/disk work on the UI actor.

**Direction:** Give durable journal I/O a serial non-UI owner, retain ordering/acknowledgment guarantees, and measure a nearly full journal on a slower disk. Do not solve it by making persistence fire-and-forget and losing crash durability.

### 31. Build/distribution environments do not select an isolated relay

**P2 · Release-readiness gap.** [CompanionPublisher.swift:26](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:26), [relay configuration](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/wrangler.jsonc), [distribution instructions](/Users/george/NorthWolfLabs/TokenTach/Distribution/TestFlight.md)

The default relay is a development endpoint, without a corresponding build-channel selection/migration mechanism for beta versus production credentials and data. Packaging does distinguish APNs environments, but that does not itself isolate relay storage or service policy. A future distribution build can therefore inherit the same development service unless somebody manually coordinates the change.

The privacy document explicitly says production distribution is not enabled yet; this is unfinished release infrastructure, not evidence that production users have already been misrouted.

**Direction:** Define relay environments as part of signed build configuration, validate the expected combination with APNs entitlements, and plan how existing pairings migrate or deliberately require re-pairing.

### 32. Pairing while sharing is paused silently leaves the phone without new updates

**P3 · Source-confirmed.** [CompanionSettingsView.swift:14](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionSettingsView.swift:14)

If a viewing link already exists and sharing is off, “Pair iPhone…” immediately displays that link without resuming publication or explaining the paused state in the sheet. Pairing can succeed while the phone sees an old snapshot or waits indefinitely for new data. The setup action appears successful without completing the behavior the user was trying to enable.

**Direction:** Explain that sharing is paused in the pairing flow and offer the corresponding enable action. Keep a deliberate pause intact unless the user explicitly chooses to resume.

### 33. Task truncation is not represented in the companion payload

**P3 · Source-confirmed.** [CompanionPublisher.swift:338](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CompanionPublisher.swift:338), [CompanionModels.swift](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionModels.swift)

The publisher exports at most 200 task summaries, and transport encoding can trim further to meet its byte limit. The protocol has history-truncation information for account history but no equivalent task-coverage flag/count. The phone and Live Activity consequently cannot distinguish “all active tasks” from “the retained subset,” and users cannot explain count differences between Mac and phone. At sufficiently large active workloads, prioritizing active tasks still cannot guarantee that every active task fits.

**Direction:** Include total/omitted counts or an explicit task-coverage state, preserve important terminal transitions independently, and make incomplete aggregates visible. Keep the bounds; expose their consequences.

### 34. Anonymous relay creation has no durable expiry or meaningful total admission bound

**P3 · Operational hardening gap.** [relay initialization and rate limiting](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts), [wrangler.jsonc](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/wrangler.jsonc)

Initialization accepts self-generated installation identities and credentials. The per-IP rate limiter slows creation but does not establish an overall authorized population, and initialized feed storage has no automatic abandoned-feed expiry. Repeated creation over time or across addresses can create persistent objects/data and billable work. A leaked publisher capability can also generate authenticated high-frequency traffic without an explicit per-feed message budget.

This is a cost/operations concern for a publicly reachable service, not a demonstrated cross-user authorization bypass. A small controlled development trial may reasonably accept it temporarily.

**Direction:** Before broader access, define registration/admission, abandoned-feed retention, usage limits, and operator alerts. Test limits without requiring production secrets or storing real task data.

### 35. Invalid push tokens leave the feed advertising push demand

**P3 · Source-confirmed.** [receiver.ts:324](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/receiver.ts:324), [index.ts:428](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts:428)

On an invalid alert token, the receiver forgets the device and clears its outbox. The feed's subscriber record can still have `pushEnabled`, so adaptive demand continues telling the Mac that push observations are needed. If every relevant receiver is in this state, the Mac and relay can keep doing push-related work with nobody eligible to receive it.

**Direction:** Propagate invalid-registration state back into demand calculation or use expiring registration liveness. Preserve recovery when a phone supplies a replacement token, and verify that zero viable receivers allows publishing to idle.

## Presentation, freshness, and product completeness

### 36. The Dashboard presents stale allowances without their freshness state

**P2 · Source-confirmed.** [DashboardView.swift:98](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:98), [reset label:155](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:155), [AppState.swift:105](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift:105)

The Dashboard allowance cards use the retained snapshot without displaying the account freshness/error/observation information available elsewhere. A cached allowance can look current while the account helper is failing. An expired reset can read “Resetting now” long after the cache became stale.

The reset string is also computed with `state.currentDate`, a plain computed clock value rather than the Dashboard's observed surface clock. Passage of time alone does not invalidate that dependency. Other updates can refresh it, but a countdown should not depend on incidental account or task changes.

**Direction:** Carry the same explicit freshness model into Dashboard cards and make countdown updates depend on the visible clock. Test an offline cached snapshot across a reset deadline with no task updates.

### 37. Account activity can silently remain old while allowances look healthy

**P2 · Source-confirmed.** [AppState.swift:473](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift:473), [Dashboard activity section:235](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:235)

Activity fetching uses `try?` and preserves older activity data on failure. Retaining useful history is sensible, and its separate observation time is maintained. The Mac history presentation does not surface that age or partial failure, so successful allowance polling makes the whole account appear updated even when daily/lifetime statistics are not.

**Direction:** Track/report activity-fetch health separately from allowance health, label retained history with its observation age, and provide a targeted retry. Verify fresh limits combined with repeatedly failing history requests.

### 38. The primary popover hides available local tasks behind account setup/failure

**P2 · Source-confirmed; product coupling.** [ContentView.swift:42](/Users/george/NorthWolfLabs/TokenTach/TokenTach/ContentView.swift:42), [AppState.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift)

The conversation section is nested under the account-snapshot presentation branch. Local session monitoring can already be producing valid tasks before helper selection/account fetching succeeds, but those tasks are not exposed in the main popover. The Dashboard and underlying providers are more independent than this primary interface suggests.

**Direction:** Present local task health and account setup independently. A missing allowance connection should explain the unavailable allowance section while still making successfully observed local work accessible.

### 39. The token mix bar treats overlapping counters as disjoint categories

**P2 · Source-confirmed.** [TokenMixBar.swift:6](/Users/george/NorthWolfLabs/TokenTach/TokenTach/TokenMixBar.swift:6)

The stacked bar sums input, cached input, output, and reasoning output as its denominator. Cached input is part of input, and reasoning output is part of output. For 80 input tokens including 60 cached and 20 output including 10 reasoning, the bar divides by 170 rather than the 100-token total. Its segment widths therefore do not represent a meaningful partition of token usage. Cache-write usage is also absent from the displayed breakdown.

Upstream's [token-usage formatting](https://github.com/openai/codex/blob/main/codex-rs/tui/src/token_usage.rs) explicitly subtracts cached input to derive non-cached input; its [response usage parsing](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/sse/responses.rs) reads reasoning as output detail.

**Direction:** Use mutually exclusive segments with clearly defined cache-write semantics, or show overlapping counters as separate values instead of a 100% stacked composition. Test the visual proportions against a known counter example.

### 40. Some Mac charts and metrics turn unavailable or partial telemetry into definite values

**P2 · Source-confirmed.** [DashboardView.swift:813](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:813), [ContentView.swift:675](/Users/george/NorthWolfLabs/TokenTach/TokenTach/ContentView.swift:675)

The Dashboard records a point for every displayed conversation on each sample, without requiring a token observation or a fresh measurement; nonfinite values become zero. The detail presentation also has paths that show a numeric five-minute rate without carrying availability. Partial aggregate token totals have model-level completeness information that is not consistently reflected in the Mac interface.

The result can look like measured inactivity or an exact total when the reader actually lacks evidence. The phone has more deliberate missing-sample/partial-data behavior, so this is also cross-surface inconsistency.

**Direction:** Keep missing observations as gaps/unavailable values and label partial totals. Distinguish a measured zero from no measurement throughout models, charts, accessibility values, and export.

### 41. The rate is a smoothed estimate, not a conventional rolling-window average

**P3 · Source-confirmed; metric-definition decision.** [LocalSessionMonitor.swift:1033](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:1033)

`timeWeightedRate` sums all tokens in the window, converts to a per-minute value, then multiplies the whole sum by an idle factor based only on the newest sample. For a 60-second window, 600 tokens observed 30 seconds ago display as 300 tok/min rather than the conventional 600 tok/min window average. A new small sample also restores the weight of older samples.

The comments make clear that smoothing is intentional; the concern is the meaning communicated by “pace,” “last minute,” and “five-minute” metrics and comparisons. Users may reasonably treat these as directly measured averages.

**Direction:** Document and label the estimate, or separate an exact rolling average from an animated instantaneous estimate. Add tests for the mathematical definition, including sparse batches and an old large batch followed by a tiny new one.

### 42. Empty activity in the selected period hides available all-time statistics

**P3 · Source-confirmed.** [DashboardView.swift:235](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:235)

The lifetime/statistics content sits inside the branch that requires daily activity for the selected period. Choosing Today on a day with no activity can hide valid lifetime totals, streaks, or longest-turn information even though those values are independent of today's rows.

**Direction:** Scope the empty state to the period-dependent chart and retain available all-time metrics. Verify an empty current day with nonempty historical/lifetime data.

### 43. The five-minute chart's effective retention shrinks as task count grows

**P3 · Source-confirmed.** [DashboardView.swift:813](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardView.swift:813)

The history stores one sample per task per second but applies a single 3,000-sample cap. Ten tasks fit roughly five minutes; twenty tasks fit roughly two and a half minutes. Larger task sets shorten the chart further while the axis still describes a five-minute interval. View-local history also starts over when the view's lifetime resets.

**Direction:** Budget by time and series, downsample deliberately, or disclose available coverage. A per-series ring buffer or aggregate sampling policy would make retention predictable without removing bounds.

### 44. The quota widget does not identify the account whose number it selected

**P3 · Source-confirmed.** [TokenTachWidgets.swift:45](/Users/george/NorthWolfLabs/TokenTach/Companion/Widgets/TokenTachWidgets.swift:45)

The widget chooses allowance windows across available snapshots, including the most constrained values, but its compact labels do not identify the account/Mac and it offers no corresponding account selection. With multiple accounts, a displayed weekly percentage can be valid yet impossible to attribute. The selected account can change when a different account becomes more constrained, without making that change visible.

**Direction:** Give the widget an explicit account selection or clearly labeled aggregation policy. Include identity where the family permits it and an unambiguous accessibility description everywhere.

### 45. Widget stale/empty states are inconsistent across families

**P3 · Source-confirmed.** [TokenTachWidgets.swift:72](/Users/george/NorthWolfLabs/TokenTach/Companion/Widgets/TokenTachWidgets.swift:72), [empty state:121](/Users/george/NorthWolfLabs/TokenTach/Companion/Widgets/TokenTachWidgets.swift:121)

The accessory circular family adds stale context to accessibility text but leaves the visual gauge looking current. Separately, the no-window fallback asks the user to link a Mac even when a Mac is already linked but has not produced usable allowance data. That sends the user back through the wrong corrective action.

**Direction:** Make stale visual treatment consistent within each widget family's limits, and distinguish unlinked, waiting, offline, and linked-without-account-data states. The next action should follow the actual missing prerequisite.

### 46. The Dashboard's timer keeps running while its window is minimized

**P3 · Source-confirmed; energy impact unmeasured.** [DashboardWindowController.swift:29](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardWindowController.swift:29), [close handling:42](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardWindowController.swift:42), [VisibleSurfaceClock.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/VisibleSurfaceClock.swift)

The surface clock starts when the Dashboard is shown and stops when the window closes. There is no matching miniaturization/visibility handling, despite the window being minimizable. The explicit one-second timer continues while minimized. SwiftUI may independently suppress some rendering; I am not claiming all chart frames continue to draw.

**Direction:** Tie presentation-only clocks to effective visibility and resume from the current time on restore. Include minimized/hidden windows in the resource scenarios so “not visible” has a defined operational meaning.

## Tests, release engineering, and reproducibility

### 47. The draft-release job invokes GitHub CLI without a repository

**P1 · Tool failure reproduced; workflow source-confirmed.** [release.yml:366](/Users/george/NorthWolfLabs/TokenTach/.github/workflows/release.yml:366)

`publish-draft` downloads artifacts but does not check out the repository, set `GH_REPO`, or pass `--repo` to `gh release view/create`. GitHub CLI cannot infer a repository from an artifact directory. The first failure is hidden by the `if` existence check; the subsequent create command then fails rather than creating the intended owner-reviewed draft.

Running `gh release view` from a non-repository temporary directory reproduced “failed to run git: fatal: not a git repository.” No release was created or changed.

**Direction:** Pass the explicit repository identity to both commands or set `GH_REPO` for this job. Distinguish “release absent” from authentication/network/tool errors instead of treating every failed lookup as absence.

### 48. The GitHub release path does not enforce the same gates as the local release path

**P2 · Source-confirmed.** [release workflow](/Users/george/NorthWolfLabs/TokenTach/.github/workflows/release.yml), [local release script:289](/Users/george/NorthWolfLabs/TokenTach/Scripts/release.sh:289), [performance policy](/Users/george/NorthWolfLabs/TokenTach/Performance/README.md)

The local release script includes the resource gate and package smoke validation. The GitHub release workflow has its own compatibility/build/sign/publish pipeline, but does not run the performance script or require the companion/repository workflows' successful results for the tagged commit. Verifying that a tag points at an allowed branch commit is not equivalent to verifying all required checks passed for that exact commit.

This leaves two different meanings of “release validation,” and documentation can imply stronger coverage than the automated publication path establishes.

**Direction:** Define a shared gate contract and make every distribution path either execute it or consume immutable results tied to the exact source/artifact. Document intentional channel exceptions explicitly.

### 49. Companion CI builds the UI but does not execute its UI tests or select the pinned toolchain

**P2 · Source-confirmed.** [companion.yml:15](/Users/george/NorthWolfLabs/TokenTach/.github/workflows/companion.yml:15), [Companion/UITests](/Users/george/NorthWolfLabs/TokenTach/Companion/UITests)

The workflow runs shared-model/relay tests and a generic simulator build. It never runs the existing phone UI acceptance tests. Pairing, removal, stale-state rendering, navigation, and interaction regressions can therefore coexist with a green companion workflow. It also uses the runner's default Xcode rather than selecting/checking the version recorded for the project.

Some physical-device/APNs cases appropriately remain opt-in. That is separate from running deterministic simulator cases already present in the repository. A successful simulator compile is not evidence that those flows work.

**Direction:** Run a bounded, local-fixture UI subset on an explicit simulator/toolchain, and keep device-only qualification as a clearly separate gate.

### 50. The critical helper launch-signature test is skipped in ordinary ad-hoc runs

**P2 · Observed verification gap.** [TokenTachTests.swift:1049](/Users/george/NorthWolfLabs/TokenTach/TokenTachTests/TokenTachTests.swift:1049), [ci.yml](/Users/george/NorthWolfLabs/TokenTach/.github/workflows/ci.yml)

`helperLaunchRequirementRejectsAProcessFromAnotherSigner` requires a team-signed host and skips under ad-hoc signing. That is exactly what happened in this review and what the ordinary test commands use. Other trust tests are valuable, but they do not replace exercising the OS launch requirement in a realistically signed app.

This is not a finding that signature enforcement is broken. It is a gap between security-sensitive source logic and the normal executable test evidence.

**Direction:** Add a restricted signed qualification job/manual release check covering both allowed and wrong-signer helpers. Keep signing credentials away from untrusted pull-request execution and record the tested OS/helper/signing matrix.

### 51. The performance fixture's token records are rejected by the production parser

**P2 · Source-confirmed and supported by finding 3's probe.** [PerformanceWorkload.swift:62](/Users/george/NorthWolfLabs/TokenTach/TokenTach/PerformanceWorkload.swift:62)

Both token-usage objects in the generated records omit `cache_write_input_tokens`. With the current required-field decoder, the workload exercises record parsing and rejection instead of normal token accumulation, rate calculation, and all downstream changes caused by accepted observations. A low-resource result can therefore be reassuring about the wrong workload.

This is a verification consequence of finding 3, not an independent parser defect. It deserves separate attention because fixing the parser may materially change the measured resource profile.

**Direction:** Assert fixture behavior before resource measurement: expected task count/state, positive token totals, changing rates, and successful terminal transitions. Re-run performance qualification after restoring accepted token events.

### 52. Dashboard presentation timing measures the show call, not a rendered frame

**P3 · Source-confirmed measurement limitation.** [DashboardWindowController.swift:31](/Users/george/NorthWolfLabs/TokenTach/TokenTach/DashboardWindowController.swift:31), [PerformanceSignposts.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/PerformanceSignposts.swift)

The presentation metric is recorded immediately after the window-show operation. That measures work up to that call's completion, not necessarily layout, drawing, compositing, or the first useful chart frame. A regression that defers expensive work until after the call can pass a “presentation latency” budget while still feeling slow.

The existing metric remains useful as a controller-level timing; the problem is interpreting it as end-to-end visible latency.

**Direction:** Name that boundary accurately and add a separate first-useful-frame/interaction measurement where reliable. Correlate signposts with UI traces rather than assuming the method return proves pixels appeared.

### 53. Candidate source records cannot reconstruct builds containing untracked files

**P2 · Source-confirmed.** [package-mobile.sh:15](/Users/george/NorthWolfLabs/TokenTach/Scripts/package-mobile.sh:15), [package-candidate.sh:5](/Users/george/NorthWolfLabs/TokenTach/Scripts/package-candidate.sh:5), [package-store.sh](/Users/george/NorthWolfLabs/TokenTach/Scripts/package-store.sh), [package-beta.sh](/Users/george/NorthWolfLabs/TokenTach/Scripts/package-beta.sh)

The mobile packager saves HEAD, a binary diff against HEAD, and short status. Git diff does not contain untracked file contents. Other packaging paths retain even less source material, and the candidate path has no equivalent complete source capture. In the current rename-heavy tree, substantial application/project content is untracked, so these records cannot recreate the app they package.

Allowing dirty development candidates is a legitimate workflow; the issue is claiming useful provenance without capturing all build inputs.

**Direction:** Record a reproducible source snapshot or manifest/archive including untracked build inputs, plus configuration/toolchain/dependency versions. For official release paths, a clean immutable commit can supply that boundary. Do not silently discard existing user changes to achieve it.

### 54. Versions, project generation, and packaging rules have multiple sources of truth

**P3 · Source-confirmed maintainability risk.** [package-candidate.sh:5](/Users/george/NorthWolfLabs/TokenTach/Scripts/package-candidate.sh:5), [generate-companion-project.rb](/Users/george/NorthWolfLabs/TokenTach/Scripts/generate-companion-project.rb), [Mac project](/Users/george/NorthWolfLabs/TokenTach/TokenTach.xcodeproj/project.pbxproj), [distribution documents](/Users/george/NorthWolfLabs/TokenTach/Distribution/README.md)

The checked-in project/generator, candidate defaults, and distribution documentation carry separate version/build values and channel decisions. Some differences are intentional staged releases, but that intent is not encoded in one validated manifest. The Ruby project generator also relies on the installed `xcodeproj` environment without a repository-locked dependency set or a checked regeneration-diff gate.

Signing, package checking, provenance, and gate behavior are repeated across several scripts, which has already produced the inconsistencies above.

**Direction:** Centralize channel/version inputs and reusable package validation, lock generator dependencies, and verify that regenerating the companion project does not introduce an unexpected diff. Keep channel-specific behavior explicit rather than hiding it in unrelated defaults.

## Documentation, architecture, and diagnostics

### 55. README and in-app Help make incorrect privacy claims

**P2 · Source-confirmed.** [README.md:77](/Users/george/NorthWolfLabs/TokenTach/README.md:77), [HelpView.swift:126](/Users/george/NorthWolfLabs/TokenTach/TokenTach/HelpView.swift:126), [PRIVACY.md:12](/Users/george/NorthWolfLabs/TokenTach/PRIVACY.md:12)

README says raw email is not retained; Help says raw identities are not saved and broadly describes detailed task telemetry as unsaved. The actual account snapshot retains verified email, and companion snapshots/journals retain the explicitly permitted task summaries. The more detailed privacy policy acknowledges email retention/upload, so the documents disagree about behavior a user may reasonably use to decide whether to enable sharing.

The [privacy-preparation instructions:31](/Users/george/NorthWolfLabs/TokenTach/Distribution/Privacy-Preparation.md:31) also say shared UserDefaults are not used, while [task-selection preferences:147](/Users/george/NorthWolfLabs/TokenTach/Companion/Shared/CompanionLiveState.swift:147) use the App Group defaults suite. Findings 18–20 cover separate promises about controls, deletion, and sharing scope that are not implemented as described.

**Direction:** Derive a concise data inventory from actual storage and transport models, then update README, Help, the privacy policy, and distribution declarations together. Distinguish local-only behavior from optional companion behavior without absolute claims that become false when sharing is enabled.

### 56. Setup and sandbox documentation contradict the current app

**P2 · Source-confirmed.** [README.md:61](/Users/george/NorthWolfLabs/TokenTach/README.md:61), [README.md:111](/Users/george/NorthWolfLabs/TokenTach/README.md:111), [ScopedCodexAccess.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/ScopedCodexAccess.swift), [SettingsView.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/SettingsView.swift)

README says helper discovery is automatic and Settings is needed only as a fallback. The sandboxed app requires persisted user-selected access to the Codex directory and helper. The same README first says “no App Sandbox,” then says the main target uses App Sandbox. Those contradictions obscure both initial setup and troubleshooting.

The selection flow also asks users to locate a hidden data directory and an executable that may live inside an application bundle, without sufficient concrete guidance in the setup surface. A generic file chooser is a difficult recovery mechanism when the user does not know the required location.

**Direction:** Document the actual first-run sequence and grants, supply useful chooser locations/instructions, and keep historical unsandboxed behavior clearly historical. Include how to replace/revoke a saved grant and recover after moving/updating the host app.

### 57. Cross-component state contracts are implicit and spread across large owners

**P3 · Architectural concern.** [LocalSessionMonitor.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift), [AppState.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift), [CompanionStore.swift](/Users/george/NorthWolfLabs/TokenTach/Companion/iOS/CompanionStore.swift), [relay index.ts](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/index.ts), [receiver.ts](/Users/george/NorthWolfLabs/TokenTach/Companion/Relay/src/receiver.ts)

Parsing, discovery scheduling, lifecycle inference, aggregation, storage, connection management, retry decisions, and presentation are concentrated in a few large types. More significantly, the same concepts—freshness, completion, reset evidence, revocation, snapshot ordering, and retry ownership—are implemented independently across Swift and TypeScript. Wire schema version 1 by itself does not document how optional features and recovery behavior evolve.

The defects above are mostly missing invariants between those responsibilities, not evidence that SwiftUI/AppKit/Hono are the wrong choices. Splitting files solely to reduce line counts would not address them.

**Direction:** Extract pure event reduction from filesystem scheduling, transport generations from account requests, and durable delivery decisions from I/O. Document which state is durable, what a restart can lose, who owns each retry, and how older clients degrade. Reuse transition fixtures across implementations.

### 58. A second notification implementation and unused state obscure the real path

**P3 · Source-confirmed.** [NotificationScheduler.swift:70](/Users/george/NorthWolfLabs/TokenTach/TokenTach/NotificationScheduler.swift:70), [AppState.swift:52](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift:52), [TelemetryPolicies.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/TelemetryPolicies.swift)

The scheduler retains older `evaluate(snapshot:)` / `evaluate(conversations:)` logic and its own defaults-based deduplication alongside the active AlertMonitor/outbox delivery path. AppState still has obsolete notification-policy/signature state. Tests of those older entry points can look like production notification coverage even when production uses different logic.

**Direction:** Trace the supported notification API, retire obsolete implementations/state, and move useful behavioral tests onto the real event/outbox path. Preserve migration of any still-relevant persisted keys deliberately.

### 59. Default-unbounded event streams lack an explicit backpressure policy

**P3 · Resource-risk design gap; growth not measured.** [LocalSessionMonitor.swift:124](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:124), [CodexAppServerClient.swift](/Users/george/NorthWolfLabs/TokenTach/TokenTach/CodexAppServerClient.swift)

The asynchronous streams use default buffering rather than a documented bounded policy. If a consumer is suspended on other work while its producer continues yielding snapshots/events, queued values can accumulate. The parser's byte limits do not bound a separate stream queue.

Snapshot streams normally need only the newest state; transition/event streams may need ordered delivery or explicit overflow recovery. Treating both as default-unbounded buffers leaves memory behavior dependent on consumer timing.

**Direction:** Choose buffering per semantic type, coalesce snapshots, and handle dropped events by resynchronizing where necessary. Test a deliberately stalled consumer. This is an identified missing bound, not a measured production leak.

### 60. Silent degradation has no useful diagnostic surface

**P3 · Source-confirmed product/operations gap.** [LocalSessionMonitor.swift:748](/Users/george/NorthWolfLabs/TokenTach/TokenTach/LocalSessionMonitor.swift:748), [AlertMonitor.swift:231](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AlertMonitor.swift:231), [AppState.swift:473](/Users/george/NorthWolfLabs/TokenTach/TokenTach/AppState.swift:473)

Many recoverable failures intentionally use `try?`, but there is no consolidated account/task/notification health view to distinguish parse rejection, read failure, incomplete discovery, stale history, oversized state, or ordinary inactivity. The notification monitor's storage error is not exposed through the normal settings/status presentation. Several failures in this review therefore look like valid zero/empty/stale results to a user.

**Direction:** Add bounded, privacy-preserving counters and last-error categories with observation times and coverage flags. A diagnostics export can contain versions, counts, bounds reached, and sanitized error codes without including prompts, raw task contents, credentials, or personal paths. Make it possible to answer “why is this task missing?” without enabling broad raw logging.

## Suggested order for later work

This is prioritization, not authorization to implement changes.

1. **Restore trustworthy local telemetry:** findings 1–5, then lifecycle handling in 8–12. Add small adversarial fixtures that prove information is preserved across budget and connection boundaries.
2. **Complete the sharing/deletion contract:** findings 18–25 and 55. Verify durable keys and old capabilities after revocation, including offline and lost-response cases.
3. **Repair release evidence:** findings 47–51 and 53. In particular, make the resource workload assert that it is processing accepted telemetry before trusting performance results.
4. **Align freshness and measurement semantics:** findings 14–17, 21–22, and 36–45. Users should be able to distinguish current observation, old evidence, partial coverage, and estimates.
5. **Address bounded-resource and ownership gaps:** findings 13, 26–30, 34–35, 46, and 59. Measure the paths that can become expensive rather than inferring safety from idle behavior.
6. **Reduce future divergence:** findings 54 and 56–60, with shared transition fixtures and clear ownership contracts rather than a wholesale rewrite.

## Probe details and practical limits

The source-exact Swift probes compiled the production monitor/client/store dependencies with synthetic files and an injectable clock. They did not parse the user's Codex files. The helper probe used a tiny local C JSON-RPC peer with delayed initialization, bypassing trust validation only for that isolated fixture. Child processes were stopped at the end.

| Probe | Observed result |
| --- | --- |
| Serial helper initialization control | Identity request succeeded |
| Two overlapping helper initialization requests | Two children launched; neither request completed before the two-second stop |
| Short versus dense rollout | Short: `recent`; dense: `running`, completion absent |
| Token field present versus absent | 100 total tokens versus zero |
| Eight recent files beyond the initial byte budget | Six retained/completed after about 200 accelerated maintenance ticks |
| Atomic 218-byte to 219-byte replacement | Previous `running` state retained; completion absent |
| Start timestamp two hours earlier, no writer lock | Still `running`; fixture also had recent session metadata |
| 1,000 permitted-size pending alert summaries | 610,753-byte encoded state rejected by the 512 KiB store limit |
| Delegate-backed URLSession lifetime | Alive after request/owner release; released after invalidation |
| Relay `fiveMinuteRate: 1e100` | Schema accepted |
| GitHub CLI outside a checkout without explicit repository | Repository inference failed |

The accelerated maintenance probe tests scheduling order and persistence of the loss, not production wall-clock latency. The memory probe tests a Foundation lifetime pattern on macOS, not the magnitude of a device leak. The outbox probe tests encoded size and rejection; the draining failure is established from control flow. Numeric schema acceptance was exercised; the phone itself was not deliberately crashed.

Passing unit/build checks are useful evidence of the supported paths they exercise. They do not cancel the reproduced counterexamples, establish performance budgets, or certify the untested OS/device/signing combinations. Conversely, the risk/design findings should be validated in their stated conditions before spending effort on a large redesign.
