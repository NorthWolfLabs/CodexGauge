import type { Snapshot } from './protocol';

export interface LiveState {
  taskID?: string; title: string; project?: string; state: string;
  running: number; attention: number; tokensPerMinute: number; updatedAt: number;
  taskObservedAt?: number; startedAt?: number; activity?: string; contextPercent?: number; hasRate?: boolean;
}
export interface LiveRecord {
  state: LiveState; activityID?: string; token?: string; dismissed?: boolean;
  lastSentAt?: number; lastStartAt?: number; startAttempts?: number;
  lastSignature?: string; retryAt?: number; attempts?: number; ending?: boolean;
}
export interface LiveMessage { event: 'start' | 'update' | 'end'; state: LiveState; macID: string; macName: string; timestamp: number; dismissImmediately?: boolean }

function short(text: string, max: number): string {
  let result = '';
  for (const part of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)) {
    if (result.length + part.segment.length > max) break;
    result += part.segment;
  }
  return result;
}
export function liveState(snapshot: Snapshot, previousTaskID?: string): LiveState {
  const active = snapshot.tasks.filter(t => t.state !== 'completed').sort((a, b) => {
    const priority = Number(a.state === 'running') - Number(b.state === 'running');
    return priority || (a.startedAt ?? Number.MAX_VALUE) - (b.startedAt ?? Number.MAX_VALUE) || a.id.localeCompare(b.id);
  });
  const attention = active.filter(t => t.state === 'needsInput' || t.state === 'needsApproval');
  const candidates = attention.length ? attention : active;
  const first = candidates.find(t => t.id === previousTaskID) ?? candidates[0];
  return { taskID: first?.id, title: short(first?.title ?? 'No active tasks', 100), project: first?.project ? short(first.project, 80) : undefined,
    state: first?.state ?? 'idle', running: active.filter(t => t.state === 'running').length,
    attention: attention.length,
    tokensPerMinute: active.filter(t => t.state === 'running').reduce((sum, t) => sum + t.tokensPerMinute, 0),
    updatedAt: snapshot.observedAt, taskObservedAt: first?.observedAt ?? undefined,
    startedAt: first?.startedAt ?? undefined, activity: first?.activity, contextPercent: first?.metrics?.contextIncludesAgent ? undefined : first?.contextPercent ?? undefined,
    hasRate: active.filter(t => t.state === 'running').every(t => (t.hasTokenObservation ?? (t.tokensPerMinute > 0))) };
}
export const liveSignature = (state: LiveState) => JSON.stringify([state.taskID, state.title, state.project, state.state, state.running, state.attention, state.startedAt, state.activity, state.contextPercent, state.hasRate]);
export function liveObservationRecovered(previous: LiveState | undefined, current: LiveState, now: number): boolean {
  const expires = (state: LiveState) => Math.min(state.updatedAt, state.taskObservedAt ?? state.updatedAt) + 90;
  return previous !== undefined && expires(previous) < now && expires(current) >= now;
}
export function needsLiveAlarm(record: LiveRecord, enabled: boolean, canStart: boolean, now: number): boolean {
  if (record.dismissed || (record.attempts ?? 0) >= 8) return false;
  if (record.token && (!enabled || record.ending || !record.state.running && !record.state.attention)) return true;
  if (now - record.state.updatedAt > 90) return false;
  return Boolean(record.token || enabled && canStart && record.state.running + record.state.attention > 0 && (record.startAttempts ?? 0) < 3);
}
export function nextLiveEvent(record: LiveRecord, enabled: boolean, canStart: boolean, now: number): LiveMessage['event'] | undefined {
  if (record.retryAt && now < record.retryAt) return;
  if ((record.attempts ?? 0) >= 8 || record.dismissed) return;
  const active = record.state.running + record.state.attention > 0;
  if (record.token) {
    if (!enabled || record.ending || !active) return 'end';
    // Never relabel stale observations as fresh just because the alarm ran.
    if (now - record.state.updatedAt > 90) return;
    if (record.lastSignature !== liveSignature(record.state) || now - (record.lastSentAt ?? 0) >= 60) return 'update';
    return;
  }
  if (!enabled || !canStart || !active || record.ending || now - record.state.updatedAt > 90) return;
  if ((record.startAttempts ?? 0) >= 3 || now - (record.lastStartAt ?? 0) < 90) return;
  return 'start';
}
export function livePayload(message: LiveMessage): string {
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(message.timestamp), event: message.event, 'content-state': message.state,
    'stale-date': Math.floor(Math.min(message.state.updatedAt, message.state.taskObservedAt ?? message.state.updatedAt) + 90),
    'relevance-score': message.state.attention ? 100 : 50,
  };
  if (message.event === 'start') {
    aps['attributes-type'] = 'CompanionActivityAttributes';
    aps.attributes = { macID: message.macID, macName: short(message.macName, 80) };
    aps['input-push-token'] = 1;
    aps.alert = { title: 'Tasks on ' + short(message.macName, 80), body: message.state.title };
  } else if (message.event === 'end') {
    aps['dismissal-date'] = Math.floor(message.timestamp + (message.dismissImmediately ? -1 : 60));
    delete aps['stale-date'];
  }
  return JSON.stringify({ aps });
}
