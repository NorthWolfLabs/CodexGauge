import { DurableObject } from 'cloudflare:workers';
import { Hono } from 'hono';
import { z } from 'zod';
export { PushReceiver } from './receiver';
import { bodyLimit } from 'hono/body-limit';
import { alertSignature } from './alerts';
import { macID, token, snapshotSchema, presentation, type Snapshot, type Scope } from './protocol';

const MAX_BYTES = 128 * 1024;
const app = new Hono<{ Bindings: Env }>();
app.use('*', bodyLimit({ maxSize: MAX_BYTES }));
app.get('/health', c => c.json({ status: 'ok', protocol: 1 }));
app.all('/v1/macs/:id/*', async c => {
  if (!token.safeParse(c.req.header('authorization')?.replace(/^Bearer /, '') ?? '').success) return c.json({ error: 'Request rejected' }, 401);
  const ip = c.req.header('CF-Connecting-IP') ?? 'local';
  const limiter = c.req.path.endsWith('/initialize') ? c.env.CREATE_LIMIT : c.env.REQUEST_LIMIT;
  if (!(await limiter.limit({ key: ip })).success) return c.json({ error: 'Try again shortly' }, 429, { 'Retry-After': '60' });
  const id = macID.safeParse(c.req.param('id'));
  if (!id.success) return c.json({ error: 'Invalid device identifier' }, 400);
  return c.env.MACS.getByName(id.data.toLowerCase()).fetch(c.req.raw);
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
interface SocketIdentity { role: 'publisher' | Scope; publisherGeneration?: number }
interface Subscriber { id: string; generation: number; revision?: number }
// APNs tokens are variable-length opaque bytes. ActivityKit tokens can be
// substantially longer than ordinary device tokens. Bound the request size,
// not an assumed Apple token length; require complete hexadecimal bytes.
const pushToken = z.string().max(4096).regex(/^(?:[a-f0-9]{2})+$/);
const pushSchema = z.object({ token: pushToken, environment: z.enum(['sandbox', 'production']), kinds: z.array(z.enum(['low', 'allowance', 'banked', 'working', 'attention', 'completed'])).max(6),
  liveActivities: z.object({ enabled: z.boolean(), pushToStartToken: pushToken.optional() }).strict().optional() }).strict();
const liveRegistrationSchema = z.object({ token: pushToken, environment: z.enum(['sandbox', 'production']),
  activityID: z.string().min(1).max(200), activityToken: pushToken.optional(), dismissed: z.boolean().optional(), ended: z.boolean().optional() }).strict();

// One feed per installation: viewers may combine feeds, but cannot publish to,
// impersonate, or send commands to any Mac. No generic message-forwarding path.
export class MacFeed extends DurableObject<Env> {
  private latestSnapshot?: Snapshot;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }
  private read<T>(key: string): T | undefined {
    const row = this.ctx.storage.sql.exec<{ value: string }>('SELECT value FROM state WHERE key = ?', key).toArray()[0];
    return row ? JSON.parse(row.value) as T : undefined;
  }
  private write(key: string, value: unknown) {
    this.ctx.storage.sql.exec('INSERT INTO state VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', key, JSON.stringify(value));
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
    const role = equals(digest, keys.publisher) ? 'publisher' : equals(digest, keys.reader) ? 'full' : equals(digest, keys.usageReader) ? 'usage' : undefined;
    if (!role) return this.error(401);
    if (action === 'live-activity' && request.method === 'POST' && role === 'full') {
      const registration = liveRegistrationSchema.safeParse(await this.body(request));
      if (!registration.success || (!registration.data.dismissed && !registration.data.ended && !registration.data.activityToken)
        || registration.data.dismissed && registration.data.ended) return this.error(400);
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      const currentKeys = this.read<Keys>('keys');
      if (!currentKeys || !equals(digest, currentKeys.reader)) return this.error(401);
      const generation = this.read<number>('generation') ?? 1;
      const subscriber = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID && s.generation === generation);
      if (!subscriber) return this.error(403);
      const accepted = await this.env.RECEIVERS.getByName(receiverID).registerLiveActivity(id.toLowerCase(), generation, registration.data);
      return accepted ? Response.json({ ok: true }) : this.error(403);
    }
    if (action === 'test-notification' && request.method === 'POST' && role !== 'publisher') {
      const registration = pushSchema.pick({ token: true, environment: true }).safeParse(await this.body(request));
      if (!registration.success) return this.error(400);
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      const generation = this.read<number>('generation') ?? 1;
      const result = await this.env.RECEIVERS.getByName(receiverID).testNotification(id.toLowerCase(), generation);
      return Response.json({ result }, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (action === 'feed' && request.method === 'DELETE' && role === 'publisher') {
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      const generation = this.read<number>('generation') ?? 1;
      // Revoke authorization before an RPC yields, so a concurrent registration
      // cannot be accepted after the subscriber list was captured for cleanup.
      this.ctx.storage.sql.exec('DELETE FROM state');
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
      this.write('generation', (this.read<number>('generation') ?? 1) + 1);
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      this.write('subscribers', []);
      for (const ws of this.ctx.getWebSockets()) if ((ws.deserializeAttachment() as SocketIdentity).role !== 'publisher') ws.close(1008, 'Viewing access revoked');
      await Promise.all(subscriptions.map(s => this.env.RECEIVERS.getByName(s.id).revoke(id.toLowerCase(), s.generation)));
      return Response.json({ ok: true });
    }
    if (action === 'notifications' && ['POST', 'DELETE'].includes(request.method) && role !== 'publisher') {
      const registration = pushSchema.safeParse(await this.body(request));
      if (!registration.success) return this.error(400);
      const receiverID = await hash(registration.data.environment + ':' + registration.data.token);
      // Reading the body yielded. The viewing key may have rotated meanwhile.
      const currentKeys = this.read<Keys>('keys');
      const scope = currentKeys && equals(digest, currentKeys.reader) ? 'full'
        : currentKeys && equals(digest, currentKeys.usageReader) ? 'usage' : undefined;
      if (!scope) return this.error(401);
      if (request.method === 'DELETE') {
        const existing = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID);
        this.write('subscribers', (this.read<Subscriber[]>('subscribers') ?? []).filter(s => s.id !== receiverID));
        if (existing) await this.env.RECEIVERS.getByName(receiverID).revoke(id.toLowerCase(), existing.generation, existing.revision ?? 0);
        return Response.json({ ok: true });
      }
      const generation = this.read<number>('generation') ?? 1;
      const subscriptions = this.read<Subscriber[]>('subscribers') ?? [];
      if (subscriptions.length >= 16 && !subscriptions.some(s => s.id === receiverID)) return this.error(429);
      const revision = (this.read<number>('registrationRevision') ?? 0) + 1;
      this.write('registrationRevision', revision);
      // Reserve atomically before RPC yields. Reusing the pre-await list afterward
      // loses other phones and lets concurrent requests exceed the subscriber cap.
      this.write('subscribers', [...subscriptions.filter(s => s.id !== receiverID), { id: receiverID, generation, revision }]);
      const device = { ...registration.data, kinds: scope === 'usage' ? registration.data.kinds.filter(k => ['low', 'banked', 'allowance'].includes(k)) : registration.data.kinds };
      const receiver = this.env.RECEIVERS.getByName(receiverID);
      try { await receiver.register(id.toLowerCase(), device, scope, generation, revision); }
      catch {
        // Keep the reservation: RPC may have applied before its response failed.
        // Retry reuses the slot; unlink/rotation can still clean up that receiver.
        return this.error(503);
      }
      const current = (this.read<Subscriber[]>('subscribers') ?? []).find(s => s.id === receiverID);
      if (generation !== (this.read<number>('generation') ?? 1) || !current || current.generation !== generation) {
        await receiver.revoke(id.toLowerCase(), generation, revision);
        return this.error(401);
      }
      // A newer registration from this same phone supersedes this request; it
      // does not revoke the viewing link. Reporting 401 here made simultaneous
      // token refresh/test requests fail and could end a valid Live Activity.
      // Receiver revisions already prevent an older request replacing the new
      // preferences. Do not revoke that newer reservation during cleanup.
      if (current.revision !== revision) {
        return Response.json({ configured: Boolean(this.env.APNS_PRIVATE_KEY && this.env.APNS_KEY_ID) });
      }
      const latest = this.latestSnapshot ?? this.read<Snapshot>('snapshot');
      if (latest) await this.env.RECEIVERS.getByName(receiverID).observe(latest, generation);
      return Response.json({ configured: Boolean(this.env.APNS_PRIVATE_KEY && this.env.APNS_KEY_ID) });
    }
    if (action === 'snapshot' && request.method === 'GET' && role !== 'publisher') {
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
      server.serializeAttachment({ role, publisherGeneration } satisfies SocketIdentity);
      if (role !== 'publisher') server.send(JSON.stringify(presentation(this.latestSnapshot ?? this.read<Snapshot>('snapshot'), role)));
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
    const saved = this.read<Snapshot>('snapshot');
    const previous = this.latestSnapshot ?? saved;
    if (previous && snapshot.observedAt <= previous.observedAt) {
      // A repeated/out-of-order frame must not roll state back or strand the
      // publisher's request/acknowledgment loop until its timeout.
      ws.send(JSON.stringify({ type: 'accepted', observedAt: previous.observedAt }));
      return;
    }
    this.latestSnapshot = snapshot;
    let subscribers: Subscriber[] = [];
    if (!saved || snapshot.observedAt - saved.observedAt >= 30 || alertSignature(saved) !== alertSignature(snapshot)) {
      this.write('snapshot', snapshot);
      subscribers = this.read<Subscriber[]>('subscribers') ?? [];
    }
    for (const viewer of this.ctx.getWebSockets()) {
      const role = (viewer.deserializeAttachment() as SocketIdentity).role;
      if (role !== 'publisher') {
        try { viewer.send(JSON.stringify(presentation(snapshot, role))); }
        catch { viewer.close(1011, 'Reconnect to refresh'); }
      }
    }
    ws.send(JSON.stringify({ type: 'accepted', observedAt: snapshot.observedAt }));
    // Fan out before the RPC yields: a later publisher frame must never be
    // delivered ahead of this one while a receiver is busy processing alerts.
    await Promise.all(subscribers.map(s => this.env.RECEIVERS.getByName(s.id).observe(snapshot, s.generation)));
  }
  webSocketClose(ws: WebSocket, code: number) {
    // 1005/1006 describe a missing close frame/abnormal disconnect; they cannot
    // be sent on the wire. Browsers and URLSession can disconnect this way.
    const valid = code >= 1000 && code < 5000 && ![1004, 1005, 1006, 1015].includes(code);
    ws.close(valid ? code : 1000);
  }
  webSocketError(ws: WebSocket) { ws.close(1011, 'Reconnect'); }
  private error(status: number) { return Response.json({ error: 'Request rejected' }, { status }); }
  private async body(request: Request): Promise<Record<string, unknown> | undefined> {
    const reader = request.body?.getReader();
    if (!reader) return undefined;
    const chunks: Uint8Array[] = []; let length = 0;
    while (true) {
      const chunk = await reader.read(); if (chunk.done) break;
      length += chunk.value.length;
      if (length > MAX_BYTES) { await reader.cancel(); return undefined; }
      chunks.push(chunk.value);
    }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { return undefined; }
  }
}
