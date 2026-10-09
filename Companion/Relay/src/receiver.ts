import { DurableObject } from 'cloudflare:workers';
import { receiverChanges, notificationSignature, accountAlertSignature, compactSnapshot } from './alerts';
import type { PushRegistration, PushResult } from './apns';
import { liveState, nextLiveTaskID, liveRecordMissingOnDevice, liveSignature, liveUrgentSignature, livePhaseSignature, liveDeliveryIsUrgent, liveRefreshAfter, liveNeedsRenewal, nextLiveEvent, type LiveRecord } from './live-activities';
import type { Delivery } from './delivery';
import type { Scope, Snapshot } from './protocol';

interface Subscription { scope: Scope; generation: number; revision?: number; kinds: string[]; liveEnabled?: boolean }

// One inbox per push device still deduplicates account events across Macs. Live
// measurements are an evictable cache; only semantic baselines, lifecycle state,
// and important deliveries are durable. APNs never runs inside this object.
export class PushReceiverV2 extends DurableObject<Env> {
  private memory = new Map<string, unknown>();
  private stored = new Map<string, string | undefined>();
  private counters = { observations: 0, writes: 0, metrics: 0, durable: 0, alarms: 0 };
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }
  private read<T>(key: string): T | undefined {
    if (!this.memory.has(key)) {
      const row = this.ctx.storage.sql.exec<{ value: string }>('SELECT value FROM state WHERE key = ?', key).toArray()[0];
      this.stored.set(key, row?.value);
      this.memory.set(key, row ? JSON.parse(row.value) : undefined);
    }
    return this.memory.get(key) as T | undefined;
  }
  private write(key: string, value: unknown) {
    const encoded = JSON.stringify(value);
    if (!this.stored.has(key)) this.read(key);
    this.memory.set(key, value);
    if (encoded === this.stored.get(key)) return;
    this.ctx.storage.sql.exec('INSERT INTO state VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', key, encoded);
    this.stored.set(key, encoded); this.counters.writes++;
  }
  private forget(key: string) {
    this.ctx.storage.sql.exec('DELETE FROM state WHERE key = ?', key);
    this.memory.delete(key); this.stored.delete(key); this.counters.writes++;
  }
  private records(): [string, LiveRecord][] {
    const keys = new Set(this.ctx.storage.sql.exec<{ key: string }>("SELECT key FROM state WHERE key LIKE 'live:%'").toArray().map(r => r.key));
    for (const key of this.memory.keys()) if (key.startsWith('live:') && this.memory.get(key)) keys.add(key);
    return [...keys].map(key => [key.slice(5), this.read<LiveRecord>(key)!]);
  }
  private queue(): Delivery[] { return this.read<Delivery[]>('outbox') ?? []; }
  private subscription(mac: string) { return this.read<Subscription>('subscription:' + mac); }
  private async schedule() {
    const queue = this.queue();
    const next = queue.length ? Math.min(...queue.map(j => Math.max(j.due, j.leaseUntil ?? 0))) * 1000 : null;
    const current = await this.ctx.storage.getAlarm();
    if (next === null) { if (current !== null) await this.ctx.storage.deleteAlarm(); }
    else if (current === null || Math.abs(current - next) > 50) await this.ctx.storage.setAlarm(Math.max(Date.now() + 100, next));
  }
  private liveRecord(mac: string) { return this.read<LiveRecord>('live:' + mac); }
  private observeLive(snapshot: Snapshot) {
    const key = 'live:' + snapshot.id, previous = this.liveRecord(snapshot.id);
    const subscription = this.subscription(snapshot.id);
    const state = liveState(snapshot, previous?.state.taskID, previous?.selectedTaskID);
    if (!previous && (!subscription?.liveEnabled || !state.running && !state.attention)) return;
    if (previous && (previous.dismissed || !previous.token) && !state.running && !state.attention) { this.forget(key); return; }
    const record = { ...previous, state };
    if (!previous || liveUrgentSignature(previous.state) !== liveUrgentSignature(state)) this.write(key, record);
    else this.memory.set(key, record);
  }
  private observe(snapshot: Snapshot, generation: number) {
    const subscription = this.subscription(snapshot.id);
    if (!subscription || subscription.generation !== generation) return;
    const key = 'mac:' + snapshot.id, old = this.read<Snapshot>(key);
    if (old && old.observedAt >= snapshot.observedAt) return;
    this.counters.observations++;
    const newest = snapshot.account ? this.read<Snapshot['account']>('account:' + snapshot.account.id) : undefined;
    const result = receiverChanges(old, newest, snapshot);
    if (!old || notificationSignature(old) !== notificationSignature(snapshot)) this.write(key, snapshot);
    else this.memory.set(key, snapshot);
    this.observeLive(snapshot);
    if (result.account) {
      const accountKey = 'account:' + result.account.id;
      if (accountAlertSignature(newest) !== accountAlertSignature(result.account)) this.write(accountKey, result.account);
      else this.memory.set(accountKey, result.account);
    }
    const seen = this.read<string[]>('seen') ?? [], jobs = this.queue().slice();
    let changed = false;
    const device = this.read<PushRegistration>('device');
    for (const event of result.events) {
      if (seen.includes(event.id) || subscription.scope !== 'full' && event.taskID) continue;
      seen.push(event.id); changed = true;
      if (device && subscription.kinds.includes(event.kind)) jobs.push({
        ...this.job(snapshot.id, device), alert: event, durable: true, expires: event.at + 3600,
      });
    }
    if (changed) { this.write('seen', seen.slice(-1000)); this.write('outbox', jobs.slice(-100)); }
  }
  private job(mac: string, device: PushRegistration): Delivery {
    const subscription = this.subscription(mac), now = Date.now() / 1000;
    return { id: crypto.randomUUID(), attemptID: '', mac, generation: subscription?.generation ?? 0,
      revision: subscription?.revision ?? 0, device, urgent: true, durable: false, attempts: 0, due: now, expires: now + 180 };
  }
  private queueLifecycle() {
    const device = this.read<PushRegistration>('device');
    if (!device) return;
    // A newer semantic state supersedes an undelivered Live Activity update.
    // Never replay "needs approval" after completion or against a replaced token.
    const jobs = this.queue().filter(job => {
      if (job.live?.event !== 'update') return true;
      const current = this.liveRecord(job.mac);
      return current?.token === job.device.token && liveUrgentSignature(current.state) === liveUrgentSignature(job.live.state);
    }), now = Date.now() / 1000;
    for (const [mac, record] of this.records()) {
      const subscription = this.subscription(mac);
      if (!subscription || jobs.some(j => j.mac === mac && j.live && j.durable)) continue;
      const event = nextLiveEvent(record, subscription.liveEnabled === true, Boolean(device.liveActivities?.pushToStartToken), now, device.liveActivities?.frequentUpdates === true);
      if (!event || event === 'update' && record.lastUrgentSignature === liveUrgentSignature(record.state)) continue;
      const token = event === 'start' ? device.liveActivities?.pushToStartToken : record.token;
      if (!token) continue;
      const job = this.job(mac, { ...device, token });
      job.live = { event, state: record.state, macID: mac, macName: this.read<Snapshot>('mac:' + mac)?.name ?? 'Mac', timestamp: now,
        dismissImmediately: event === 'end' && (!subscription.liveEnabled || liveNeedsRenewal(record, now)) };
      job.durable = true;
      // Important task transitions must also survive the Mac going away.
      // Phase/rate/freshness updates take the replaceable path in prepare().
      job.expires = now + (event === 'end' ? 3600 : 180);
      jobs.push(job);
      if (event === 'start') this.write('live:' + mac, { ...record, lastStartAt: now, startAttempts: (record.startAttempts ?? 0) + 1 });
    }
    this.write('outbox', jobs);
  }
  async register(mac: string, device: PushRegistration, scope: Scope, generation: number, revision = 0) {
    const previous = this.subscription(mac);
    if (previous && (previous.generation > generation || previous.generation === generation && (previous.revision ?? 0) > revision)) return;
    this.write('device', device);
    this.write('subscription:' + mac, { scope, generation, revision, kinds: device.kinds, liveEnabled: scope === 'full' && device.liveActivities?.enabled === true });
    // Refreshing preferences invalidates old in-flight jobs. Current state and
    // events in the outbox are retained with the new authorization revision.
    this.write('outbox', this.queue().filter(j => j.mac !== mac || !j.alert || device.kinds.includes(j.alert.kind)).map(j => j.mac === mac ? { ...j, generation, revision, leaseUntil: undefined, attemptID: '' } : j));
    if (previous && !previous.liveEnabled && scope === 'full' && device.liveActivities?.enabled) this.forget('live:' + mac);
    const live = this.liveRecord(mac);
    if (scope === 'full' && device.liveActivities?.enabled && live && liveRecordMissingOnDevice(live, device.liveActivities.activeActivityIDs, Date.now() / 1000)) {
      this.write('live:' + mac, { state: live.state, selectedTaskID: live.selectedTaskID });
      this.write('outbox', this.queue().filter(j => j.mac !== mac || !j.live));
    }
    const snapshot = this.read<Snapshot>('mac:' + mac);
    if (snapshot) this.observeLive(snapshot);
    this.queueLifecycle(); await this.schedule();
  }
  async reserveForegroundStart(mac: string, generation: number, revision: number, registry?: string[]) {
    const subscription = this.subscription(mac);
    let record = this.liveRecord(mac);
    const now = Date.now() / 1000;
    const result = { foregroundStartAllowed: false, foregroundStartRetry: false, foregroundStartDismissed: record?.dismissed === true };
    if (subscription?.generation !== generation || subscription.revision !== revision || subscription.scope !== 'full' || !subscription.liveEnabled
      || !record || record.dismissed || record.ending || !record.state.running && !record.state.attention) return result;
    // Only a foreground registry explicitly reporting no card may request one.
    // A fresh token or another reservation is protected against racing requests.
    if (!registry || registry.length || (record.foregroundStartUntil ?? 0) > now
      || now - record.state.updatedAt > 180) return { ...result, foregroundStartRetry: true };
    if (record.token) {
      // A fresh token may race an earlier registry report. Confirm absence in
      // two foreground reports rather than making an app update wait 30 seconds.
      // A token registration between them resets this confirmation.
      if (record.foregroundMissingActivityID !== record.activityID || record.foregroundMissingAt === undefined) {
        this.write('live:' + mac, { ...record, foregroundMissingActivityID: record.activityID, foregroundMissingAt: now });
        return { ...result, foregroundStartRetry: true, foregroundStartRetrySoon: true };
      }
      if (now - record.foregroundMissingAt < 1) return { ...result, foregroundStartRetry: true, foregroundStartRetrySoon: true };
      record = { state: record.state, selectedTaskID: record.selectedTaskID };
      this.write('outbox', this.queue().filter(j => j.mac !== mac || !j.live));
    }
    this.write('live:' + mac, { ...record, foregroundStartUntil: now + 15 });
    this.write('outbox', this.queue().filter(j => j.mac !== mac || j.live?.event !== 'start'));
    await this.schedule();
    return { ...result, foregroundStartAllowed: true };
  }
  async registerLiveActivity(mac: string, generation: number, registration: { activityID: string; activityToken?: string; dismissed?: boolean; ended?: boolean; selectedTaskID?: string }) {
    const subscription = this.subscription(mac), previous = this.liveRecord(mac), snapshot = this.read<Snapshot>('mac:' + mac);
    if (subscription?.generation !== generation || subscription.scope !== 'full' || !subscription.liveEnabled || !snapshot) return false;
    if (registration.ended || registration.dismissed) {
      if (previous?.activityID === registration.activityID) {
        this.write('live:' + mac, registration.dismissed ? { ...previous, dismissed: true, token: undefined }
          : { state: liveState(snapshot, previous.state.taskID, previous.selectedTaskID), selectedTaskID: previous.selectedTaskID });
        this.write('outbox', this.queue().filter(j => j.mac !== mac || !j.live));
      }
    } else {
      const selectedTaskID = registration.selectedTaskID ?? previous?.selectedTaskID;
      this.write('live:' + mac, { ...previous, selectedTaskID, state: liveState(snapshot, previous?.state.taskID, selectedTaskID),
        activityID: registration.activityID, token: registration.activityToken,
        registeredAt: previous?.activityID === registration.activityID ? previous.registeredAt ?? Date.now() / 1000 : Date.now() / 1000,
        lastStartAt: previous?.activityID === undefined || previous.activityID === registration.activityID ? previous?.lastStartAt : undefined,
        dismissed: false, deliveryBlocked: undefined, foregroundStartUntil: undefined, foregroundMissingAt: undefined, foregroundMissingActivityID: undefined,
        attempts: 0, retryAt: undefined, lastSignature: undefined });
      this.write('outbox', this.queue().filter(j => j.mac !== mac || !j.live));
    }
    this.queueLifecycle(); await this.schedule(); return true;
  }
  async selectLiveActivity(mac: string, generation: number, activityID: string, afterTaskID?: string, fresh?: Snapshot) {
    if (fresh) this.observe(compactSnapshot(fresh), generation);
    const subscription = this.subscription(mac), record = this.liveRecord(mac), snapshot = this.read<Snapshot>('mac:' + mac);
    if (subscription?.generation !== generation || subscription.scope !== 'full' || !subscription.liveEnabled || !record || record.dismissed
      || record.activityID !== activityID || !snapshot || Date.now() / 1000 - snapshot.observedAt > 180) return;
    const selectedTaskID = nextLiveTaskID(snapshot, afterTaskID);
    if (!selectedTaskID) return;
    const state = liveState(snapshot, record.state.taskID, selectedTaskID);
    this.write('live:' + mac, { ...record, selectedTaskID, state, lastSignature: undefined });
    // The phone applies this state immediately. The next Mac push batch supplies
    // future updates; this selection does not start a server polling loop.
    return state;
  }
  async testNotification(mac: string, generation: number): Promise<'queued' | 'not-registered' | 'rate-limited'> {
    const device = this.read<PushRegistration>('device');
    if (!device || this.subscription(mac)?.generation !== generation) return 'not-registered';
    const now = Date.now() / 1000;
    if (now - (this.read<number>('lastTest') ?? 0) < 30) return 'rate-limited';
    this.write('lastTest', now);
    this.write('outbox', [...this.queue(), { ...this.job(mac, device), durable: true, expires: now + 3600,
      alert: { id: 'test:' + crypto.randomUUID(), kind: 'completed', title: 'Test notification', body: 'Your TokenTach phone alerts are connected.', at: now, macID: mac } }]);
    await this.schedule(); return 'queued';
  }
  async revoke(mac: string, generation?: number, revision?: number) {
    const subscription = this.subscription(mac);
    if (generation !== undefined && subscription?.generation !== generation || revision !== undefined && (subscription?.revision ?? 0) !== revision) return;
    const live = this.liveRecord(mac), device = this.read<PushRegistration>('device');
    const jobs = this.queue().filter(j => j.mac !== mac);
    if (live?.token && device) {
      jobs.push({ ...this.job(mac, { ...device, token: live.token }), durable: true, revoked: true, expires: Date.now() / 1000 + 3600,
        live: { event: 'end', macID: mac, macName: '', timestamp: Date.now() / 1000, dismissImmediately: true,
          state: { title: 'Access removed', state: 'idle', running: 0, attention: 0, tokensPerMinute: 0, updatedAt: Date.now() / 1000 } } });
    }
    this.write('outbox', jobs);
    this.forget('subscription:' + mac); this.forget('mac:' + mac); this.forget('live:' + mac);
    await this.schedule();
  }
  async prepareBatch(observations: Snapshot[], generation: number) {
    const deliveries = await this.prepare(observations, generation);
    const mac = observations.at(-1)?.id, device = this.read<PushRegistration>('device');
    const record = mac ? this.liveRecord(mac) : undefined;
    if (!mac || !record || !this.subscription(mac)?.liveEnabled) return { deliveries };
    // This request will deliver the returned jobs before acknowledging the Mac.
    // Derive the next deadline in the same RPC; no extra database write or alarm.
    const prompt = deliveries.find(job => job.mac === mac && job.live && job.urgent);
    const next = prompt?.live ? { ...record, lastPromptSentAt: prompt.live.timestamp, lastPhaseSignature: livePhaseSignature(prompt.live.state) } : record;
    return { deliveries, refreshAfter: liveRefreshAfter(next, Date.now() / 1000, device?.liveActivities?.frequentUpdates === true) };
  }
  async prepare(observations: Snapshot[], generation: number): Promise<Delivery[]> {
    for (const snapshot of observations) this.observe(compactSnapshot(snapshot), generation);
    this.queueLifecycle();
    const jobs = await this.claimPending();
    const device = this.read<PushRegistration>('device'), now = Date.now() / 1000;
    if (!device) return jobs;
    for (const snapshot of observations.slice(-1)) {
      const record = this.liveRecord(snapshot.id), subscription = this.subscription(snapshot.id);
      if (!record || !subscription || this.queue().some(j => j.mac === snapshot.id && j.live)) continue;
      const event = nextLiveEvent(record, subscription.liveEnabled === true, Boolean(device.liveActivities?.pushToStartToken), now, device.liveActivities?.frequentUpdates === true);
      if (event !== 'update' || !record.token) continue;
      const urgent = liveDeliveryIsUrgent(record, now, device.liveActivities?.frequentUpdates === true);
      const job: Delivery = { ...this.job(snapshot.id, { ...device, token: record.token }), attemptID: crypto.randomUUID(), urgent,
        live: { event, state: record.state, macID: snapshot.id, macName: snapshot.name, timestamp: now } };
      // Reserve only in memory. A restart may repeat a latest-value update, which
      // is safe; it must not turn every metric into a storage operation.
      this.memory.set('live:' + snapshot.id, { ...record, lastSentAt: now, lastSignature: liveSignature(record.state), lastUpdatePhaseSignature: livePhaseSignature(record.state) });
      jobs.push(job); this.counters.metrics++;
    }
    if (this.counters.observations % 128 === 0) console.info('relay.receiver', this.counters);
    return jobs;
  }
  async seed(snapshot: Snapshot, generation: number) {
    this.observe(compactSnapshot(snapshot), generation);
    this.queueLifecycle(); await this.schedule();
  }
  async claimPending(): Promise<Delivery[]> {
    const now = Date.now() / 1000, claimed: Delivery[] = [], retained: Delivery[] = [];
    for (const original of this.queue()) {
      const subscription = this.subscription(original.mac);
      if (original.expires < now || original.attempts >= 8) continue;
      if (!original.revoked && (!subscription || subscription.generation !== original.generation || (subscription.revision ?? 0) !== original.revision)) continue;
      if (original.alert && !original.alert.id.startsWith('test:') && !subscription?.kinds.includes(original.alert.kind)) continue;
      if (original.live?.event === 'start') {
        const record = this.liveRecord(original.mac);
        if (!record || record.dismissed || record.token || !record.state.running && !record.state.attention || now - record.state.updatedAt > 180) continue;
      }
      if (claimed.length >= 10 || Math.max(original.due, original.leaseUntil ?? 0) > now) { retained.push(original); continue; }
      const job = { ...original, attemptID: crypto.randomUUID(), attempts: original.attempts + 1, leaseUntil: now + 30,
        // APNs expiration and ordering describe this delivery attempt. The
        // observation retains its own age, including during a delayed retry.
        ...(original.live ? { live: { ...original.live, timestamp: now,
          ...(original.live.event === 'start' ? { state: this.liveRecord(original.mac)!.state } : {}) } } : {}) };
      claimed.push(job); retained.push(job); this.counters.durable++;
    }
    this.write('outbox', retained); await this.schedule(); return claimed;
  }
  async complete(job: Delivery, result: PushResult) {
    if (job.durable && !this.queue().some(j => j.id === job.id && j.attemptID === job.attemptID)) return;
    const subscription = this.subscription(job.mac);
    if (!job.revoked && (!subscription || subscription.generation !== job.generation || (subscription.revision ?? 0) !== job.revision)) return;
    const retry = result === 'retry' || result === 'not-configured';
    if (job.durable) {
      this.write('outbox', this.queue().flatMap(j => j.id !== job.id ? [j] : retry ? [{ ...j, due: Date.now() / 1000 + Math.min(300, 15 * 2 ** Math.min(j.attempts, 4)), leaseUntil: undefined }] : []));
    }
    const current = this.liveRecord(job.mac);
    if (job.live && current && !job.revoked && (job.live.event === 'start' || current.token === job.device.token)) {
      const key = 'live:' + job.mac;
      if (result === 'accepted') {
        if (job.live.event === 'end') {
          if (current.state.running + current.state.attention > 0 && (job.live.dismissImmediately || current.state.updatedAt > job.live.state.updatedAt)) {
            this.write(key, { selectedTaskID: current.selectedTaskID, state: current.state });
          } else this.forget(key);
        } else if (job.live.timestamp >= (current.lastPromptSentAt ?? 0)) {
          const state = job.live.state;
          const updated = { ...current,
            ...(job.live.timestamp >= (current.lastSentAt ?? 0) ? { lastSentAt: job.live.timestamp, lastSignature: liveSignature(state), lastUpdatePhaseSignature: livePhaseSignature(state) } : {}),
            lastUrgentSignature: liveUrgentSignature(state),
            ...(job.urgent || job.live.event === 'start' ? { lastPhaseSignature: livePhaseSignature(state), lastPromptSentAt: job.live.timestamp } : {}), attempts: 0, retryAt: undefined };
          // Priority transitions/freshness checkpoints are infrequent. Ordinary
          // accepted metric updates never reach this method.
          this.write(key, updated);
        }
      } else if (result === 'invalid-token' && job.live.event === 'update') {
        this.write(key, { selectedTaskID: current.selectedTaskID, state: current.state });
      } else if (['invalid-token', 'configuration-error', 'rejected'].includes(result)) {
        // Delivery failures are not a person's dismissal. Stop automatic retry
        // storms, but allow an authorized foreground recovery to register a card.
        this.write(key, { ...current, deliveryBlocked: true, token: undefined });
      } else if (!job.durable && job.live.timestamp >= (current.lastSentAt ?? 0)) this.memory.set(key, { ...current, retryAt: Date.now() / 1000 + 30 });
    }
    if (job.alert && result === 'invalid-token') { this.forget('device'); this.write('outbox', []); }
    this.queueLifecycle(); await this.schedule();
  }
  async alarm() {
    this.counters.alarms++;
    if (!this.queue().length) return;
    // Reserve the wakeup before yielding. Dispatch returns immediately; only the
    // Worker waits on APNs, and a crash is recovered by the outstanding alarm.
    await this.ctx.storage.setAlarm(Date.now() + 30_000);
    await this.env.DELIVERY.dispatch(this.ctx.id.toString());
  }
  diagnostics() { return { ...this.counters, pending: this.queue().length }; }
}
