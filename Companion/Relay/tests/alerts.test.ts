import assert from 'node:assert/strict';
import { test } from 'node:test';
import { changes, receiverChanges, alertSignature } from '../src/alerts.ts';
import { providerToken, sendPush } from '../src/apns.ts';
import type { Snapshot } from '../src/protocol.ts';
const initial = (): Snapshot => ({ schemaVersion: 1, id: '33333333-3333-4333-8333-333333333333', name: 'Test Mac', observedAt: 1000,
  account: { id: 'same-account', observedAt: 1000, windows: [{ id: 'weekly', name: 'Weekly', remainingPercent: 60, resetsAt: 1100 }], bankedResets: 2, dailyTokens: [] },
  tasks: [{ id: 'task', title: 'Build mobile', project: 'CodexGauge', state: 'running', activity: 'Working', startedAt: 990, tokensPerMinute: 3, totalTokens: 100, agentCount: 0 }] });
test('live token ticks do not require persistent writes, but state changes do', () => {
  const before = initial(), after = structuredClone(before);
  after.observedAt++; after.account!.observedAt++; after.tasks[0].tokensPerMinute = 900;
  assert.equal(alertSignature(before), alertSignature(after));
  after.tasks[0].state = 'needsInput';
  assert.notEqual(alertSignature(before), alertSignature(after));
});
test('first observation and disappearing tasks never produce completions', () => {
  const before = initial();
  assert.deepEqual(changes(undefined, before), []);
  assert.deepEqual(changes(before, { ...before, observedAt: 1001, tasks: [] }), []);
});
test('explicit completion identifies its task, project and Mac without live catch-up text', () => {
  const before = initial(), after = structuredClone(before); after.observedAt++;
  after.tasks[0].state = 'completed'; after.tasks[0].eventAt = 1001;
  const events = changes(before, after);
  assert.equal(events.length, 1); assert.equal(events[0].kind, 'completed');
  assert.equal(events[0].body, 'Build mobile\nCodexGauge\nTest Mac');
});
test('historical tasks are baselined; an actual later turn can emit a working alert', () => {
  const before = initial(), after = structuredClone(before); after.observedAt = 1002;
  after.tasks.push({ ...after.tasks[0], id: 'history', state: 'completed', eventAt: 900 });
  assert.equal(changes(before, after).length, 0);
  after.tasks[0].startedAt = 1001;
  assert.equal(changes(before, after)[0].kind, 'working');
});
test('catch-up adds the observation window and unchanged active tasks stay quiet', () => {
  const before = initial(), after = structuredClone(before); after.observedAt = 2000;
  assert.deepEqual(changes(before, after), []);
  after.tasks[0].state = 'needsApproval'; after.tasks[0].eventAt = 1950;
  assert.match(changes(before, after)[0].body, /Observed between/);
});
test('account comparisons detect resets and low crossings once; unrelated accounts stay separate', () => {
  const before = initial(), after = structuredClone(before); after.observedAt = 1200;
  after.account!.observedAt = 1200; after.account!.windows[0].resetsAt = 2200;
  after.account!.windows[0].remainingPercent = 10; after.account!.bankedResets = 3;
  assert.deepEqual(changes(before, after).map(e => e.kind), ['low', 'allowance', 'banked']);
  assert.deepEqual(changes(after, { ...after, observedAt: 1201, account: { ...after.account!, observedAt: 1201 } }), []);
  after.account!.id = 'different-account'; assert.deepEqual(changes(before, after), []);
});
test('APNs tokens are ES256 signatures and no configuration sends no request', async () => {
  assert.equal(await providerToken({} as Env), undefined);
  assert.equal(await sendPush({} as Env, { token: 'f'.repeat(64), environment: 'sandbox', kinds: [] }, { id: 'test', kind: 'low', title: 'Low', body: '10%', at: 1000, macID: 'test' }), 'not-configured');
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pem = Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64');
  const jwt = (await providerToken({ APNS_PRIVATE_KEY: pem, APNS_TEAM_ID: 'TESTTEAM', APNS_KEY_ID: 'TESTKEY' } as Env, 1000000))!;
  const [header, payload, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url').toString()), { iss: 'TESTTEAM', iat: 1000 });
  assert.equal(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, keys.publicKey, Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${payload}`)), true);
});

test('APNs reuses concurrent provider tokens, refreshes before expiry, and respects key rotation', async () => {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pem = Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64');
  const env = { APNS_PRIVATE_KEY: pem, APNS_TEAM_ID: 'TESTTEAM', APNS_KEY_ID: 'CACHEKEY' } as Env;
  const start = 10_000_000;
  const first = await Promise.all([providerToken(env, start), providerToken(env, start)]);
  assert.equal(first[0], first[1]);
  assert.equal(await providerToken(env, start + 49 * 60_000), first[0]);
  const refreshed = await providerToken(env, start + 50 * 60_000);
  assert.notEqual(refreshed, first[0]);
  assert.equal(JSON.parse(Buffer.from(refreshed!.split('.')[1], 'base64url').toString()).iat, (start + 50 * 60_000) / 1000);
  const rotated = await providerToken({ ...env, APNS_KEY_ID: 'ROTATED' } as Env, start + 51 * 60_000);
  assert.equal(JSON.parse(Buffer.from(rotated!.split('.')[0], 'base64url').toString()).kid, 'ROTATED');
});

test('APNs separates permanent registration/configuration errors from retryable delivery failures', async () => {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const env = { APNS_PRIVATE_KEY: Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64'),
    APNS_TEAM_ID: 'TESTTEAM', APNS_KEY_ID: 'ERRORKEY', APNS_BUNDLE_ID: 'example.test' } as Env;
  const original = globalThis.fetch;
  try {
    for (const [status, reason, expected] of [
      [200, '', 'accepted'], [302, '', 'rejected'], [400, 'BadDeviceToken', 'invalid-token'], [400, 'DeviceTokenNotForTopic', 'invalid-token'],
      [410, 'Unregistered', 'invalid-token'], [403, 'InvalidProviderToken', 'configuration-error'],
      [403, 'BadEnvironmentKeyIdInToken', 'configuration-error'], [403, 'ExpiredProviderToken', 'retry'],
      [429, 'TooManyRequests', 'retry'], [503, 'ServiceUnavailable', 'retry'], [413, 'PayloadTooLarge', 'rejected'],
    ] as const) {
      globalThis.fetch = async (_url, options) => {
        assert.equal(options?.redirect, 'manual', 'Workers must reject redirects without using its unsupported error mode');
        return new Response(JSON.stringify({ reason }), { status });
      };
      assert.equal(await sendPush(env, { token: 'f'.repeat(64), environment: 'sandbox', kinds: [] },
        { id: 'test', kind: 'completed', title: 'Test', body: 'Synthetic', at: 1000, macID: 'test' }), expected);
    }
  } finally { globalThis.fetch = original; }
});

test('two Macs seeing the same banked reset produce one account alert and retain their own task alerts', () => {
  const first = initial(), second = { ...initial(), id: '44444444-4444-4444-8444-444444444444' };
  const updatedFirst = structuredClone(first); updatedFirst.observedAt += 1;
  updatedFirst.account!.observedAt += 1; updatedFirst.account!.bankedResets = 3;
  const a = receiverChanges(first, first.account, updatedFirst);
  assert.deepEqual(a.events.map(e => e.kind), ['banked']);
  const updatedSecond = structuredClone(second); updatedSecond.observedAt += 2;
  updatedSecond.account!.observedAt += 2; updatedSecond.account!.bankedResets = 3;
  updatedSecond.tasks[0].state = 'needsInput'; updatedSecond.tasks[0].eventAt = 1002;
  const b = receiverChanges(second, a.account, updatedSecond);
  assert.deepEqual(b.events.map(e => e.kind), ['attention']);
  assert.equal(b.events[0].macID, second.id);
  assert.deepEqual(receiverChanges(updatedSecond, b.account, second).events, []);
});

test('APNs payloads fit the byte limit without splitting emoji or losing task routing', async () => {
  const { notificationPayload } = await import('../src/apns.ts');
  const event = { id: 'unicode', kind: 'completed' as const, title: 'Task completed',
    body: '🧑🏽‍💻'.repeat(500), macID: '11111111-1111-4111-8111-111111111111', taskID: 'a'.repeat(64), at: 1000 };
  const payload = notificationPayload(event)!;
  assert.ok(Buffer.byteLength(payload) <= 4096);
  const parsed = JSON.parse(payload);
  assert.equal(parsed.macID, event.macID);
  assert.equal(parsed.taskID, event.taskID);
  assert.equal(parsed.aps.alert.title, event.title);
  assert.match(parsed.aps.alert.body, /^(🧑🏽‍💻)+…$/u);
  const escaped = notificationPayload({ ...event, body: '\"\\\n'.repeat(1000) })!;
  assert.ok(Buffer.byteLength(escaped) <= 4096);
  assert.equal(JSON.parse(notificationPayload({ ...event, body: 'Normal task' })!).aps.alert.body, 'Normal task');
  assert.ok(Buffer.byteLength(notificationPayload({ ...event, title: '界'.repeat(4000) })!) <= 4096);
});
