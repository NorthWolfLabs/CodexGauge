import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';
import { generateKeyPairSync, randomUUID, createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';

const require = createRequire(import.meta.url);
const wrangler = createRequire(require.resolve('wrangler'));
const { Miniflare, Response: MFResponse } = wrangler('miniflare');
const { build } = wrangler('esbuild');
const bundle = await build({ entryPoints: [resolve('src/index.ts')], bundle: true, write: false, format: 'esm', platform: 'neutral',
  conditions: ['workerd', 'worker', 'browser'], external: ['cloudflare:workers', 'node:*'], target: 'es2023' });
const privateKey = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey.export({ format: 'pem', type: 'pkcs8' }).toString();
const key = 'a'.repeat(64), phone = 'd'.repeat(64);
const receiverName = createHash('sha256').update('sandbox:' + phone).digest('hex');
async function runtime(resourcePersistencePath?: string) {
  const sent: { body: any; token: string; priority: string }[] = [];
  let status = 200;
  const mf = new Miniflare({ resourcePersistencePath, unsafeInspectDurableObjects: true, workers: [{ config: {
    name: 'relay-test', compatibilityDate: '2026-09-29', compatibilityFlags: ['nodejs_compat'],
    manifest: { mainModule: 'index.js', modulesRoot: process.cwd(), modules: { 'index.js': { type: 'esm', contents: bundle.outputFiles[0].text } } },
    env: {
      MACS: { type: 'durable-object', worker: 'relay-test', exportName: 'MacFeedV2' },
      RECEIVERS: { type: 'durable-object', worker: 'relay-test', exportName: 'PushReceiverV2' },
      DELIVERY: { type: 'worker', worker: 'relay-test', exportName: 'PushDelivery' },
      CREATE_LIMIT: { type: 'rate-limit', namespace: '1', simple: { limit: 10000, period: 60 } },
      REQUEST_LIMIT: { type: 'rate-limit', namespace: '2', simple: { limit: 10000, period: 60 } },
      ...Object.fromEntries(Object.entries({ APNS_PRIVATE_KEY: privateKey, APNS_KEY_ID: 'test', APNS_TEAM_ID: 'test', APNS_BUNDLE_ID: 'test.app' }).map(([k, value]) => [k, { type: 'json', value }])),
    },
    exports: { MacFeedV2: { type: 'durable-object', storage: 'sqlite' }, PushReceiverV2: { type: 'durable-object', storage: 'sqlite' } },
  }, dev: { outboundService: { type: 'fetcher', handler: async (request: Request) => {
    assert.equal(new URL(request.url).hostname, 'api.sandbox.push.apple.com');
    sent.push({ body: await request.json(), token: new URL(request.url).pathname.split('/').at(-1)!, priority: request.headers.get('apns-priority')! });
    return new MFResponse(status === 200 ? null : JSON.stringify({ reason: 'ServiceUnavailable' }), { status });
  } } } }] });
  const ns = await mf.getDurableObjectNamespace('RECEIVERS');
  const receiver = ns.get(ns.idFromName(receiverName));
  const request = (id: string, action: string, body?: unknown, bearer = key, method = 'POST') => mf.dispatchFetch('http://relay/v1/macs/' + id + '/' + action, {
    method, headers: { Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { mf, receiver, sent, request, fail: (code: number) => { status = code; } };
}
function snapshot(id: string, observedAt = Date.now() / 1000) {
  return { schemaVersion: 1, id, name: 'Synthetic Mac', observedAt,
    account: { id: 'account', observedAt, bankedResets: 1, windows: [{ id: 'weekly', name: 'Weekly', remainingPercent: 70 }], dailyTokens: [] },
    tasks: [{ id: 'task', title: 'Synthetic task', state: 'running', activity: 'Thinking', startedAt: observedAt - 20,
      tokensPerMinute: 100, totalTokens: 100, agentCount: 0, contextPercent: 20 }] };
}
const registration = { token: phone, environment: 'sandbox', kinds: ['completed', 'banked'], liveActivities: { enabled: true, frequentUpdates: true } };

test('foreground recovery reserves one start, registers updates, respects dismissal, and resets after idle', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, registration, 'full', 1, 1);
    await r.receiver.seed(source, 1);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, undefined)).foregroundStartAllowed, false);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 0, [])).foregroundStartAllowed, false);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, ['existing'])).foregroundStartAllowed, false);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, true);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false, 'Concurrent requests cannot both reserve a card');
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'foreground', activityToken: 'e'.repeat(64) });
    const updates = await r.receiver.prepare([{ ...source, observedAt: source.observedAt + .1 }], 1);
    assert.equal(updates[0].live.event, 'update');
    await r.receiver.complete(updates[0], 'accepted');
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'foreground', dismissed: true });
    const dismissed = await r.receiver.reserveForegroundStart(id, 1, 1, []);
    assert.equal(dismissed.foregroundStartAllowed, false); assert.equal(dismissed.foregroundStartDismissed, true);
    await r.receiver.seed({ ...source, observedAt: source.observedAt + 1, tasks: [] }, 1);
    await r.receiver.seed({ ...source, observedAt: source.observedAt + 2 }, 1);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, true, 'New active session may start after idle');
    await r.receiver.revoke(id, 1);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false);
  } finally { await r.mf.dispose(); }
});

