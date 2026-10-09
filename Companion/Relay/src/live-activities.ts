import type { Snapshot } from './protocol';

export interface LiveTaskPreview {
  taskID: string; title: string; project?: string; state: string; tokensPerMinute: number;
  taskObservedAt?: number; startedAt?: number; activity?: string; contextPercent?: number; hasRate: boolean; taskIndex: number;
}
export interface LiveState {
  taskID?: string; title: string; project?: string; state: string;
  running: number; attention: number; tokensPerMinute: number; updatedAt: number;
  taskObservedAt?: number; startedAt?: number; activity?: string; contextPercent?: number; hasRate?: boolean; account?: string; taskIndex?: number; selectionIsPinned?: boolean; nextTask?: LiveTaskPreview; deliveryTimestamp?: number;
}
export interface LiveRecord {
  selectedTaskID?: string; state: LiveState; activityID?: string; token?: string; dismissed?: boolean;
  lastSentAt?: number; lastStartAt?: number; registeredAt?: number; startAttempts?: number;
  lastSignature?: string; lastUpdatePhaseSignature?: string; lastUrgentSignature?: string; lastPhaseSignature?: string; lastPromptSentAt?: number;
  retryAt?: number; attempts?: number; ending?: boolean; foregroundStartUntil?: number; deliveryBlocked?: boolean;
  foregroundMissingAt?: number; foregroundMissingActivityID?: string;
}
export interface LiveMessage { event: 'start' | 'update' | 'end'; state: LiveState; macID: string; macName: string; timestamp: number; dismissImmediately?: boolean }

/** Foreground registry reports can retire an orphaned token after an app update.
 * A grace period protects activity registration from an earlier in-flight report.
 * A person's explicit dismissal must remain authoritative. */
export function liveRecordMissingOnDevice(record: LiveRecord, activeIDs: string[] | undefined, now: number): boolean {
  return activeIDs !== undefined && !record.dismissed && Boolean(record.token && record.activityID)
    && now - (record.registeredAt ?? record.lastStartAt ?? 0) >= 30
    && !activeIDs.includes(record.activityID!);
}

export function nextLiveTaskID(snapshot: Snapshot, afterTaskID?: string): string | undefined {
  const active = snapshot.tasks.filter(t => t.state !== 'completed').sort((a, b) =>
    Number(a.state === 'running') - Number(b.state === 'running')
      || (a.startedAt ?? Number.MAX_VALUE) - (b.startedAt ?? Number.MAX_VALUE) || a.id.localeCompare(b.id));
  const index = active.findIndex(t => t.id === afterTaskID);
  return active.length ? active[(index + 1) % active.length].id : undefined;
}

function short(text: string, max: number): string {
  let result = '';
  for (const part of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)) {
    if (result.length + part.segment.length > max) break;
    result += part.segment;
  }
  return result;
}
export function liveState(snapshot: Snapshot, previousTaskID?: string, selectedTaskID?: string): LiveState {
  const active = snapshot.tasks.filter(t => t.state !== 'completed').sort((a, b) => {
    const priority = Number(a.state === 'running') - Number(b.state === 'running');
    return priority || (a.startedAt ?? Number.MAX_VALUE) - (b.startedAt ?? Number.MAX_VALUE) || a.id.localeCompare(b.id);
  });
  const attention = active.filter(t => t.state === 'needsInput' || t.state === 'needsApproval');
  const candidates = attention.length ? attention : active;
  const first = active.find(t => t.id === selectedTaskID) ?? candidates.find(t => t.id === previousTaskID) ?? candidates[0];
  const nextIndex = first ? (active.indexOf(first) + 1) % active.length : -1;
  const next = active.length > 1 && nextIndex >= 0 ? active[nextIndex] : undefined;
  const nextTask: LiveTaskPreview | undefined = next ? { taskID: next.id, title: short(next.title, 100), project: next.project ? short(next.project, 80) : undefined,
    state: next.state, tokensPerMinute: next.state === 'running' ? next.tokensPerMinute : 0, taskObservedAt: next.observedAt ?? undefined,
    startedAt: next.startedAt ?? undefined, activity: next.activity, contextPercent: next.metrics?.contextIncludesAgent ? undefined : next.contextPercent ?? undefined,
    hasRate: next.hasTokenObservation ?? next.tokensPerMinute > 0, taskIndex: nextIndex } : undefined;
  return { taskID: first?.id, title: short(first?.title ?? 'No active tasks', 100), project: first?.project ? short(first.project, 80) : undefined,
    state: first?.state ?? 'idle', running: active.filter(t => t.state === 'running').length,
    attention: attention.length,
    tokensPerMinute: first?.state === 'running' ? first.tokensPerMinute : 0,
    updatedAt: snapshot.observedAt, taskObservedAt: first?.observedAt ?? undefined,
    startedAt: first?.startedAt ?? undefined, activity: first?.activity, contextPercent: first?.metrics?.contextIncludesAgent ? undefined : first?.contextPercent ?? undefined,
    hasRate: first ? (first.hasTokenObservation ?? (first.tokensPerMinute > 0)) : false,
    account: snapshot.account?.email ? short(snapshot.account.email, 100) : undefined,
    taskIndex: first ? active.findIndex(t => t.id === first.id) : undefined,
    selectionIsPinned: selectedTaskID !== undefined && first?.id === selectedTaskID ? true : undefined, nextTask };
}
export const liveSignature = (state: LiveState) => JSON.stringify([state.taskID, state.title, state.project, state.state, state.running, state.attention, state.startedAt, state.activity, state.contextPercent, state.hasRate, Math.round(state.tokensPerMinute), state.account, state.taskIndex, state.selectionIsPinned, state.nextTask]);
export const liveUrgentSignature = (state: LiveState) => JSON.stringify([state.taskID, state.state, state.running, state.attention, state.startedAt]);
export const livePhaseSignature = (state: LiveState) => JSON.stringify([state.taskID, state.activity]);
/** Phase changes describe current work. Coalesce them to protect the prompt-push budget. */
export function liveDeliveryIsUrgent(record: LiveRecord, now: number, frequentUpdates = false): boolean {
  return record.lastUrgentSignature !== liveUrgentSignature(record.state)
    || record.lastPhaseSignature !== livePhaseSignature(record.state)
      && now - (record.lastPromptSentAt ?? 0) >= (frequentUpdates ? 30 : 60)
    // Low-priority delivery can be deferred even when APNs accepts it. Send a
    // bounded prompt freshness update before the 180-second stale deadline.
    || now - (record.lastPromptSentAt ?? 0) >= 120;
}
export const liveFreshnessInterval = 180;
/** Tell the publisher when a deferred phase or prompt freshness update is due.
 * Numerical updates must not keep moving this deadline into the future. */
