import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { liveState, nextLiveTaskID, liveRecordMissingOnDevice, livePayload, liveSignature, liveUrgentSignature, livePhaseSignature, liveDeliveryIsUrgent, liveRefreshAfter, liveNeedsRenewal, liveLifetime, nextLiveEvent, type LiveRecord, type LiveMessage } from '../src/live-activities.ts';
import { sendLivePush } from '../src/apns.ts';
import type { Snapshot } from '../src/protocol.ts';
const snapshot = (): Snapshot => ({ schemaVersion: 1, id: '11111111-1111-4111-8111-111111111111', name: 'Test Mac', observedAt: 2000,
  tasks: [{ id: 'a', title: 'Working task', state: 'running', activity: 'Writing', tokensPerMinute: 500, totalTokens: 100, agentCount: 0 },
  { id: 'b', title: 'Review task', project: 'Project', state: 'needsApproval', activity: 'Waiting', tokensPerMinute: 0, totalTokens: 10, agentCount: 0 },
  { id: 'c', title: 'Old task', state: 'completed', activity: 'Completed', tokensPerMinute: 100, totalTokens: 10, agentCount: 0 }] });

test('refresh hints preserve prompt deadlines across lower-priority metrics and phases', () => {
  const state = liveState(snapshot());
  const record: LiveRecord = { state, token: 'aa', lastPromptSentAt: 2000, lastPhaseSignature: livePhaseSignature(state) };
  assert.equal(liveRefreshAfter(record, 2060), 60, 'A minute metric cannot postpone the 120-second prompt fallback');
  record.state = { ...state, activity: 'Thinking' };
  assert.equal(liveRefreshAfter(record, 2010, true), 20);
  assert.equal(liveRefreshAfter(record, 2010, false), 50);
  assert.equal(liveRefreshAfter(record, 2100), 5, 'Overdue hints remain bounded');
  assert.equal(liveRefreshAfter({ ...record, dismissed: true }, 2010), undefined);
  assert.equal(liveRefreshAfter({ ...record, state: { ...state, running: 0, attention: 0 } }, 2010), undefined);
});

test('foreground registry recovers missing mature activities without overriding dismissal or registration races', () => {
  const record: LiveRecord = { state: liveState(snapshot()), token: 'a'.repeat(64), activityID: 'old-card', registeredAt: 1940 };
  assert.equal(liveRecordMissingOnDevice(record, [], 2000), true);
  assert.equal(liveRecordMissingOnDevice(record, ['old-card'], 2000), false);
  assert.equal(liveRecordMissingOnDevice(record, undefined, 2000), false, 'Old clients and background wakes cannot retire a card');
  assert.equal(liveRecordMissingOnDevice({ ...record, registeredAt: 1999 }, [], 2000), false);
  assert.equal(liveRecordMissingOnDevice({ ...record, registeredAt: undefined, lastStartAt: 1900 }, [], 2000), true);
  assert.equal(liveRecordMissingOnDevice({ ...record, registeredAt: undefined }, [], 2000), true, 'Legacy records without an age can be reconciled');
  assert.equal(liveRecordMissingOnDevice({ ...record, dismissed: true }, [], 2000), false);
  assert.equal(liveRecordMissingOnDevice({ ...record, token: undefined }, [], 2000), false, 'An in-flight remote start is preserved');
});

test('task cycling wraps, excludes completed tasks and pins a running task despite attention', () => {
  const feed = snapshot();
  assert.equal(nextLiveTaskID(feed, 'b'), 'a');
  assert.equal(nextLiveTaskID(feed, 'a'), 'b');
  assert.equal(nextLiveTaskID(feed, 'missing'), 'b');
  assert.equal(nextLiveTaskID({ ...feed, tasks: [] }), undefined);
  const selected = liveState(feed, undefined, 'a');
  assert.equal(selected.taskID, 'a'); assert.equal(selected.taskIndex, 1);
  assert.equal(selected.selectionIsPinned, true); assert.equal(selected.tokensPerMinute, 500);
  feed.tasks[0].state = 'completed';
  assert.equal(liveState(feed, 'a', 'a').taskID, 'b');
  assert.equal(liveState(feed, 'a', 'a').selectionIsPinned, undefined);
});