test('foreground starts require full access, enabled preferences and fresh active evidence', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, registration, 'usage', 1, 1);
    await r.receiver.seed(source, 1);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false);
    await r.receiver.register(id, { ...registration, liveActivities: { enabled: false } }, 'full', 1, 2);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 2, [])).foregroundStartAllowed, false);
    await r.receiver.register(id, registration, 'full', 1, 3);
    await r.receiver.seed({ ...source, observedAt: source.observedAt + .1, tasks: [] }, 1);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 3, [])).foregroundStartAllowed, false);
    const other = randomUUID();
    await r.receiver.register(other, registration, 'full', 1, 1);
    await r.receiver.seed(snapshot(other, Date.now() / 1000 - 181), 1);
    assert.equal((await r.receiver.reserveForegroundStart(other, 1, 1, [])).foregroundStartAllowed, false);
  } finally { await r.mf.dispose(); }
});

test('two foreground reports recover a young orphan while renewed tokens reset the confirmation', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, registration, 'full', 1, 1);
    await r.receiver.seed(source, 1);
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'young', activityToken: 'e'.repeat(64) });
    const first = await r.receiver.reserveForegroundStart(id, 1, 1, []);
    assert.equal(first.foregroundStartAllowed, false); assert.equal(first.foregroundStartRetrySoon, true);
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false);
    await new Promise(resolve => setTimeout(resolve, 1100));
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'young', activityToken: 'f'.repeat(64) });
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false, 'A real token update resets the earlier absence report');
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, true, 'Confirmed absence can recover before the ordinary 30-second registry grace');
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'replacement', activityToken: 'e'.repeat(64) });
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'replacement', dismissed: true });
    assert.equal((await r.receiver.reserveForegroundStart(id, 1, 1, [])).foregroundStartAllowed, false);
  } finally { await r.mf.dispose(); }
});

test('APNs rejection stops remote retries but does not masquerade as user dismissal', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, { ...registration, liveActivities: { enabled: true, pushToStartToken: 'f'.repeat(64) } }, 'full', 1, 1);
    const jobs = await r.receiver.prepare([source], 1);
    assert.equal(jobs[0].live.event, 'start');
    await r.receiver.complete(jobs[0], 'rejected');
    assert.equal((await r.receiver.prepare([{ ...source, observedAt: source.observedAt + .1 }], 1)).length, 0);
    const permission = await r.receiver.reserveForegroundStart(id, 1, 1, []);
    assert.equal(permission.foregroundStartAllowed, true); assert.equal(permission.foregroundStartDismissed, false);
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'recovered', activityToken: 'e'.repeat(64) });
    const update = await r.receiver.prepare([{ ...source, observedAt: source.observedAt + .2 }], 1);
    assert.equal(update[0].live.event, 'update');
  } finally { await r.mf.dispose(); }
});

