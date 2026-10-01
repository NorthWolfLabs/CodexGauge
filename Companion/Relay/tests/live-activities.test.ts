import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { liveState, livePayload, liveSignature, liveObservationRecovered, nextLiveEvent, needsLiveAlarm, type LiveRecord, type LiveMessage } from '../src/live-activities.ts';
import { sendLivePush } from '../src/apns.ts';
import type { Snapshot } from '../src/protocol.ts';
const snapshot = (): Snapshot => ({ schemaVersion: 1, id: '11111111-1111-4111-8111-111111111111', name: 'Test Mac', observedAt: 2000,
  tasks: [{ id: 'a', title: 'Working task', state: 'running', activity: 'Writing', tokensPerMinute: 500, totalTokens: 100, agentCount: 0 },
  { id: 'b', title: 'Review task', project: 'Project', state: 'needsApproval', activity: 'Waiting', tokensPerMinute: 0, totalTokens: 10, agentCount: 0 },
  { id: 'c', title: 'Old task', state: 'completed', activity: 'Completed', tokensPerMinute: 100, totalTokens: 10, agentCount: 0 }] });

test('only fresh task evidence triggers immediate stale-state recovery', () => {
  const old = { ...liveState(snapshot()), taskObservedAt: 1700 };
  const heartbeat = { ...old, updatedAt: 2001 };
  assert.equal(liveObservationRecovered(old, heartbeat, 2001), false);
  const fresh = { ...heartbeat, taskObservedAt: 2001 };
  assert.equal(liveObservationRecovered(old, fresh, 2001), true);
  assert.equal(liveObservationRecovered(fresh, { ...fresh, updatedAt: 2002 }, 2002), false);
  assert.equal(liveObservationRecovered(undefined, fresh, 2001), false);
});

