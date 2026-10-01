import { DurableObject } from 'cloudflare:workers';
import { receiverChanges, type AlertEvent } from './alerts';
import { sendPush, sendLivePush, type PushRegistration, type PushResult } from './apns';
import { liveState, liveSignature, liveObservationRecovered, nextLiveEvent, needsLiveAlarm, type LiveRecord } from './live-activities';
import type { Scope, Snapshot } from './protocol';

interface Subscription { scope: Scope; generation: number; revision?: number; kinds: string[]; liveEnabled?: boolean }
interface Pending { event: AlertEvent; attempts: number }
// One object per APNs device token. Account observations from all linked Macs
// meet here so shared allowance changes create one alert, never one per Mac.
export class PushReceiver extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }
  private read<T>(key: string): T | undefined {
    const row = this.ctx.storage.sql.exec<{ value: string }>('SELECT value FROM state WHERE key = ?', key).toArray()[0];
    return row ? JSON.parse(row.value) as T : undefined;
  }
  private write(key: string, value: unknown) {
    this.ctx.storage.sql.exec('INSERT INTO state VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', key, JSON.stringify(value));
  }
  async register(mac: string, device: PushRegistration, scope: Scope, generation: number, revision = 0) {
    const previous = this.read<Subscription>(`subscription:${mac}`);
    if (previous && (previous.generation > generation || (previous.generation === generation && (previous.revision ?? 0) > revision))) return;
    this.write('device', device);
    this.write(`subscription:${mac}`, { scope, generation, revision, kinds: device.kinds, liveEnabled: scope === 'full' && device.liveActivities?.enabled === true });
    // An explicit off/on choice starts a fresh session, even if the previous
    // activity was dismissed. Ordinary registration refreshes preserve dismissal.
    if (previous && !previous.liveEnabled && scope === 'full' && device.liveActivities?.enabled) {
      this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `live:${mac}`);
    }
    this.write('pending', (this.read<Pending[]>('pending') ?? []).filter(p => p.event.macID !== mac || device.kinds.includes(p.event.kind)));
    const snapshot = this.read<Snapshot>(`mac:${mac}`);
    if (snapshot) this.observeLive(snapshot);
    if ((this.read<Pending[]>('pending') ?? []).length || this.liveRecords().length) await this.ctx.storage.setAlarm(Date.now() + 1000);
  }
  async registerLiveActivity(mac: string, generation: number, registration: { activityID: string; activityToken?: string; dismissed?: boolean; ended?: boolean }) {
    const subscription = this.read<Subscription>(`subscription:${mac}`);
    if (subscription?.generation !== generation || subscription.scope !== 'full' || !subscription.liveEnabled) return false;
    const previous = this.read<LiveRecord>(`live:${mac}`);
    const snapshot = this.read<Snapshot>(`mac:${mac}`);
    if (!snapshot) return false;
    if (registration.ended) {
      if (previous?.activityID === registration.activityID) {
        this.write(`live:${mac}`, { state: liveState(snapshot) });
        await this.ctx.storage.setAlarm(Date.now() + 1000);
      }
    } else if (registration.dismissed) {
      if (previous?.activityID === registration.activityID) this.write(`live:${mac}`, { ...previous, dismissed: true, token: undefined });
    } else {
      this.write(`live:${mac}`, { ...previous, state: liveState(snapshot, previous?.state.taskID), activityID: registration.activityID,
        token: registration.activityToken, dismissed: false, attempts: 0, retryAt: undefined, lastSignature: undefined });
      await this.ctx.storage.setAlarm(Date.now() + 1000);
    }
    return true;
  }
  async testNotification(mac: string, generation: number): Promise<PushResult | 'not-registered' | 'rate-limited'> {
    const subscription = this.read<Subscription>(`subscription:${mac}`);
    const device = this.read<PushRegistration>('device');
    if (!device || subscription?.generation !== generation) return 'not-registered';
    const now = Date.now();
    if (now - (this.read<number>('lastTest') ?? 0) < 30_000) return 'rate-limited';
    this.write('lastTest', now);
    try {
      return await sendPush(this.env, device, { id: `test:${crypto.randomUUID()}`, kind: 'completed',
        title: 'Test notification', body: 'Your CodexGauge phone alerts are connected.', at: now / 1000, macID: mac });
    } catch { return 'retry'; }
  }
  async revoke(mac: string, generation?: number, revision?: number) {
    const subscription = this.read<Subscription>(`subscription:${mac}`);
    // Cleanup from an older request must not delete a replacement subscription.
    if (generation !== undefined && subscription?.generation !== generation) return;
    if (revision !== undefined && (subscription?.revision ?? 0) !== revision) return;
    const live = this.read<LiveRecord>(`live:${mac}`), device = this.read<PushRegistration>('device');
    const accountID = this.read<Snapshot>(`mac:${mac}`)?.account?.id;
    this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ? OR key = ?', `subscription:${mac}`, `mac:${mac}`);
    this.write('pending', (this.read<Pending[]>('pending') ?? []).filter(p => p.event.macID !== mac));
    this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `live:${mac}`);
    if (accountID) {
      const remaining = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM state WHERE key LIKE 'mac:%'").toArray();
      if (!remaining.some(row => (JSON.parse(row.value) as Snapshot).account?.id === accountID)) {
        this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `account:${accountID}`);
      }
    }
    if (live?.token && device) {
      try { await sendLivePush(this.env, { ...device, token: live.token }, { event: 'end', macID: mac, macName: '', timestamp: Date.now() / 1000, dismissImmediately: true,
        state: { title: 'Access removed', state: 'idle', running: 0, attention: 0, tokensPerMinute: 0, updatedAt: Date.now() / 1000 } }, true); } catch { /* The system stale date remains the fallback. */ }
    }
    if (!this.ctx.storage.sql.exec("SELECT key FROM state WHERE key LIKE 'subscription:%' LIMIT 1").toArray().length) {
      await this.ctx.storage.deleteAll();
      this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    }
  }
  async observe(snapshot: Snapshot, generation: number) {
    const subscription = this.read<Subscription>(`subscription:${snapshot.id}`);
    if (!subscription || subscription.generation !== generation) return;
    const old = this.read<Snapshot>(`mac:${snapshot.id}`);
    if (old && old.observedAt >= snapshot.observedAt) return;
    const account = snapshot.account;
    const newest = account ? this.read<Snapshot['account']>(`account:${account.id}`) : undefined;
    const result = receiverChanges(old, newest, snapshot);
    const events = result.events.filter(e => subscription.scope === 'full' || !e.taskID);
    this.write(`mac:${snapshot.id}`, snapshot);
    this.observeLive(snapshot);
    if (result.account) this.write(`account:${result.account.id}`, result.account);
    const seen = this.read<string[]>('seen') ?? [];
    let pending = this.read<Pending[]>('pending') ?? [];
    const previousSeen = JSON.stringify(seen), previousPending = JSON.stringify(pending);
    for (const event of events) {
      if (seen.includes(event.id)) continue;
      seen.push(event.id);
      if (subscription.kinds.includes(event.kind)) pending.push({ event, attempts: 0 });
    }
    pending = pending.filter(p => p.event.at > Date.now() / 1000 - 3600).slice(-100);
    if (previousSeen !== JSON.stringify(seen)) this.write('seen', seen.slice(-1000));
    if (previousPending !== JSON.stringify(pending)) {
      this.write('pending', pending);
    }
    if (pending.length || this.liveRecords().length) await this.ctx.storage.setAlarm(Date.now() + 1000);
  }
  async alarm() {
    const device = this.read<PushRegistration>('device');
    if (!device) return;
    await this.deliverLive(device);
    const batch = (this.read<Pending[]>('pending') ?? []).slice(0, 10);
    for (const item of batch) {
      const subscription = this.read<Subscription>(`subscription:${item.event.macID}`);
      if (!subscription?.kinds.includes(item.event.kind)) { this.remove(item.event.id); continue; }
      if (item.event.at < Date.now() / 1000 - 3600 || item.attempts >= 8) { this.remove(item.event.id); continue; }
      try {
        const result = await sendPush(this.env, device, item.event);
        this.write('lastDelivery', { result, at: Date.now() / 1000 });
        if (result === 'accepted' || result === 'rejected' || result === 'configuration-error') this.remove(item.event.id);
        else if (result === 'invalid-token') {
          this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', 'device');
          this.write('pending', []); return;
        } else { this.retry(item.event.id); break; }
      } catch { this.retry(item.event.id); break; }
    }
    const now = Date.now() / 1000;
    const pending = this.read<Pending[]>('pending') ?? [];
    const records = this.liveRecords();
    const enabled = (mac: string) => this.read<Subscription>(`subscription:${mac}`)?.liveEnabled === true;
    const canStart = Boolean(device.liveActivities?.pushToStartToken);
    if (pending.length || records.some(([mac, record]) => needsLiveAlarm(record, enabled(mac), canStart, now))) {
      const immediate = pending.some(item => item.attempts === 0)
        || records.some(([mac, record]) => nextLiveEvent(record, enabled(mac), canStart, now) !== undefined);
      const due = Date.now() + (immediate ? 1000 : 60000);
      // A newer observation may have scheduled an earlier alarm while APNs I/O
      // yielded. Never replace its prompt state transition with our retry delay.
      const scheduled = await this.ctx.storage.getAlarm();
      if (scheduled === null || scheduled > due) await this.ctx.storage.setAlarm(due);
    }
  }
  private liveRecords(): [string, LiveRecord][] {
    return this.ctx.storage.sql.exec<{ key: string; value: string }>("SELECT key, value FROM state WHERE key LIKE 'live:%'").toArray()
      .map(row => [row.key.slice(5), JSON.parse(row.value) as LiveRecord]);
  }
  private observeLive(snapshot: Snapshot) {
    const subscription = this.read<Subscription>(`subscription:${snapshot.id}`);
    const previous = this.read<LiveRecord>(`live:${snapshot.id}`);
    const state = liveState(snapshot, previous?.state.taskID);
    if (!previous && (!subscription?.liveEnabled || !state.running && !state.attention)) return;
    if (previous?.dismissed && !state.running && !state.attention) {
      this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `live:${snapshot.id}`); return;
    }
    if (previous && !previous.token && !state.running && !state.attention) {
      this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `live:${snapshot.id}`); return;
    }
    const now = Date.now() / 1000;
    const recovered = liveObservationRecovered(previous?.state, state, now);
    this.write(`live:${snapshot.id}`, { ...previous, state, ...(recovered ? { lastSignature: undefined } : {}) });
  }
  private async deliverLive(device: PushRegistration) {
    for (const [mac, original] of this.liveRecords()) {
      const subscription = this.read<Subscription>(`subscription:${mac}`);
      if (!subscription) continue;
      const now = Date.now() / 1000;
      const event = nextLiveEvent(original, subscription.liveEnabled === true, Boolean(device.liveActivities?.pushToStartToken), now);
      if (!event) continue;
      const token = event === 'start' ? device.liveActivities?.pushToStartToken : original.token;
      if (!token) continue;
      const urgent = original.lastSignature !== liveSignature(original.state);
      // Reserve a start before network I/O; a new observation cannot send another.
      if (event === 'start') this.write(`live:${mac}`, { ...original, lastStartAt: now, startAttempts: (original.startAttempts ?? 0) + 1 });
      let result: PushResult;
      try {
        result = await sendLivePush(this.env, { ...device, token }, { event, state: original.state, macID: mac,
          // APNs orders delivery by this timestamp. Observation age remains in
          // content-state/stale-date; a Mac clock offset must not make a later
          // server end appear older than its preceding update.
          macName: this.read<Snapshot>(`mac:${mac}`)?.name ?? 'Mac', timestamp: now,
          dismissImmediately: event === 'end' && subscription.liveEnabled !== true }, urgent);
      } catch { result = 'retry'; }
      const current = this.read<LiveRecord>(`live:${mac}`);
      if (!current || (event !== 'start' && current.token !== original.token)) continue;
      if (result === 'accepted') {
        if (event === 'end') {
          // A new task can arrive during APNs I/O. The old activity has ended,
          // but keep the newer state so it can start a replacement activity.
          if (current.state.updatedAt > original.state.updatedAt && current.state.running + current.state.attention > 0) {
            this.write(`live:${mac}`, { state: current.state });
          } else this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', `live:${mac}`);
        }
        else this.write(`live:${mac}`, { ...current, lastSentAt: now, lastSignature: liveSignature(original.state), attempts: 0, retryAt: undefined });
      } else if (result === 'invalid-token' && event === 'update') {
        // Activity tokens expire independently of the app's push-to-start token.
        // A fresh start can recover a system-ended activity for a long task.
        this.write(`live:${mac}`, { state: current.state });
      } else if (['invalid-token', 'configuration-error', 'rejected'].includes(result)) {
        this.write(`live:${mac}`, { ...current, dismissed: true, token: undefined });
      } else this.write(`live:${mac}`, { ...current, attempts: (current.attempts ?? 0) + 1, retryAt: now + 60 });
    }
  }
  private remove(id: string) { this.write('pending', (this.read<Pending[]>('pending') ?? []).filter(p => p.event.id !== id)); }
  private retry(id: string) { this.write('pending', (this.read<Pending[]>('pending') ?? []).map(p => p.event.id === id ? { ...p, attempts: p.attempts + 1 } : p)); }
}
