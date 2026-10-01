import type { Snapshot } from './protocol';
export type AlertKind = 'low' | 'allowance' | 'banked' | 'working' | 'attention' | 'completed';
export interface AlertEvent { id: string; kind: AlertKind; title: string; body: string; at: number; macID: string; taskID?: string }

// Persist immediately for alert-relevant changes, otherwise checkpoint at 30 s.
// Token-rate ticks still stream live without a database write for every frame.
export function alertSignature(snapshot: Snapshot): string {
  return JSON.stringify({ account: snapshot.account && {
    id: snapshot.account.id, windows: snapshot.account.windows, banked: snapshot.account.bankedResets,
  }, tasks: snapshot.tasks.map(t => [t.id, t.state, t.eventAt, t.startedAt]) });
}

export function receiverChanges(old: Snapshot | undefined, newest: Snapshot['account'], snapshot: Snapshot) {
  if (old && old.observedAt >= snapshot.observedAt) return { events: [] as AlertEvent[], account: null };
  const account = snapshot.account && (!newest || snapshot.account.observedAt > newest.observedAt) ? snapshot.account : null;
  const before = old ? { ...old, account: newest ?? old.account } : undefined;
  return { events: changes(before, { ...snapshot, account }), account };
}

// Baseline the first observation. An absent/idle task is never completion evidence.
export function changes(before: Snapshot | undefined, after: Snapshot): AlertEvent[] {
  if (!before) return [];
  const result: AlertEvent[] = [], now = after.observedAt;
  const catchUp = now - before.observedAt > 90;
  const context = catchUp ? `\nObserved between ${new Date(before.observedAt * 1000).toISOString()} and ${new Date(now * 1000).toISOString()}.` : '';
  const event = (id: string, kind: AlertKind, title: string, body: string, taskID?: string) => {
    result.push({ id, kind, title, body: body + context, at: now, macID: after.id, taskID });
  };
  for (const task of after.tasks) {
    const old = before.tasks.find(t => t.id === task.id);
    if (old?.state === task.state && old?.eventAt === task.eventAt && old?.startedAt === task.startedAt) continue;
    // Newly discovered historical tasks aren't fresh completions/input requests.
    if (!old && task.state !== 'running' && (!task.eventAt || task.eventAt < before.observedAt)) continue;
    if (task.state === 'completed' && !task.eventAt) continue;
    const kind = task.state === 'running' ? 'working' : task.state === 'completed' ? 'completed' : 'attention';
    const title = task.state === 'needsApproval' ? 'Approval needed' : task.state === 'needsInput' ? 'Input needed' : task.state === 'running' ? 'Task working' : 'Task completed';
    const key = `task:${after.id}:${task.id}:${task.state}:${task.eventAt ?? task.startedAt ?? now}`;
    event(key, kind, title, `${task.title}${task.project ? `\n${task.project}` : ''}\n${after.name}`, task.id);
  }
  const a = before.account, b = after.account;
  if (a && b && a.id === b.id && b.observedAt > a.observedAt) {
    for (const window of b.windows) {
      const old = a.windows.find(w => w.id === window.id);
      if (!old) continue;
      if (window.remainingPercent <= 10 && old.remainingPercent > 10) {
        event(`low:${b.id}:${window.id}:${window.resetsAt ?? 0}:10`, 'low', `${window.name} running low`, `${window.remainingPercent}% remaining`);
      }
      if (old.resetsAt && window.resetsAt && old.resetsAt <= b.observedAt && window.resetsAt > old.resetsAt && window.resetsAt > b.observedAt) {
        event(`reset:${b.id}:${window.id}:${window.resetsAt}`, 'allowance', `${window.name} reset`, `${window.remainingPercent}% remaining`);
      }
    }
    if (a.bankedResets != null && b.bankedResets != null && b.bankedResets > a.bankedResets) {
      // Same count transition observed by several Macs uses a shared account key.
      event(`banked:${b.id}:${a.bankedResets}:${b.bankedResets}:${b.observedAt}`, 'banked', 'Banked reset added', `+${b.bankedResets - a.bankedResets} · ${b.bankedResets} available`);
    }
  }
  return result;
}