test('notification endpoint adds foreground eligibility only for opted-in clients and rejects publisher access', async () => {
  const r = await runtime(), id = randomUUID();
  try {
    await r.request(id, 'initialize', { reader: 'b'.repeat(64), usageReader: 'c'.repeat(64) });
    assert.deepEqual(await (await r.request(id, 'notifications', registration, 'b'.repeat(64))).json(), { configured: true });
    await r.receiver.seed(snapshot(id), 1);
    const requested = { ...registration, liveActivities: { enabled: true, activeActivityIDs: [], requestForegroundStart: true } };
    const result = await r.request(id, 'notifications', requested, 'b'.repeat(64));
    assert.equal(result.status, 200); assert.equal((await result.json()).foregroundStartAllowed, true);
    assert.equal((await r.request(id, 'notifications', requested)).status, 403);
    const usage = await r.request(id, 'notifications', requested, 'c'.repeat(64));
    assert.equal(usage.status, 200); assert.equal((await usage.json()).foregroundStartAllowed, false);
  } finally { await r.mf.dispose(); }
});

test('hundreds of metrics perform zero durable writes; HTTP plans hide tokens and preserve ordering', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    assert.equal((await r.request(id, 'initialize', { reader: 'b'.repeat(64), usageReader: 'c'.repeat(64) })).status, 200);
    assert.equal((await r.request(id, 'notifications', registration, 'b'.repeat(64))).status, 200);
    await r.receiver.seed(source, 1);
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'activity', activityToken: 'e'.repeat(64) });
    const initial = await r.request(id, 'push', { observations: [source] });
    assert.equal(initial.status, 200);
    assert.deepEqual(Object.keys(await initial.json()), ['acceptedThrough']);
    assert.equal(r.sent.length, 1);
    const before = await r.receiver.diagnostics();
    for (let i = 1; i <= 200; i++) {
      const next = structuredClone(source); next.observedAt += i / 1000; next.account.observedAt = next.observedAt;
      next.tasks[0].tokensPerMinute += i; next.tasks[0].contextPercent = 20 + i / 100;
      await r.receiver.prepare([next], 1);
    }
    const after = await r.receiver.diagnostics();
    assert.equal(after.writes, before.writes, 'Metric snapshots must not write SQL');
    assert.equal(after.pending, 0, 'Metric traffic must not create durable delivery jobs');
    assert.equal(after.alarms, before.alarms, 'Metric traffic must not start polling alarms');
    await new Promise(resolve => setTimeout(resolve, 5100));
    const due = structuredClone(source); due.observedAt = Date.now() / 1000;
    due.tasks[0].tokensPerMinute += 1000;
    assert.equal((await r.request(id, 'push', { observations: [due] })).status, 200);
    assert.equal(r.sent.length, 2);
    assert.equal(r.sent[1].priority, '5');
    assert.equal((await r.receiver.diagnostics()).writes, before.writes, 'Accepted background metrics need no durable receipt');
    assert.equal((await r.request(id, 'push', { observations: [source] }, 'b'.repeat(64))).status, 403);
    assert.equal((await r.request(id, 'push', { observations: [{ ...source, id: randomUUID() }] })).status, 400);
    assert.equal((await r.request(id, 'push', { observations: [source, source] })).status, 400);
    assert.equal((await r.request(id, 'diagnostics', undefined, 'b'.repeat(64), 'GET')).status, 403);
  } finally { await r.mf.dispose(); }
});

test('important delivery survives object eviction; stale attempt receipts cannot erase a retry', async () => {
  const path = await mkdtemp(resolve(tmpdir(), 'relay-runtime-'));
  let r = await runtime(path);
  const id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, { ...registration, liveActivities: { enabled: false } }, 'full', 1);
    await r.receiver.prepare([source], 1);
    const done = structuredClone(source); done.observedAt += .01; done.tasks[0].state = 'completed';
    (done.tasks[0] as any).eventAt = done.observedAt;
    const first = await r.receiver.prepare([done], 1);
    assert.equal(first.length, 1); assert.equal(first[0].alert.kind, 'completed');
    const storage = await r.mf.unsafeGetDurableObjectStorage('relay-test', 'PushReceiverV2', { name: receiverName });
    const rows = await storage.exec("SELECT value FROM state WHERE key = 'outbox'");
    const jobs = JSON.parse(rows[0].value); jobs[0].leaseUntil = Date.now() / 1000 - 1;
    await storage.exec("UPDATE state SET value = ? WHERE key = 'outbox'", JSON.stringify(jobs));
    await r.mf.dispose();
    r = await runtime(path);
    const retry = await r.receiver.claimPending();
    assert.equal(retry.length, 1); assert.equal(retry[0].id, first[0].id); assert.notEqual(retry[0].attemptID, first[0].attemptID);
    await r.receiver.complete(first[0], 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 1);
    await r.receiver.complete(retry[0], 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 0);
    assert.equal((await r.receiver.prepare([done], 1)).length, 0, 'Replayed transition is not a second notification');
  } finally { await r.mf.dispose(); await rm(path, { recursive: true, force: true }); }
});

