import { DurableObject } from 'cloudflare:workers';
import { Hono } from 'hono';
import { z } from 'zod';
export { PushReceiverV2 } from './receiver';
export { PushDelivery } from './delivery';
import { deliverBatch, type DeliveryBatch } from './delivery';
import { bodyLimit } from 'hono/body-limit';
import { compactSnapshot } from './alerts';
import { macID, token, snapshotSchema, presentation, type Snapshot, type Scope } from './protocol';

const MAX_BYTES = 128 * 1024;
const pushBatchSchema = z.object({ observations: z.array(snapshotSchema).min(1).max(16) }).strict();
const app = new Hono<{ Bindings: Env }>();
app.use('*', bodyLimit({ maxSize: 1024 * 1024 }));
app.get('/health', c => c.json({ status: 'ok', protocol: 2, architecture: 'publisher-driven-push', publishing: 'adaptive-events-v1' }));
app.all('/v1/macs/:id/*', async c => {
  if (!token.safeParse(c.req.header('authorization')?.replace(/^Bearer /, '') ?? '').success) return c.json({ error: 'Request rejected' }, 401);
  const ip = c.req.header('CF-Connecting-IP') ?? 'local';
  const limiter = c.req.path.endsWith('/initialize') ? c.env.CREATE_LIMIT : c.env.REQUEST_LIMIT;
  if (!(await limiter.limit({ key: ip })).success) return c.json({ error: 'Try again shortly' }, 429, { 'Retry-After': '60' });
  const id = macID.safeParse(c.req.param('id'));
  if (!id.success) return c.json({ error: 'Invalid device identifier' }, 400);
  // Finish the size-limited upload before crossing the DO boundary. A DO can
  // reject on scope without reading a body; forwarding Hono's still-streaming
  // limiter then races response completion in workerd and can turn 403 into 500.
  const forwarded = c.req.raw.body ? new Request(c.req.raw, { body: await c.req.arrayBuffer() }) : c.req.raw;
  const response = await c.env.MACS.getByName(id.data.toLowerCase()).fetch(forwarded);
  // Only this outer Worker may consume delivery plans containing APNs tokens.
  // Never return an internal plan to either client.
  if (response.ok && (c.req.path.endsWith('/push') || c.req.path.endsWith('/test-notification'))) {
    const plan = await response.json() as { batches?: DeliveryBatch[]; result?: string; acceptedThrough?: number; refreshAfter?: number };
    const results = await Promise.all((plan.batches ?? []).map(batch => deliverBatch(c.env, batch)));
    if (c.req.path.endsWith('/test-notification')) return c.json({ result: plan.result ?? results.flat()[0] ?? 'queued' });
    return c.json({ acceptedThrough: plan.acceptedThrough, refreshAfter: plan.refreshAfter }, 200, { 'Cache-Control': 'no-store' });
  }
  return response;
});
app.notFound(c => c.json({ error: 'Not found' }, 404));
export default app;

async function hash(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function equals(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left), b = new TextEncoder().encode(right);
  return a.length === b.length && crypto.subtle.timingSafeEqual(a, b);
}
interface Keys { publisher: string; reader: string; usageReader: string }
interface SocketIdentity { role: 'publisher' | Scope; publisherGeneration?: number; deviceID?: string; adaptive?: boolean }
interface Subscriber { id: string; generation: number; revision?: number; deviceID?: string; pushEnabled?: boolean }
interface PairedDevice { id: string; name: string; digest: string; scope: Scope; pairedAt: number; lastSeen: number }
const pairSchema = z.object({ id: macID, name: z.string().trim().min(1).max(80), token }).strict();
// APNs tokens are variable-length opaque bytes. ActivityKit tokens can be
// substantially longer than ordinary device tokens. Bound the request size,
// not an assumed Apple token length; require complete hexadecimal bytes.
const pushToken = z.string().max(4096).regex(/^(?:[a-f0-9]{2})+$/);
const pushSchema = z.object({ token: pushToken, environment: z.enum(['sandbox', 'production']), kinds: z.array(z.enum(['low', 'allowance', 'banked', 'working', 'attention', 'completed'])).max(6),
  liveActivities: z.object({ enabled: z.boolean(), frequentUpdates: z.boolean().optional(), pushToStartToken: pushToken.optional(),
    activeActivityIDs: z.array(z.string().min(1).max(200)).max(32).optional(), requestForegroundStart: z.boolean().optional() }).strict().optional() }).strict();