test('Live Activity summary prioritizes attention and counts only active tasks', () => {
  const state = liveState(snapshot());
  assert.equal(state.taskID, 'b'); assert.equal(state.running, 1); assert.equal(state.attention, 1);
  assert.equal(state.tokensPerMinute, 0);
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
  record.lastSentAt = 2000; record.lastSignature = liveSignature(record.state); record.lastUrgentSignature = liveUrgentSignature(record.state); record.lastPhaseSignature = livePhaseSignature(record.state); record.lastPromptSentAt = 2000;
  record.state.tokensPerMinute = 900;
  assert.equal(nextLiveEvent(record, true, true, 2001), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2060), 'update');
  assert.equal(nextLiveEvent(record, true, true, 2200), undefined);
  record.state.state = 'needsInput';
  assert.equal(nextLiveEvent(record, true, true, 2001), 'update');
  assert.equal(nextLiveEvent(record, false, true, 2001), 'end');
  assert.equal(nextLiveEvent({ ...record, dismissed: true }, true, true, 2001), undefined);
  record.state = liveState({ ...snapshot(), tasks: [] });
  assert.equal(nextLiveEvent(record, true, true, 2001), 'end');
});
test('foreground reservation blocks racing remote starts without blocking registered updates', () => {
  const record: LiveRecord = { state: liveState(snapshot()), foregroundStartUntil: 2015 };
  assert.equal(nextLiveEvent(record, true, true, 2001), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2015), 'start', 'A crashed foreground request cannot suppress later starts forever');
  assert.equal(nextLiveEvent({ ...record, token: 'aa' }, true, true, 2001), 'update');
  assert.equal(nextLiveEvent({ ...record, deliveryBlocked: true }, true, true, 2015), undefined);
  assert.equal(nextLiveEvent({ ...record, dismissed: true }, true, true, 2015), undefined);
});
test('ActivityKit payload uses native attributes, Unix timestamps, stale and dismissal dates', () => {
  const message: LiveMessage = { event: 'start', state: liveState(snapshot()), macID: snapshot().id, macName: 'Mac', timestamp: 2001 };
  const start = JSON.parse(livePayload(message));
  assert.equal(start.aps['attributes-type'], 'CompanionActivityAttributes');
  assert.equal(start.aps.attributes.macID, message.macID);
  assert.equal(start.aps['content-state'].updatedAt, 2000);
  assert.equal(start.aps['stale-date'], 2180);
  // Delivery ordering and observation age are separate: delayed delivery must
  // not renew a Mac observation's stale deadline.
  const delayed = JSON.parse(livePayload({ ...message, event: 'update', timestamp: 2060 }));
  assert.equal(delayed.aps.timestamp, 2060);
  assert.equal(delayed.aps['content-state'].updatedAt, 2000);
  assert.equal(delayed.aps['stale-date'], 2180);
  assert.ok(start.aps.alert);
  const ended = JSON.parse(livePayload({ ...message, event: 'end' }));
  assert.equal(ended.aps['dismissal-date'], 2000, 'Ordinary completion dismisses the card immediately');
  const empty = snapshot(); empty.tasks = [];
  const emptyState = liveState(empty);
  assert.equal(nextLiveEvent({ state: emptyState }, true, true, 2001), undefined, 'No activity starts without active tasks');
  assert.equal(nextLiveEvent({ state: emptyState, token: 'a'.repeat(64) }, true, true, 2001), 'end');
  const emptied = JSON.parse(livePayload({ ...message, event: 'end', state: emptyState }));
  assert.equal(emptied.aps['dismissal-date'], 2000, 'An empty task snapshot must not retain a no-active-tasks card');
  const revoked = JSON.parse(livePayload({ ...message, event: 'end', dismissImmediately: true }));
  assert.equal(revoked.aps['dismissal-date'], 2000, 'Access removal dismisses the entire card immediately');
  assert.equal(ended.aps.attributes, undefined);
  assert.equal(ended.aps['stale-date'], undefined);
  const large = snapshot(); large.name = '🧑🏽‍💻'.repeat(10); large.tasks[1].title = '🧑🏽‍💻'.repeat(200);
  assert.ok(Buffer.byteLength(livePayload({ ...message, state: liveState(large), macName: large.name })) <= 4096);
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
  assert.equal(payload.aps['stale-date'], 2180);
  feed.tasks[0].state = 'completed';
  assert.equal(liveState(feed, selected.id).taskID, 'new');
  feed.tasks.unshift({ ...feed.tasks[1], id: 'attention', state: 'needsApproval' });
  assert.equal(liveState(feed, 'new').taskID, 'attention');
});

test('selected task rate, source heartbeat, and bounded metric updates stay independent', () => {
  const feed = snapshot(); feed.tasks = [feed.tasks[0], { ...feed.tasks[0], id: 'other', tokensPerMinute: 9000 }];
  feed.tasks[0].observedAt = 1000;
  const state = liveState(feed, 'a'); assert.equal(state.tokensPerMinute, 500);
  const record: LiveRecord = { state, token: 'a'.repeat(64), lastSentAt: 2000,
    lastSignature: liveSignature(state), lastUrgentSignature: liveUrgentSignature(state), lastPhaseSignature: livePhaseSignature(state), lastPromptSentAt: 2000 };
  state.tokensPerMinute = 750; state.contextPercent = 40; state.activity = 'Using a tool';
  assert.equal(nextLiveEvent(record, true, true, 2001, true), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2005, true), 'update');
  assert.equal(nextLiveEvent(record, true, true, 2005, false), 'update', 'Phases are events regardless of the metric cadence');
  assert.equal(nextLiveEvent(record, true, true, 2015, false), 'update');
  assert.equal(record.lastUrgentSignature, liveUrgentSignature(state), 'Metrics and phase use low priority');
  state.state = 'needsInput'; assert.equal(nextLiveEvent(record, true, true, 2001, false), 'update');
  const aps = JSON.parse(livePayload({ event: 'update', state, macID: feed.id, macName: 'Mac', timestamp: 2001 })).aps;
  assert.equal(aps['stale-date'], 2180, 'A fresh Mac observation does not expire with the last task event');
});