test('two Macs share account deduplication; revocation removes pending alerts and cannot be undone by stale receipts', async () => {
  const r = await runtime(), a = randomUUID(), b = randomUUID(), now = Date.now() / 1000;
  try {
    for (const id of [a, b]) {
      await r.receiver.register(id, { ...registration, liveActivities: { enabled: false } }, 'full', 1);
      await r.receiver.prepare([snapshot(id, now)], 1);
    }
    const changedA = snapshot(a, now + .01), changedB = snapshot(b, now + .02);
    changedA.account.bankedResets = 2; changedB.account.bankedResets = 2;
    const jobsA = await r.receiver.prepare([changedA], 1), jobsB = await r.receiver.prepare([changedB], 1);
    assert.equal(jobsA.length, 1); assert.equal(jobsB.length, 0);
    await r.receiver.revoke(a, 1);
    await r.receiver.complete(jobsA[0], 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 0);
    assert.equal((await r.receiver.prepare([{ ...changedA, observedAt: now + .03 }], 1)).length, 0);
  } finally { await r.mf.dispose(); }
});

test('durable alarm dispatch runs APNs in the Worker and retires its outbox', async () => {
  const r = await runtime(), id = randomUUID();
  try {
    await r.receiver.register(id, { ...registration, liveActivities: { enabled: false } }, 'full', 1);
    assert.equal(await r.receiver.testNotification(id, 1), 'queued');
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline && (await r.receiver.diagnostics()).pending) await new Promise(resolve => setTimeout(resolve, 25));
    assert.equal(r.sent.length, 1);
    assert.equal((await r.receiver.diagnostics()).pending, 0);
    assert.equal(r.sent[0].body.aps.alert.title, 'Test notification');
  } finally { await r.mf.dispose(); }
});

test('Live Activity start, token, updates, end and revocation retain lifecycle guarantees', async () => {
  const r = await runtime(), id = randomUUID(), source = snapshot(id);
  try {
    await r.receiver.register(id, { ...registration, liveActivities: { ...registration.liveActivities, pushToStartToken: 'f'.repeat(64) } }, 'full', 1);
    const start = await r.receiver.prepare([source], 1);
    assert.equal(start.length, 1); assert.equal(start[0].live.event, 'start'); assert.equal(start[0].durable, true);
    await r.receiver.complete(start[0], 'accepted');
    await r.receiver.registerLiveActivity(id, 1, { activityID: 'active', activityToken: 'e'.repeat(64) });
    source.observedAt += .01; source.tasks[0].state = 'needsApproval';
    const update = await r.receiver.prepare([source], 1);
    assert.equal(update.length, 1); assert.equal(update[0].live.event, 'update'); assert.equal(update[0].durable, true);
    await r.receiver.complete(update[0], 'retry');
    assert.equal((await r.receiver.diagnostics()).pending, 1, 'An important state change can retry without another Mac batch');
    const done = structuredClone(source); done.observedAt += 1; done.tasks[0].state = 'completed'; (done.tasks[0] as any).eventAt = done.observedAt;
    const ending = await r.receiver.prepare([done], 1);
    assert.deepEqual(ending.map((j: any) => j.live?.event ?? j.alert.kind).sort(), ['completed', 'end']);
    await r.receiver.complete(update[0], 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 2, 'Completion replaces the stale approval update; its receipt cannot remove the new jobs');
    // A retry is durable even when no later Mac observation ever arrives.
    for (const job of ending) await r.receiver.complete(job, job.live ? 'retry' : 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 1);
    await r.receiver.revoke(id, 1);
    const revoked = await r.receiver.claimPending();
    assert.equal(revoked.length, 1); assert.equal(revoked[0].live.dismissImmediately, true);
    await r.receiver.complete(ending.find((j: any) => j.live), 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 1, 'Old end receipt must not remove the revocation job');
    await r.receiver.complete(revoked[0], 'accepted');
    assert.equal((await r.receiver.diagnostics()).pending, 0);
  } finally { await r.mf.dispose(); }
});