export function liveRefreshAfter(record: LiveRecord, now: number, frequentUpdates = false): number | undefined {
  if (record.dismissed || record.deliveryBlocked || record.ending || !record.state.running && !record.state.attention) return;
  if (!record.token) return 120;
  const promptAt = record.lastPromptSentAt ?? now;
  const phaseDue = record.lastPhaseSignature !== livePhaseSignature(record.state) ? promptAt + (frequentUpdates ? 30 : 60) : Infinity;
  return Math.max(5, Math.min(120, Math.min(promptAt + 120, phaseDue) - now));
}
// ActivityKit ends a card after eight hours even if APNs continues accepting
// updates. Renew before that limit; the task's turn clock remains unchanged.
export const liveLifetime = 8 * 60 * 60 - 60;
export function liveNeedsRenewal(record: LiveRecord, now: number): boolean {
  const start = record.lastStartAt ?? record.registeredAt;
  return Boolean(record.token && start !== undefined && now - start >= liveLifetime);
}
export function nextLiveEvent(record: LiveRecord, enabled: boolean, canStart: boolean, now: number, frequentUpdates = false): LiveMessage['event'] | undefined {
  if (record.retryAt && now < record.retryAt) return;
  if ((record.attempts ?? 0) >= 8 || record.dismissed || record.deliveryBlocked) return;
  const active = record.state.running + record.state.attention > 0;
  if (record.token) {
    if (!enabled || record.ending || !active || liveNeedsRenewal(record, now)) return 'end';
    // Never relabel stale observations as fresh just because the alarm ran.
    if (now - record.state.updatedAt > liveFreshnessInterval) return;
    const elapsed = now - (record.lastSentAt ?? 0);
    if (liveDeliveryIsUrgent(record, now, frequentUpdates)) return 'update';
    // Phases are latest-value events; metrics can wait a minute. Keep the
    // separate bounded priority/freshness policy to respect Apple's push budget.
    if ((record.lastUpdatePhaseSignature ?? record.lastPhaseSignature) !== livePhaseSignature(record.state) && elapsed >= 5
      || record.lastSignature !== liveSignature(record.state) && elapsed >= 60
      || elapsed >= 120) return 'update';
    return;
  }
  if (!enabled || !canStart || !active || record.ending || now - record.state.updatedAt > liveFreshnessInterval) return;
  if ((record.foregroundStartUntil ?? 0) > now) return;
  if ((record.startAttempts ?? 0) >= 3 || now - (record.lastStartAt ?? 0) < 90) return;
  return 'start';
}
export function livePayload(message: LiveMessage): string {
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(message.timestamp), event: message.event, 'content-state': { ...message.state, deliveryTimestamp: Math.floor(message.timestamp) },
    'stale-date': Math.floor(message.state.updatedAt + liveFreshnessInterval),
    'relevance-score': message.state.attention ? 100 : 50,
  };
  if (message.event === 'start') {
    aps['attributes-type'] = 'CompanionActivityAttributes';
    aps.attributes = { macID: message.macID, macName: short(message.macName, 80) };
    aps['input-push-token'] = 1;
    aps.alert = { title: 'Tasks on ' + short(message.macName, 80), body: message.state.title };
  } else if (message.event === 'end') {
    // A task monitor has no useful completed/empty card to retain. A past
    // dismissal date removes it as soon as Apple delivers the end event.
    aps['dismissal-date'] = Math.floor(message.timestamp - 1);
    delete aps['stale-date'];
  }
  let payload = JSON.stringify({ aps });
  // Optional acceleration must never exceed ActivityKit's 4 KiB payload limit.
  if (new TextEncoder().encode(payload).byteLength > 4096) {
    delete (aps['content-state'] as LiveState).nextTask;
    payload = JSON.stringify({ aps });
  }
  return payload;
}
