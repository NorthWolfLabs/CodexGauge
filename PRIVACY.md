# Privacy

CodexGauge reads Codex activity locally. It has no analytics SDK, advertising SDK, or account login of its own. The development iPhone companion can publish usage and task state to an explicitly configured Cloudflare relay, as described below. Companion publishing is off until configured.

## Data read

- Saved local Codex project names, roots, and task associations, used to label task alerts.

- Account identity type, plan, allowances, reset metadata, earned reset count, and aggregate activity returned by the installed Codex app server.
- Local task identifiers and parent links, task names from the local index, workspace, model, timestamps, lifecycle state, token counters, context-window size, turn duration, and response-start latency.

CodexGauge does not model or retain prompts, answers, reasoning, command output, tool content, Codex credentials, Codex authentication tokens, or app-server stderr. Account IDs and account emails returned by the helper are used transiently to derive a locally salted account fingerprint for reset detection. Raw account IDs are not persisted or uploaded. The verified account email is retained with the account snapshot and included in companion snapshots so linked viewers can identify which account their limits and activity belong to. Email fingerprints are a fallback for personal accounts only.

## Data stored

CodexGauge stores preferences, hashes and allowance-cycle keys needed to avoid duplicate notifications, and the last successful account snapshot in the user’s Application Support directory. Local monitoring does not persist raw task identifiers or detailed task telemetry. Pending task alerts retain up to 200 characters each of the task title and associated project name until delivery. Saved local Codex project metadata supplies the project label; projectless or unknown associations have no label. Salted task-identifier hashes and event timestamps are persisted for notification deduplication. A versioned notification outbox holds pending event summaries and local delivery acknowledgements. The optional companion additionally stores the bounded snapshots described below.

## Notifications

Apple notifications are delivered by macOS Notification Center only when enabled. Working, attention, and completion notifications include task and associated project names. Notification permission can be revoked in System Settings.

Failed deliveries remain locally queued and retry after temporary errors. Catch-up reports only resets detectable from snapshots and available reset-credit metadata, never a complete historical event log. If account continuity cannot be established, cross-restart catch-up is withheld rather than mixing accounts.

## App updates

Configured release builds use Sparkle to check an HTTPS update feed and download signed updates. Automatic checks are off by default and can be enabled in Settings; installation requires the user’s choice. The update host receives ordinary request metadata such as the IP address and app/OS version. Sparkle system-profile reporting is disabled. No Codex usage, task data, or credentials are sent by the updater. Development and beta builds do not start it, and no public update feed is configured yet.

## Local-only limitations

Task activity is discovered from files and locks on the current Mac. Tasks that run only on another computer are not visible. Account allowances and aggregate account activity can still include usage from elsewhere when the Codex service reports it.

## Optional iPhone companion (development)

When enabled, the Mac sends its name, observation times, a hashed account identifier, verified account email and account type, plan, allowances and reset dates, banked reset count, available credit balances, aggregate token history, and up to 200 task summaries to the configured relay. A task summary includes its installation-scoped hashed identifier, title, project name, lifecycle state, activity label, token statistics, context percentage, timestamps, and linked-agent count. It excludes workspace paths, prompts, responses, commands, credentials, and raw account/task IDs. A stable account hash lets several Macs identify the same allowance; it is pseudonymous, not anonymous.

The relay persists its latest snapshots, hashed access credentials, device subscriptions, deduplication IDs, and pending notification summaries in Cloudflare Durable Objects. The iPhone caches snapshots in its protected app-group container for widgets. Publisher/read credentials stay in Keychain; the app and widget share only read credentials. A full viewing link exposes task and project names, which may contain personal information. A usage-only link excludes tasks. Treat either link as a secret. Replacing the Mac's links revokes relay viewing access and subscriptions; it cannot erase copies previously received by viewers. Turning publishing off pauses updates and leaves the last stored snapshot available to existing viewers.

Connections use TLS in deployment; local DEBUG fixtures allow loopback HTTP. This is not end-to-end encryption: the relay operator can access stored summaries. Cloudflare also receives connection metadata. APNs receives device tokens and selected alert titles/bodies, including task/project names for task alerts. When Live Activities are enabled, APNs also receives the activity state (task/project title, Mac name, working/waiting counts and throughput). The relay retains ActivityKit push-to-start and per-activity tokens, the latest activity state and bounded retry/dismissal metadata for the subscription. The phone keeps its five-minute throughput samples in memory only. Unlinking removes the corresponding relay activity record and ends the local activity; revocation requests a best-effort sanitized end push. Already displayed copies cannot be recalled with certainty. Device tokens are retained for subscriptions; pending alerts expire after one hour and retry at most eight times. Stale snapshots remain until replaced or until the publisher chooses **Disconnect and delete relay data**. That removes the Mac's feed and subscriptions; when a phone has no remaining subscriptions its receiver state is deleted too. Development builds use the North Wolf Labs development relay; production distribution is not enabled yet.

The phone cannot send commands to the Mac. Its requests only read snapshots and manage its own relay notification subscription. Optional sharing has no user-account directory or public topic listing. Usage-only viewing links also disclose the verified account email; share them only with people you want to see that identity and your usage.