test('minute metrics and two-minute freshness do not suppress immediate task transitions', () => {
  const state = { ...liveState(snapshot()), state: 'running', activity: 'Thinking' };
  const record: LiveRecord = { state, token: 'a'.repeat(64), lastSentAt: 2000, lastPromptSentAt: 2000,
    lastSignature: liveSignature(state), lastUrgentSignature: liveUrgentSignature(state), lastPhaseSignature: livePhaseSignature(state) };
  record.state = { ...state, tokensPerMinute: 1200, contextPercent: 48 };
  for (const frequent of [true, false]) {
    assert.equal(nextLiveEvent(record, true, true, 2059, frequent), undefined);
    assert.equal(nextLiveEvent(record, true, true, 2060, frequent), 'update');
  }
  record.lastSignature = liveSignature(record.state);
  assert.equal(nextLiveEvent(record, true, true, 2119), undefined);
  assert.equal(nextLiveEvent(record, true, true, 2120), 'update');
  record.state.state = 'needsApproval';
  assert.equal(nextLiveEvent(record, true, true, 2001), 'update');
});

test('phase changes receive coalesced prompt delivery while rate-only updates remain low priority', () => {
  const state = { ...liveState(snapshot()), state: 'running', activity: 'Thinking' };
  const record: LiveRecord = { state, token: 'a'.repeat(64), lastSentAt: 2000, lastPromptSentAt: 2000,
    lastSignature: liveSignature(state), lastUrgentSignature: liveUrgentSignature(state), lastPhaseSignature: livePhaseSignature(state) };
  record.state = { ...state, activity: 'Using a tool', tokensPerMinute: 1250, contextPercent: 48 };
  assert.equal(liveDeliveryIsUrgent(record, 2029, true), false);
  assert.equal(liveDeliveryIsUrgent(record, 2030, true), true);
  assert.equal(nextLiveEvent(record, true, true, 2030, true), 'update');
  assert.equal(liveDeliveryIsUrgent(record, 2059, false), false);
  assert.equal(liveDeliveryIsUrgent(record, 2060, false), true);
  record.lastPhaseSignature = livePhaseSignature(record.state);
  assert.equal(liveDeliveryIsUrgent(record, 2060, true), false);
  assert.equal(liveDeliveryIsUrgent(record, 2120, true), true, 'Freshness reaches the phone before the stale deadline even when low-priority pushes are delayed');
  record.state.state = 'needsApproval';
  assert.equal(liveDeliveryIsUrgent(record, 2001, false), true, 'Approval bypasses the phase debounce');
});

test('long-running tasks renew their card before ActivityKit freezes it at eight hours', () => {
  const now = 2000 + liveLifetime;
  const state = { ...liveState(snapshot()), state: 'running', running: 1, attention: 0, updatedAt: now, startedAt: 1000 };
  const record: LiveRecord = { state, token: 'a'.repeat(64), lastStartAt: 2000, lastSentAt: now,
    lastSignature: liveSignature(state), lastUrgentSignature: liveUrgentSignature(state), lastPhaseSignature: livePhaseSignature(state), lastPromptSentAt: now };
  assert.equal(liveNeedsRenewal(record, now - 1), false);
  assert.equal(liveNeedsRenewal(record, now), true);
  assert.equal(nextLiveEvent(record, true, true, now), 'end');
  const replacement: LiveRecord = { state };
  assert.equal(nextLiveEvent(replacement, true, true, now + 1), 'start');
  assert.equal(replacement.state.startedAt, 1000, 'Renewal must preserve the current turn elapsed clock');
  assert.equal(nextLiveEvent({ ...replacement, dismissed: true }, true, true, now + 1), undefined);
});

test('next-task preview uses the current ordered roster and bounded native payload', () => {
  const feed = snapshot(); feed.tasks[0].contextPercent = 47;
  const selected = liveState(feed, undefined, 'b');
  assert.equal(selected.nextTask?.taskID, 'a');
  assert.equal(selected.nextTask?.tokensPerMinute, 500);
  assert.equal(selected.nextTask?.contextPercent, 47);
  assert.equal(selected.nextTask?.taskIndex, 1);
  assert.equal(liveState({ ...feed, tasks: [feed.tasks[0]] }).nextTask, undefined);
  const payload = JSON.parse(livePayload({event:'update',state:selected,macID:feed.id,macName:feed.name,timestamp:2001}));
  assert.equal(payload.aps['content-state'].deliveryTimestamp, 2001);
  assert.equal(payload.aps['content-state'].nextTask.taskID, 'a');
  assert.equal(payload.aps['stale-date'], 2180);
  feed.tasks[0].id = '界'.repeat(200); feed.tasks[1].id = '界'.repeat(200);
  for (const task of feed.tasks) { task.title = '界'.repeat(200); task.project = '界'.repeat(200); }
  const large = livePayload({event:'start',state:liveState(feed),macID:feed.id,macName:'界'.repeat(200),timestamp:2001});
  assert.ok(Buffer.byteLength(large) <= 4096);
});
