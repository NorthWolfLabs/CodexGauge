# Privacy

CodexGauge is a local, read-only macOS utility. It has no analytics SDK, advertising SDK, account system, backend, or telemetry upload.

## Data read

- Account identity type, plan, allowances, reset metadata, earned reset count, and aggregate activity returned by the installed Codex app server.
- Local task identifiers and parent links, task names from the local index, workspace, model, timestamps, lifecycle state, token counters, context-window size, turn duration, and response-start latency.

CodexGauge does not model or retain prompts, answers, reasoning, command output, tool content, email addresses, credentials, authentication tokens, or app-server stderr.

## Data stored

CodexGauge stores preferences, hashes and allowance-cycle keys needed to avoid duplicate notifications, and the last successful account snapshot in the user’s Application Support directory. It does not persist task identifiers or task telemetry.

## Notifications

Notifications are delivered by macOS Notification Center only when enabled. Attention notifications use generic text and do not include task names. Notification permission can be revoked in System Settings.

## Local-only limitations

Task activity is discovered from files and locks on the current Mac. Tasks that run only on another computer are not visible. Account allowances and aggregate account activity can still include usage from elsewhere when the Codex service reports it.