test('Live Activity summary prioritizes attention and counts only active tasks', () => {
  const state = liveState(snapshot());
  assert.equal(state.taskID, 'b'); assert.equal(state.running, 1); assert.equal(state.attention, 1);
  assert.equal(state.tokensPerMinute, 500);
  assert.equal(liveState({ ...snapshot(), tasks: [] }).state, 'idle');
});
test('Live Activities start, throttle metrics, update attention, end and respect dismissals', () => {
  const record: LiveRecord = { state: liveState(snapshot()) };
  assert.equal(nextLiveEvent(record, false, true, 2001), undefined);
  assert.equal(nextLiveEvent(record, true, false, 2001), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2001), 'start');
  assert.equal(nextLiveEvent({ ...record, lastStartAt: 2000 }, true, true, 2001), undefined);
  assert.equal(nextLiveEvent({ ...record, startAttempts: 3 }, true, true, 2001), undefined);
  record.token = 'a'.repeat(64);
  assert.equal(nextLiveEvent(record, true, true, 2001), 'update');
  record.lastSentAt = 2000; record.lastSignature = liveSignature(record.state);
  record.state.tokensPerMinute = 900;
  assert.equal(nextLiveEvent(record, true, true, 2001), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2060), 'update');
  assert.equal(nextLiveEvent(record, true, true, 2100), undefined);
  record.state.state = 'needsInput';
  assert.equal(nextLiveEvent(record, true, true, 2001), 'update');
  assert.equal(nextLiveEvent(record, false, true, 2001), 'end');
  assert.equal(nextLiveEvent({ ...record, dismissed: true }, true, true, 2001), undefined);
  record.state = liveState({ ...snapshot(), tasks: [] });
  assert.equal(nextLiveEvent(record, true, true, 2001), 'end');
});
test('ActivityKit payload uses native attributes, Unix timestamps, stale and dismissal dates', () => {
  const message: LiveMessage = { event: 'start', state: liveState(snapshot()), macID: snapshot().id, macName: 'Mac', timestamp: 2001 };
  const start = JSON.parse(livePayload(message));
  assert.equal(start.aps['attributes-type'], 'CompanionActivityAttributes');
  assert.equal(start.aps.attributes.macID, message.macID);
  assert.equal(start.aps['content-state'].updatedAt, 2000);
  assert.equal(start.aps['stale-date'], 2090);
  // Delivery ordering and observation age are separate: delayed delivery must
  // not renew a Mac observation's stale deadline.
  const delayed = JSON.parse(livePayload({ ...message, event: 'update', timestamp: 2060 }));
  assert.equal(delayed.aps.timestamp, 2060);
  assert.equal(delayed.aps['content-state'].updatedAt, 2000);
  assert.equal(delayed.aps['stale-date'], 2090);
  assert.ok(start.aps.alert);
  const ended = JSON.parse(livePayload({ ...message, event: 'end' }));
  assert.equal(ended.aps['dismissal-date'], 2061);
  const revoked = JSON.parse(livePayload({ ...message, event: 'end', dismissImmediately: true }));
  assert.equal(revoked.aps['dismissal-date'], 2000, 'Access removal dismisses the entire card immediately');
  assert.equal(ended.aps.attributes, undefined);
  assert.equal(ended.aps['stale-date'], undefined);
  const large = snapshot(); large.name = '🧑🏽‍💻'.repeat(10); large.tasks[1].title = '🧑🏽‍💻'.repeat(200);
  assert.ok(Buffer.byteLength(livePayload({ ...message, state: liveState(large), macName: large.name })) <= 4096);
});
test('Live Activity alarms stop for stale Macs but continue bounded end retries', () => {
  const record: LiveRecord = { state: liveState(snapshot()), token: 'a'.repeat(64) };
  assert.equal(needsLiveAlarm(record, true, true, 2100), false);
  assert.equal(needsLiveAlarm(record, false, true, 2100), true);
  record.state = liveState({ ...snapshot(), tasks: [] });
  record.retryAt = 2160;
  assert.equal(needsLiveAlarm(record, true, true, 2100), true);
  assert.equal(nextLiveEvent(record, true, true, 2100), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2160), 'end');
  assert.equal(needsLiveAlarm({ ...record, attempts: 8 }, true, true, 2100), false);
  assert.equal(needsLiveAlarm({ state: liveState(snapshot()), startAttempts: 3 }, true, true, 2001), false);
  assert.equal(needsLiveAlarm({ state: liveState(snapshot()) }, true, false, 2001), false);
});
test('Live Activity APNs requests use the activity topic, token and appropriate priority', async () => {
  const keys = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const env = { APNS_PRIVATE_KEY: Buffer.from(await crypto.subtle.exportKey('pkcs8', keys.privateKey)).toString('base64'), APNS_TEAM_ID: 'TEST', APNS_KEY_ID: 'LIVE', APNS_BUNDLE_ID: 'example.test' } as Env;
  const previous = globalThis.fetch;
  try {
    globalThis.fetch = async (url, options) => {
      assert.equal(String(url), 'https://api.sandbox.push.apple.com/3/device/' + 'b'.repeat(64));
      const headers = new Headers(options?.headers);
      assert.equal(headers.get('apns-topic'), 'example.test.push-type.liveactivity');
      assert.equal(headers.get('apns-push-type'), 'liveactivity');
      assert.equal(headers.get('apns-priority'), '5');
      assert.equal(options?.redirect, 'manual');
      return new Response(null, { status: 200 });
    };
    assert.equal(await sendLivePush(env, { token: 'b'.repeat(64), environment: 'sandbox', kinds: [] },
      { event: 'update', state: liveState(snapshot()), macID: snapshot().id, macName: 'Mac', timestamp: 2001 }, false), 'accepted');
  } finally { globalThis.fetch = previous; }
});
test('Swift ActivityKit content matches server-generated state exactly', { skip: !process.env.COMPANION_WIRE_FIXTURE_PATH }, async () => {
  const fixtures = JSON.parse(await readFile(process.env.COMPANION_WIRE_FIXTURE_PATH! + '.live', 'utf8')) as { snapshot: Snapshot; state: unknown }[];
  for (const fixture of fixtures) assert.deepEqual(JSON.parse(JSON.stringify(liveState(fixture.snapshot))), fixture.state);
});

test('stable selection keeps task evidence age separate from fresh aggregate updates', () => {
  const feed = snapshot();
  const selected = { ...feed.tasks[0], state: 'needsInput' as const, observedAt: 1700, startedAt: 1600 };
  feed.tasks = [selected, { ...feed.tasks[0], id: 'new', state: 'running', startedAt: 1999, observedAt: 2000 }];
  const state = liveState(feed, selected.id);
  assert.equal(state.taskID, selected.id);
  assert.equal(state.updatedAt, 2000);
  assert.equal(state.taskObservedAt, 1700);
  assert.equal(state.running, 1);
  const record: LiveRecord = { state, token: 'a'.repeat(64), lastSignature: 'previous', lastSentAt: 1900 };
  assert.equal(nextLiveEvent(record, true, true, 2001), 'update');
  const payload = JSON.parse(livePayload({ event: 'update', state, macID: feed.id, macName: feed.name, timestamp: 2001 }));
  assert.equal(payload.aps['stale-date'], 1790);
  feed.tasks[0].state = 'completed';
  assert.equal(liveState(feed, selected.id).taskID, 'new');
  feed.tasks.unshift({ ...feed.tasks[1], id: 'attention', state: 'needsApproval' });
  assert.equal(liveState(feed, 'new').taskID, 'attention');
});