const liveRegistrationSchema = z.object({ token: pushToken, environment: z.enum(['sandbox', 'production']),
  activityID: z.string().min(1).max(200), activityToken: pushToken.optional(), dismissed: z.boolean().optional(), ended: z.boolean().optional(), selectedTaskID: z.string().min(1).max(200).optional() }).strict();
const liveSelectionSchema = z.object({ activityID: z.string().min(1).max(200), afterTaskID: z.string().min(1).max(200).optional() }).strict();

// One feed per installation: viewers may combine feeds, but cannot publish to,
// impersonate, or send commands to any Mac. No generic message-forwarding path.
export class MacFeedV2 extends DurableObject<Env> {
  private latestSnapshot?: Snapshot;
  private checkpointAt?: number;
  private stored = new Map<string, string | undefined>();
  private refreshWaiters = new Set<() => void>();
  private counters = { frames: 0, checkpoints: 0, pushBatches: 0, reads: 0 };
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }
  private read<T>(key: string): T | undefined {
    if (!this.stored.has(key)) {
      const row = this.ctx.storage.sql.exec<{ value: string }>('SELECT value FROM state WHERE key = ?', key).toArray()[0];
      this.stored.set(key, row?.value); this.counters.reads++;
    }
    const value = this.stored.get(key);
    // Decode per reader so a caller cannot mutate authorization in the cache.
    return value === undefined ? undefined : JSON.parse(value) as T;
  }
  private write(key: string, value: unknown) {
    const encoded = JSON.stringify(value);
    if (this.stored.has(key) && this.stored.get(key) === encoded) return;
    this.ctx.storage.sql.exec('INSERT INTO state VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', key, encoded);
    this.stored.set(key, encoded);
  }
  private authorize(digest: string): { role: 'publisher' | Scope; deviceID?: string } | undefined {
    const keys = this.read<Keys>('keys');
    if (!keys) return;
    if (equals(digest, keys.publisher)) return { role: 'publisher' };
    if (equals(digest, keys.reader)) return { role: 'full' };
    if (equals(digest, keys.usageReader)) return { role: 'usage' };
    const device = (this.read<PairedDevice[]>('devices') ?? []).find(d => equals(digest, d.digest));
    return device ? { role: device.scope, deviceID: device.id } : undefined;
  }
  private touchDevice(id: string | undefined) {
    if (!id) return;
    const devices = this.read<PairedDevice[]>('devices') ?? [], now = Date.now() / 1000;
    if (devices.some(d => d.id === id && now - d.lastSeen >= 300)) {
      this.write('devices', devices.map(d => d.id === id ? { ...d, lastSeen: now } : d));
    }
  }
  private async removeDevice(pairedID: string, mac: string) {
    this.write('devices', (this.read<PairedDevice[]>('devices') ?? []).filter(d => d.id !== pairedID));
    const subscribers = this.read<Subscriber[]>('subscribers') ?? [];
    const removed = subscribers.filter(d => d.deviceID === pairedID);
    this.write('subscribers', subscribers.filter(d => d.deviceID !== pairedID));
    for (const ws of this.ctx.getWebSockets()) if ((ws.deserializeAttachment() as SocketIdentity).deviceID === pairedID) ws.close(1008, 'Device access removed');
    this.notifyDemand();
    await Promise.all(removed.map(d => this.env.RECEIVERS.getByName(d.id).revoke(mac.toLowerCase(), d.generation, d.revision ?? 0)));
  }
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url), action = url.pathname.split('/').at(-1);
    const bearer = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? '';
    if (!token.safeParse(bearer).success) return this.error(401);
    const digest = await hash(bearer);
    // This fetch is internal to this DO; use the route ID only for schema matching.
    const id = url.pathname.split('/')[3];
    if (action === 'initialize' && request.method === 'POST') {
      // Parse a bounded body even when the DO is invoked directly through a binding.
      const data = await this.body(request);
      const reader = token.safeParse(data?.reader), usage = token.safeParse(data?.usageReader);
      if (!reader.success || !usage.success || reader.data === bearer || usage.data === bearer || reader.data === usage.data) return this.error(400);
      const keys: Keys = { publisher: digest, reader: await hash(reader.data), usageReader: await hash(usage.data) };
      if (this.read<Keys>('keys')) return this.error(409);
      this.write('keys', keys);
      this.write('id', id.toLowerCase());
      this.write('generation', (this.read<number>('generation') ?? 0) + 1);
      return Response.json({ ok: true });
    }
    const keys = this.read<Keys>('keys');
    if (!keys) return this.error(401);
    const authorization = this.authorize(digest);
    if (!authorization) return this.error(401);
    const { role, deviceID } = authorization;
    if (action === 'diagnostics' && request.method === 'GET' && role === 'publisher') {
      const subscribers = this.read<Subscriber[]>('subscribers') ?? [];
      const receivers = await Promise.all(subscribers.map(s => this.env.RECEIVERS.getByName(s.id).diagnostics()));
      return Response.json({ runtime: this.counters, receivers }, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (action === 'push' && request.method === 'POST' && role === 'publisher') {
      const input = pushBatchSchema.safeParse(await this.body(request, 1024 * 1024));
      if (!input.success) return this.error(400);
      if (this.authorize(digest)?.role !== 'publisher') return this.error(401);
      const now = Date.now() / 1000, observations = input.data.observations;
      if (observations.some((s, i) => s.id.toLowerCase() !== id.toLowerCase() || s.observedAt > now + 120 || s.observedAt < now - 3600
        || s.account && s.account.observedAt > now + 120 || i > 0 && s.observedAt <= observations[i - 1].observedAt)) return this.error(400);
      const subscribers = this.read<Subscriber[]>('subscribers') ?? [];
      this.counters.pushBatches++;
      const batches = await Promise.all(subscribers.filter(s => s.pushEnabled !== false).map(async s => {
        const receiver = this.env.RECEIVERS.getByName(s.id);
        return { receiver: receiver.id.toString(), ...await receiver.prepareBatch(observations.map(compactSnapshot), s.generation) };
      }));
      if (this.authorize(digest)?.role !== 'publisher') return this.error(401);
      const deadlines = batches.flatMap(batch => batch.refreshAfter === undefined ? [] : [batch.refreshAfter]);
      return Response.json({ batches, acceptedThrough: observations.at(-1)!.observedAt,
        refreshAfter: deadlines.length ? Math.min(...deadlines) : undefined });
    }
    if (action === 'pair' && request.method === 'POST' && role !== 'publisher' && !deviceID) {
      const registration = pairSchema.safeParse(await this.body(request));
      if (!registration.success) return this.error(400);
      const deviceDigest = await hash(registration.data.token);
      // Body parsing and hashing yield: recheck shared authority before reserving.
      const current = this.authorize(digest);
      if (!current || current.role !== role || current.deviceID) return this.error(401);
      if ([keys.publisher, keys.reader, keys.usageReader].some(k => equals(deviceDigest, k))) return this.error(400);
      const devices = this.read<PairedDevice[]>('devices') ?? [];
      const pairedID = registration.data.id.toLowerCase();
      const existing = devices.find(d => d.id === pairedID);
      if (existing && (!equals(existing.digest, deviceDigest) || existing.scope !== role)) return this.error(409);
      if (devices.some(d => d.id !== pairedID && equals(d.digest, deviceDigest))) return this.error(409);
      if (!existing && devices.length >= 16) return this.error(429);
      const now = Date.now() / 1000;
      this.write('devices', [...devices.filter(d => d.id !== pairedID), {
        id: pairedID, name: registration.data.name, digest: deviceDigest, scope: role,
        pairedAt: existing?.pairedAt ?? now, lastSeen: now,
      } satisfies PairedDevice]);
      this.notifyDemand();
      return Response.json({ ok: true }, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (action === 'devices' && role === 'publisher') {
      if (request.method === 'GET') {
        const connected = new Set(this.ctx.getWebSockets().map(ws => (ws.deserializeAttachment() as SocketIdentity).deviceID));
        return Response.json({ devices: (this.read<PairedDevice[]>('devices') ?? []).map(({ digest: _secret, ...d }) => ({ ...d, connected: connected.has(d.id) })) }, { headers: { 'Cache-Control': 'no-store' } });
      }
      if (request.method === 'DELETE') {
        const input = z.object({ id: macID }).strict().safeParse(await this.body(request));
        if (!input.success) return this.error(400);
        if (this.authorize(digest)?.role !== 'publisher') return this.error(401);
        const pairedID = input.data.id.toLowerCase();
        // Revoke before yielding. In-flight registrations cannot restore access.
        await this.removeDevice(pairedID, id);
        return Response.json({ ok: true });
      }
    }
    if (action === 'pair' && request.method === 'DELETE' && deviceID) {
      await this.removeDevice(deviceID, id);
      return Response.json({ ok: true });
    }
    if (action === 'live-selection' && request.method === 'POST' && role === 'full' && deviceID) {
      const input = liveSelectionSchema.safeParse(await this.body(request));
      if (!input.success) return this.error(400);
      const current = this.authorize(digest);
      if (current?.deviceID !== deviceID || current.role !== 'full') return this.error(401);
      const generation = this.read<number>('generation') ?? 1;
      const subscribers = (this.read<Subscriber[]>('subscribers') ?? []).filter(s => s.deviceID === deviceID && s.generation === generation);
      for (const subscriber of subscribers) {
        const state = await this.env.RECEIVERS.getByName(subscriber.id).selectLiveActivity(id.toLowerCase(), generation, input.data.activityID, input.data.afterTaskID, this.latestSnapshot ?? this.read<Snapshot>('snapshot'));
        if (this.authorize(digest)?.deviceID !== deviceID || generation !== (this.read<number>('generation') ?? 1)) return this.error(401);
        if (state) return Response.json({ state, deliveryTimestamp: Date.now() / 1000 }, { headers: { 'Cache-Control': 'no-store' } });
      }
      return this.error(409);
    }
    if (action === 'live-activity' && request.method === 'POST' && role === 'full') {
      const registration = liveRegistrationSchema.safeParse(await this.body(request));
      if (!registration.success || (!registration.data.dismissed && !registration.data.ended && !registration.data.activityToken)
        || registration.data.dismissed && registration.data.ended) return this.error(400);
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      if (this.authorize(digest)?.role !== 'full') return this.error(401);
      const generation = this.read<number>('generation') ?? 1;
      const subscriber = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID && s.generation === generation && (!deviceID || s.deviceID === deviceID));
      if (!subscriber) return this.error(403);
      const receiver = this.env.RECEIVERS.getByName(receiverID);
      const latest = this.latestSnapshot ?? this.read<Snapshot>('snapshot');
      if (latest) await receiver.seed(compactSnapshot(latest), generation);
      const accepted = await receiver.registerLiveActivity(id.toLowerCase(), generation, registration.data);
      return accepted ? Response.json({ ok: true }) : this.error(403);
    }
    if (action === 'test-notification' && request.method === 'POST' && role !== 'publisher') {
      const registration = pushSchema.pick({ token: true, environment: true }).safeParse(await this.body(request));
      if (!registration.success) return this.error(400);
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      if (!this.authorize(digest)) return this.error(401);
      if (deviceID && !(this.read<Subscriber[]>('subscribers') ?? []).some(s => s.id === receiverID && s.deviceID === deviceID)) return this.error(403);
      const generation = this.read<number>('generation') ?? 1;
      const receiver = this.env.RECEIVERS.getByName(receiverID);
      const result = await receiver.testNotification(id.toLowerCase(), generation);
      return Response.json(result === 'queued' ? { batches: [{ receiver: receiver.id.toString(), deliveries: await receiver.claimPending() }] } : { result }, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (action === 'feed' && request.method === 'DELETE' && role === 'publisher') {
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      const generation = this.read<number>('generation') ?? 1;
      // Revoke authorization before an RPC yields, so a concurrent registration
      // cannot be accepted after the subscriber list was captured for cleanup.
      this.ctx.storage.sql.exec('DELETE FROM state');
      this.stored.clear(); this.checkpointAt = undefined;
      // Keep only a monotonic counter. Recreating the same installation ID must
      // not let cleanup for an old feed revoke a new generation's subscription.
      this.write('generation', generation);
      for (const ws of this.ctx.getWebSockets()) ws.close(1008, 'Feed removed');
      this.latestSnapshot = undefined;
      await Promise.all(subscriptions.map(s => this.env.RECEIVERS.getByName(s.id).revoke(id.toLowerCase(), s.generation)));
      return Response.json({ ok: true });
    }
    if (action === 'rotate' && request.method === 'POST' && role === 'publisher') {
      const data = await this.body(request);
      const reader = token.safeParse(data?.reader), usage = token.safeParse(data?.usageReader);
      if (!reader.success || !usage.success || reader.data === bearer || usage.data === bearer || reader.data === usage.data) return this.error(400);
      const nextKeys = { ...keys, reader: await hash(reader.data), usageReader: await hash(usage.data) };
      // Parsing/hashing yielded. A concurrent deletion must not be undone by
      // committing keys captured before it revoked the publisher.
      const currentKeys = this.read<Keys>('keys');
      if (!currentKeys || !equals(digest, currentKeys.publisher)) return this.error(401);
      this.write('keys', nextKeys);
      this.write('devices', []);
      this.write('generation', (this.read<number>('generation') ?? 1) + 1);
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      this.write('subscribers', []);
      for (const ws of this.ctx.getWebSockets()) if ((ws.deserializeAttachment() as SocketIdentity).role !== 'publisher') ws.close(1008, 'Viewing access revoked');
      this.notifyDemand();
      await Promise.all(subscriptions.map(s => this.env.RECEIVERS.getByName(s.id).revoke(id.toLowerCase(), s.generation)));
      return Response.json({ ok: true });
    }
    if (action === 'notifications' && ['POST', 'DELETE'].includes(request.method) && role !== 'publisher') {
      const registration = pushSchema.safeParse(await this.body(request));
      if (!registration.success) {
        console.warn('Notification registration schema rejected', registration.error.issues.map(issue => ({ path: issue.path.map(String).join('.'), code: issue.code })));
        return this.error(400);
      }
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      // Reading the body yielded. The viewing key may have rotated meanwhile.
      const currentAuthorization = this.authorize(digest);
      const scope = currentAuthorization?.role === 'publisher' ? undefined : currentAuthorization?.role;
      if (!scope) return this.error(401);
      if (request.method === 'DELETE') {
        const existing = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID);
        if (existing?.deviceID && existing.deviceID !== deviceID) return this.error(403);
        this.write('subscribers', (this.read<Subscriber[]>('subscribers') ?? []).filter(s => s.id !== receiverID));
        this.notifyDemand();
        if (existing) await this.env.RECEIVERS.getByName(receiverID).revoke(id.toLowerCase(), existing.generation, existing.revision ?? 0);
        return Response.json({ ok: true });
      }
      const generation = this.read<number>('generation') ?? 1;
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      if (subscriptions.length >= 16 && !subscriptions.some(s => s.id === receiverID)) return this.error(429);
      if (subscriptions.some(s => s.id === receiverID && s.deviceID && s.deviceID !== deviceID)) return this.error(403);
      const revision = (this.read<number>('registrationRevision') ?? 0) + 1;
      this.write('registrationRevision', revision);
      // Reserve atomically before RPC yields. Reusing the pre-await list afterward
      // loses other phones and lets concurrent requests exceed the subscriber cap.
      const device = { ...registration.data, kinds: scope === 'usage' ? registration.data.kinds.filter(k => ['low', 'banked', 'allowance'].includes(k)) : registration.data.kinds };
      const pushEnabled = device.kinds.length > 0 || scope === 'full' && device.liveActivities?.enabled === true;
      this.write('subscribers', [...subscriptions.filter(s => s.id !== receiverID), { id: receiverID, generation, revision, deviceID, pushEnabled }]);
      const receiver = this.env.RECEIVERS.getByName(receiverID);
      try { await receiver.register(id.toLowerCase(), device, scope, generation, revision); }
      catch {
        // Keep the reservation: RPC may have applied before its response failed.
        // Retry reuses the slot; unlink/rotation can still clean up that receiver.
        return this.error(503);
      }
      const current = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID);
      if (!this.authorize(digest) || generation !== (this.read<number>('generation') ?? 1) || !current || current.generation !== generation) {
        await receiver.revoke(id.toLowerCase(), generation, revision);
        return this.error(401);
      }
      // A newer registration from this same phone supersedes this request; it
      // does not revoke the viewing link. Reporting 401 here made simultaneous
      // token refresh/test requests fail and could end a valid Live Activity.
      // Receiver revisions already prevent an older request replacing the new
      // preferences. Do not revoke that newer reservation during cleanup.
      if (current.revision !== revision) {
        return Response.json({ configured: Boolean(this.env.APNS_PRIVATE_KEY && this.env.APNS_KEY_ID),
          ...(registration.data.liveActivities?.requestForegroundStart ? { foregroundStartAllowed: false, foregroundStartRetry: true, foregroundStartRetrySoon: true } : {}) });
      }
      const latest = this.latestSnapshot ?? this.read<Snapshot>('snapshot');
      if (latest) await receiver.seed(compactSnapshot(latest), generation);
      const foreground = registration.data.liveActivities?.requestForegroundStart
        ? await receiver.reserveForegroundStart(id.toLowerCase(), generation, revision, registration.data.liveActivities.activeActivityIDs) : undefined;
      // Rotation, unlinking, and a newer preference request can interleave RPCs.
      // An old request must never grant a new foreground card after revocation.
      if (foreground) {
        const authorized = this.authorize(digest);
        const reserved = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID);
        if (!authorized || authorized.role !== scope || generation !== (this.read<number>('generation') ?? 1)
          || !reserved || reserved.generation !== generation) return this.error(401);
        if (reserved.revision !== revision) return Response.json({ configured: Boolean(this.env.APNS_PRIVATE_KEY && this.env.APNS_KEY_ID), foregroundStartAllowed: false, foregroundStartRetry: true, foregroundStartRetrySoon: true });
      }
      this.notifyDemand(true);
      this.requestSnapshot();
      return Response.json({ configured: Boolean(this.env.APNS_PRIVATE_KEY && this.env.APNS_KEY_ID), ...foreground });
    }
    if (action === 'snapshot' && request.method === 'GET' && role !== 'publisher') {
      this.touchDevice(deviceID);
      const cached = this.latestSnapshot ?? this.read<Snapshot>('snapshot');
      // A sparse checkpoint must not leave a widget showing five-minute-old
      // data after hibernation. Connected Macs answer this bounded refresh in
      // their next one-second publication tick; offline reads return immediately.
      if ((!cached || Date.now() / 1000 - cached.observedAt > 2) && this.ctx.getWebSockets('publisher').length) {
        let ready!: () => void;
        const fresh = new Promise<void>(resolve => { ready = resolve; });
        this.refreshWaiters.add(ready);
        const timeout = setTimeout(ready, 1500);
        try { this.requestSnapshot(); await fresh; }
        finally { clearTimeout(timeout); this.refreshWaiters.delete(ready); }
        const current = this.authorize(digest);
        if (!current || current.role !== role || current.deviceID !== deviceID) return this.error(401);
      }
      return Response.json(presentation(this.latestSnapshot ?? this.read<Snapshot>('snapshot'), role), { headers: { 'Cache-Control': 'no-store' } });
    }
    if (action === 'stream' && request.method === 'GET' && request.headers.get('upgrade')?.toLowerCase() === 'websocket') {
      if (this.ctx.getWebSockets().length >= 16) return this.error(429);
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      // Only one publisher per installation; stale sockets cannot overwrite a new connection.
      if (role === 'publisher') for (const old of this.ctx.getWebSockets('publisher')) old.close(1000, 'Publisher reconnected');
      this.ctx.acceptWebSocket(server, [role]);
      let publisherGeneration: number | undefined;
      if (role === 'publisher') {
        publisherGeneration = (this.read<number>('publisherGeneration') ?? 0) + 1;
        this.write('publisherGeneration', publisherGeneration);
      }
      this.touchDevice(deviceID);
      server.serializeAttachment({ role, publisherGeneration, deviceID, adaptive: role === 'publisher' && url.searchParams.get('publishing') === 'adaptive' } satisfies SocketIdentity);
      this.notifyDemand(role === 'publisher');
      if (role !== 'publisher') {
        server.send(JSON.stringify(presentation(this.latestSnapshot ?? this.read<Snapshot>('snapshot'), role)));
        this.requestSnapshot();
      }
      return new Response(null, { status: 101, webSocket: client });
    }
    return this.error(403);
  }
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const identity = ws.deserializeAttachment() as SocketIdentity;
    if (identity.role !== 'publisher') { ws.close(1008, 'Read-only connection'); return; }
    if (identity.publisherGeneration !== this.read<number>('publisherGeneration')) { ws.close(1008, 'Publisher replaced'); return; }
    if (typeof message !== 'string' || new TextEncoder().encode(message).length > MAX_BYTES) { ws.close(1009, 'Snapshot too large'); return; }
    let input: unknown;
    try { input = JSON.parse(message); } catch { ws.close(1008, 'Invalid snapshot'); return; }
    const result = snapshotSchema.safeParse(input);
    if (!result.success || result.data.id.toLowerCase() !== this.read<string>('id')) { ws.close(1008, 'Invalid snapshot'); return; }
    const snapshot = result.data;
    const now = Date.now() / 1000;
    // A reconnect must send current state, not replay old task activity as live.
    if (Math.abs(snapshot.observedAt - now) > 120 || (snapshot.account && snapshot.account.observedAt > now + 120)) { ws.close(1008, 'Invalid observation time'); return; }
    const previous = this.latestSnapshot ?? this.read<Snapshot>('snapshot');
    this.checkpointAt ??= this.read<Snapshot>('snapshot')?.observedAt ?? -Infinity;
    if (previous && snapshot.observedAt <= previous.observedAt) {
      // A repeated/out-of-order frame must not roll state back or strand the
      // publisher's request/acknowledgment loop until its timeout.
      ws.send(JSON.stringify({ type: 'accepted', observedAt: previous.observedAt }));
      return;
    }
    this.latestSnapshot = snapshot;
    for (const ready of this.refreshWaiters) ready();
    this.counters.frames++;
    if (snapshot.observedAt - this.checkpointAt >= 300) {
      this.write('snapshot', snapshot); this.checkpointAt = snapshot.observedAt;
      this.counters.checkpoints++;
    }
    for (const viewer of this.ctx.getWebSockets()) {
      const role = (viewer.deserializeAttachment() as SocketIdentity).role;
      if (role !== 'publisher') {
        try { viewer.send(JSON.stringify(presentation(snapshot, role))); }
        catch { viewer.close(1011, 'Reconnect to refresh'); }
      }
    }
    ws.send(JSON.stringify({ type: 'accepted', observedAt: snapshot.observedAt }));
    // Push observations arrive independently through the ordinary Worker. No
    // receiver RPC, alarm, or per-phone write belongs on the WebSocket hot path.
  }
  private notifyDemand(refreshPush = false, closing?: WebSocket) {
    const sockets = this.ctx.getWebSockets().filter(ws => ws !== closing && ws.readyState === WebSocket.OPEN);
    const demand = JSON.stringify({ type: 'demand',
      viewers: sockets.filter(ws => (ws.deserializeAttachment() as SocketIdentity).role !== 'publisher').length,
      push: (this.read<Subscriber[]>('subscribers') ?? []).some(s => s.pushEnabled !== false),
      paired: (this.read<PairedDevice[]>('devices') ?? []).length > 0, refreshPush });
    // Opt in: older publishers reject unknown control frames. Attachments retain
    // the capability across hibernation; no polling alarm or stored counter.
    for (const ws of sockets) if ((ws.deserializeAttachment() as SocketIdentity).adaptive) {
      try { ws.send(demand); } catch { /* Reconnect restores current demand. */ }
    }
  }
  private requestSnapshot() {
    for (const publisher of this.ctx.getWebSockets('publisher')) {
      try { publisher.send(JSON.stringify({ type: 'refresh' })); } catch { /* Reconnect supplies current state. */ }
    }
  }

  webSocketClose(ws: WebSocket, code: number) {
    // 1005/1006 describe a missing close frame/abnormal disconnect; they cannot
    // be sent on the wire. Browsers and URLSession can disconnect this way.
    const valid = code >= 1000 && code < 5000 && ![1004, 1005, 1006, 1015].includes(code);
    ws.close(valid ? code : 1000);
    this.notifyDemand(false, ws);
  }
  webSocketError(ws: WebSocket) { ws.close(1011, 'Reconnect'); this.notifyDemand(false, ws); }
  private error(status: number) { return Response.json({ error: 'Request rejected' }, { status }); }
  private async body(request: Request, maxBytes = MAX_BYTES): Promise<Record<string, unknown> | undefined> {
    const reader = request.body?.getReader();
    if (!reader) return undefined;
    const chunks: Uint8Array[] = []; let length = 0;
    while (true) {
      const chunk = await reader.read(); if (chunk.done) break;
      length += chunk.value.length;
      if (length > maxBytes) { await reader.cancel(); return undefined; }
      chunks.push(chunk.value);
    }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { return undefined; }
  }
}
