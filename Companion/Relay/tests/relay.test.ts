import assert from 'node:assert/strict';
import { test, after } from 'node:test';
import { randomBytes, randomUUID } from 'node:crypto';
import WebSocket from 'ws';

const base = process.env.RELAY_URL ?? 'http://127.0.0.1:8789';
const credential = () => randomBytes(32).toString('hex');
const created: { id: string; publisher: string }[] = [];
after(async () => {
  for (const keys of created) {
    const response = await fetch(`${base}/v1/macs/${keys.id}/feed`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${keys.publisher}` },
    });
    assert.ok([200, 401].includes(response.status), 'Disposable test feed cleanup failed');
  }
});
async function create() {
  const id = randomUUID(), publisher = credential(), reader = credential(), usageReader = credential();
  const response = await fetch(`${base}/v1/macs/${id}/initialize`, {
    method: 'POST', headers: { Authorization: `Bearer ${publisher}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader, usageReader }),
  });
  assert.equal(response.status, 200);
  created.push({ id, publisher });
  return { id, publisher, reader, usageReader };
}
function open(id: string, token: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`${base.replace('http', 'ws')}/v1/macs/${id}/stream`, { headers: { Authorization: `Bearer ${token}` } });
    socket.once('open', () => resolve(socket)); socket.once('error', reject);
  });
}
function next(socket: WebSocket): Promise<{ type: string }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out awaiting relay response')), 3000);
    socket.once('message', message => { clearTimeout(timer); resolve(JSON.parse(message.toString())); });
  });
}
function snapshot(id: string) {
  return { schemaVersion: 1, id, name: 'Test Mac', observedAt: Date.now() / 1000,
    account: { id: 'shared-account', plan: 'Pro', observedAt: Date.now() / 1000, windows: [{ id: 'weekly', name: 'Weekly', remainingPercent: 70 }], dailyTokens: [] },
    tasks: [{ id: 'task', title: 'Private test task', state: 'needsApproval', activity: 'Waiting', tokensPerMinute: 0, totalTokens: 30, agentCount: 0 }] };
}

test('publisher relays state, usage sharing strips tasks, unauthorized reads fail', async () => {
  const keys = await create();
  const publisher = await open(keys.id, keys.publisher);
  try {
    const ack = next(publisher); publisher.send(JSON.stringify(snapshot(keys.id)));
    assert.equal((await ack).type, 'accepted');
    for (const [token, tasks] of [[keys.reader, 1], [keys.usageReader, 0]] as const) {
      const response = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${token}` } });
      assert.equal(response.status, 200);
      const value = await response.json() as { snapshot: { tasks: unknown[] } };
      assert.equal(value.snapshot.tasks.length, tasks);
    }
    const denied = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${credential()}` } });
    assert.equal(denied.status, 401);
  } finally { publisher.close(); }
});

test('a missing mature activity is retired on foreground registration, while fresh cards and explicit dismissals survive', async () => {
  const keys = await create(), pushToken = credential();
  const post = (action: string, body: unknown) => fetch(`${base}/v1/macs/${keys.id}/${action}`, {
    method: 'POST', headers: { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const publisher = await open(keys.id, keys.publisher);
  try {
    const feed = snapshot(keys.id); const ack = next(publisher); publisher.send(JSON.stringify(feed)); await ack;
    const registration = { token: pushToken, environment: 'sandbox', kinds: [], liveActivities: { enabled: true, pushToStartToken: credential() } };
    assert.equal((await post('notifications', registration)).status, 200);
    const card = { token: pushToken, environment: 'sandbox', activityID: 'orphaned-card', activityToken: credential() };
    assert.equal((await post('live-activity', card)).status, 200);
    const empty = { ...registration, liveActivities: { ...registration.liveActivities, activeActivityIDs: [] } };
    assert.equal((await post('notifications', empty)).status, 200);
    // Selection requires a paired device. Bind the same subscriber identity.
    const phone = { id: randomUUID(), name: 'Recovery phone', token: credential() };
    assert.equal((await post('pair', phone)).status, 200);
    const select = (activityID = 'orphaned-card') => fetch(`${base}/v1/macs/${keys.id}/live-selection`, { method: 'POST',
      headers: { Authorization: `Bearer ${phone.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ activityID }) });
    const registerPaired = (body: unknown) => fetch(`${base}/v1/macs/${keys.id}/notifications`, { method: 'POST',
      headers: { Authorization: `Bearer ${phone.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    assert.equal((await registerPaired(empty)).status, 200);
    assert.equal((await select()).status, 200, 'A fresh card survives an earlier empty registry report');
    await new Promise(resolve => setTimeout(resolve, 30_100));
    assert.equal((await registerPaired(empty)).status, 200);
    assert.equal((await select()).status, 409, 'The orphaned activity token is retired');
    assert.equal((await post('live-activity', { ...card, activityID: 'replacement-card' })).status, 200);
    assert.equal((await select('replacement-card')).status, 200);
    assert.equal((await post('live-activity', { ...card, activityID: 'replacement-card', activityToken: undefined, dismissed: true })).status, 200);
    assert.equal((await registerPaired(empty)).status, 200);
    assert.equal((await select('replacement-card')).status, 409, 'Explicit dismissal survives ordinary registration');
  } finally { publisher.close(); }
});

test('Live Activity cycling is device-scoped and receives phase/context/rate before the alert checkpoint', async () => {
  const keys = await create();
  const device = { id: randomUUID(), name: 'Cycle phone', token: credential() };
  const other = { id: randomUUID(), name: 'Other phone', token: credential() };
  const send = (action: string, bearer: string, body: unknown) => fetch(`${base}/v1/macs/${keys.id}/${action}`, {
    method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  assert.equal((await send('pair', keys.reader, device)).status, 200);
  assert.equal((await send('pair', keys.reader, other)).status, 200);
  const publisher = await open(keys.id, keys.publisher);
  const observedAt = Date.now() / 1000;
  const feed = { schemaVersion: 1, id: keys.id, name: 'Cycle Mac', observedAt,
    tasks: ['a', 'b'].map((id, index) => ({ id, title: 'Task ' + id, project: 'Review', state: 'running', activity: 'Thinking',
      contextPercent: 40, tokensPerMinute: 100, totalTokens: 1000, agentCount: 0, startedAt: observedAt - 20 + index * 5 })) };
  const publish = async () => { const ack = next(publisher); publisher.send(JSON.stringify(feed)); assert.equal((await ack).type, 'accepted'); };
  try {
    await publish();
    const regularToken = credential();
    assert.equal((await send('notifications', device.token, { token: regularToken, environment: 'sandbox', kinds: [], liveActivities: { enabled: true } })).status, 200);
    assert.equal((await send('live-activity', device.token, { token: regularToken, environment: 'sandbox', activityID: 'cycle-card', activityToken: credential() })).status, 200);
    const select = async (afterTaskID: string) => {
      const response = await send('live-selection', device.token, { activityID: 'cycle-card', afterTaskID });
      assert.equal(response.status, 200);
      return await response.json() as { state: { taskID: string; taskIndex: number; selectionIsPinned: boolean; activity: string; contextPercent: number; tokensPerMinute: number }; deliveryTimestamp: number };
    };
    assert.equal((await select('a')).state.taskID, 'b');
    // Same lifecycle/alert fields, under 30 seconds: this used to be withheld
    // from PushReceiver even though foreground viewers saw it immediately.
    feed.observedAt += 0.5;
    Object.assign(feed.tasks[1], { activity: 'Using a tool', contextPercent: 67, tokensPerMinute: 8400 });
    await publish();
    const changed = await select('a');
    assert.equal(changed.state.taskID, 'b'); assert.equal(changed.state.taskIndex, 1);
    assert.equal(changed.state.selectionIsPinned, true);
    assert.equal(changed.state.activity, 'Using a tool'); assert.equal(changed.state.contextPercent, 67);
    assert.equal(changed.state.tokensPerMinute, 8400);
    assert.ok(Math.abs(changed.deliveryTimestamp - Date.now() / 1000) < 2);
    assert.equal((await select('b')).state.taskID, 'a');
    for (const bearer of [keys.reader, keys.usageReader, keys.publisher]) {
      assert.equal((await send('live-selection', bearer, { activityID: 'cycle-card', afterTaskID: 'a' })).status, 403);
    }
    assert.equal((await send('live-selection', other.token, { activityID: 'cycle-card', afterTaskID: 'a' })).status, 409);
    assert.equal((await send('live-selection', device.token, { activityID: 'cycle-card', deviceID: other.id })).status, 400);
    assert.equal((await send('live-selection', device.token, { activityID: 'wrong-card' })).status, 409);
    const remove = await fetch(`${base}/v1/macs/${keys.id}/devices`, { method: 'DELETE', headers: { Authorization: `Bearer ${keys.publisher}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: device.id }) });
    assert.equal(remove.status, 200);
    assert.equal((await send('live-selection', device.token, { activityID: 'cycle-card' })).status, 401);
  } finally { publisher.close(); }
});

test('reader cannot inject snapshots or commands toward a publisher', async () => {
  const keys = await create();
  const viewer = await open(keys.id, keys.reader);
  try {
    const closed = new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Reader was not rejected as a publisher')), 3000);
      viewer.once('close', code => { clearTimeout(timer); resolve(code); });
    });
    viewer.send(JSON.stringify({ command: 'run', payload: 'anything' }));
    assert.equal(await closed, 1008);
    const response = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
    assert.equal((await response.json() as { type: string }).type, 'waiting');
  } finally { viewer.close(); }
});

test('an open viewer receives successive live snapshots without polling', async () => {
  const keys = await create(), publisher = await open(keys.id, keys.publisher);
  const viewer = await open(keys.id, keys.reader);
  const observedAt = Date.now() / 1000;
  try {
    for (let counter = 1; counter <= 2; counter++) {
      const received = new Promise<{ snapshot: { tasks: { totalTokens: number }[] } }>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Live snapshot did not arrive')), 5000);
        const handler = (message: WebSocket.RawData) => {
          const value = JSON.parse(message.toString());
          if (value.type !== 'snapshot' || value.snapshot.tasks[0].totalTokens !== counter) return;
          clearTimeout(timer); viewer.off('message', handler); resolve(value);
        };
        viewer.on('message', handler);
      });
      const value = snapshot(keys.id); value.tasks[0].totalTokens = counter;
      // Distinct observations, even when both frames land in the same clock tick.
      value.observedAt = observedAt + counter / 100;
      const ack = next(publisher); publisher.send(JSON.stringify(value));
      assert.equal((await received).snapshot.tasks[0].totalTokens, counter);
      assert.equal((await ack).type, 'accepted');
    }
  } finally { viewer.close(); publisher.close(); }
});

test('rotation closes existing viewers and rejects old links', async () => {
  const keys = await create(), viewer = await open(keys.id, keys.reader);
  const closed = new Promise<number>(resolve => viewer.once('close', code => resolve(code)));
  const response = await fetch(`${base}/v1/macs/${keys.id}/rotate`, {
    method: 'POST', headers: { Authorization: `Bearer ${keys.publisher}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader: credential(), usageReader: credential() }),
  });
  assert.equal(response.status, 200);
  assert.equal(await closed, 1008);
  const denied = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
  assert.equal(denied.status, 401);
});

test('a publisher cannot impersonate another Mac or add a command to a snapshot', async () => {
  for (const invalid of ['id', 'command']) {
    const keys = await create(), publisher = await open(keys.id, keys.publisher);
    const closed = new Promise<number>(resolve => publisher.once('close', code => resolve(code)));
    const value = snapshot(keys.id);
    publisher.send(JSON.stringify(invalid === 'id' ? { ...value, id: randomUUID() } : { ...value, command: 'run' }));
    assert.equal(await closed, 1008);
  }
});

test('one Mac cannot read or replace another Mac with its credentials', async () => {
  const first = await create(), second = await create();
  const response = await fetch(`${base}/v1/macs/${second.id}/snapshot`, { headers: { Authorization: `Bearer ${first.reader}` } });
  assert.equal(response.status, 401);
  const replace = await fetch(`${base}/v1/macs/${second.id}/initialize`, {
    method: 'POST', headers: { Authorization: `Bearer ${first.publisher}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader: credential(), usageReader: credential() }),
  });
  assert.equal(replace.status, 409);
});

test('only the publisher can delete a feed and deletion removes reader access', async () => {
  const keys = await create();
  const url = `${base}/v1/macs/${keys.id}/feed`;
  assert.equal((await fetch(url, { method: 'DELETE', headers: { Authorization: `Bearer ${keys.reader}` } })).status, 403);
  assert.equal((await fetch(url, { method: 'DELETE', headers: { Authorization: `Bearer ${keys.publisher}` } })).status, 200);
  assert.equal((await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } })).status, 401);
});

test('test pushes require a viewer and an existing subscription for that Mac', async () => {
  const keys = await create();
  const body = JSON.stringify({ token: credential(), environment: 'sandbox' });
  const request = (bearer: string) => fetch(`${base}/v1/macs/${keys.id}/test-notification`, {
    method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body,
  });
  assert.equal((await request(keys.publisher)).status, 403);
  assert.equal((await request(credential())).status, 401);
  const unregistered = await request(keys.reader);
  assert.equal(unregistered.status, 200);
  assert.deepEqual(await unregistered.json(), { result: 'not-registered' });
});

test('new viewers and widget reads receive the latest streamed telemetry between checkpoints', async () => {
  const keys = await create(), publisher = await open(keys.id, keys.publisher);
  const value = snapshot(keys.id);
  try {
    let ack = next(publisher); publisher.send(JSON.stringify(value)); await ack;
    value.observedAt += 0.01;
    value.tasks[0].totalTokens = 987;
    ack = next(publisher); publisher.send(JSON.stringify(value)); await ack;
    const response = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
    const result = await response.json() as { snapshot: { tasks: { totalTokens: number }[] } };
    assert.equal(result.snapshot.tasks[0].totalTokens, 987);
    const viewer = new WebSocket(`${base.replace('http', 'ws')}/v1/macs/${keys.id}/stream`, { headers: { Authorization: `Bearer ${keys.reader}` } });
    try {
      const initial = await next(viewer) as { type: string; snapshot: { tasks: { totalTokens: number }[] } };
      assert.equal(initial.snapshot.tasks[0].totalTokens, 987);
    } finally { viewer.close(); }
  } finally { publisher.close(); }
});

test('duplicate publisher frames are acknowledged without rolling back state', async () => {
  const keys = await create(), publisher = await open(keys.id, keys.publisher);
  const value = snapshot(keys.id);
  try {
    let ack = next(publisher); publisher.send(JSON.stringify(value)); await ack;
    ack = next(publisher); publisher.send(JSON.stringify(value));
    assert.equal((await ack).type, 'accepted');
    const older = { ...value, observedAt: value.observedAt - 1, tasks: [] };
    ack = next(publisher); publisher.send(JSON.stringify(older)); await ack;
    const response = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
    assert.equal((await response.json() as { snapshot: { tasks: unknown[] } }).snapshot.tasks.length, 1);
  } finally { publisher.close(); }
});

test('widget reads refresh an old checkpoint from a connected Mac without another database checkpoint', async () => {
  const keys = await create(), publisher = await open(keys.id, keys.publisher);
  const old = snapshot(keys.id); old.observedAt -= 10;
  try {
    const ack = next(publisher); publisher.send(JSON.stringify(old)); await ack;
    publisher.on('message', message => {
      if (JSON.parse(message.toString()).type === 'refresh') {
        const fresh = snapshot(keys.id); fresh.tasks[0].totalTokens = 999;
        publisher.send(JSON.stringify(fresh));
      }
    });
    const response = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
    assert.equal(response.status, 200);
    const value = await response.json() as any;
    assert.equal(value.snapshot.tasks[0].totalTokens, 999);
    const diagnostics = await fetch(`${base}/v1/macs/${keys.id}/diagnostics`, { headers: { Authorization: `Bearer ${keys.publisher}` } });
    assert.equal(((await diagnostics.json()) as any).runtime.checkpoints, 1);
  } finally { publisher.close(); }
});

test('viewer heartbeats are answered without granting publishing access', async () => {
  const keys = await create();
  const viewer = await open(keys.id, keys.reader);
  try {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('No viewer heartbeat response')), 3000);
      viewer.on('message', message => {
        if (message.toString() === 'pong') { clearTimeout(timer); resolve(); }
      });
      viewer.send('ping');
    });
    assert.equal(viewer.readyState, WebSocket.OPEN);
    const closed = new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Reader was not rejected as a publisher')), 3000);
      viewer.once('close', code => { clearTimeout(timer); resolve(code); });
    });
    viewer.send(JSON.stringify(snapshot(keys.id)));
    assert.equal(await closed, 1008);
  } finally { viewer.close(); }
});

test('concurrent phone registrations preserve the feed subscriber limit', async () => {
  const keys = await create();
  const responses = await Promise.all(Array.from({ length: 24 }, () => fetch(`${base}/v1/macs/${keys.id}/notifications`, {
    method: 'POST', headers: { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: credential(), environment: 'sandbox', kinds: ['completed'] }),
  })));
  assert.equal(responses.filter(r => r.status === 200).length, 16);
  assert.equal(responses.filter(r => r.status === 429).length, 8);
  for (const response of responses) await response.body?.cancel();
});

test('burst snapshots stay ordered while push receivers observe task changes', async () => {
  const keys = await create();
  const registration = await fetch(`${base}/v1/macs/${keys.id}/notifications`, {
    method: 'POST', headers: { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: credential(), environment: 'sandbox', kinds: [] }),
  });
  assert.equal(registration.status, 200);
  await registration.body?.cancel();
  const publisher = await open(keys.id, keys.publisher), viewer = await open(keys.id, keys.reader);
  try {
    const received: number[] = [];
    const complete = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Burst snapshots did not arrive')), 5000);
      viewer.on('message', data => {
        const message = JSON.parse(data.toString());
        if (message.type !== 'snapshot') return;
        received.push(message.snapshot.tasks[0].totalTokens);
        if (received.length === 20) { clearTimeout(timer); resolve(); }
      });
    });
    const value = snapshot(keys.id);
    for (let i = 0; i < 20; i++) {
      value.observedAt += 0.001;
      value.tasks[0].totalTokens = i;
      value.tasks[0].state = i % 2 ? 'needsInput' : 'needsApproval';
      publisher.send(JSON.stringify(value));
    }
    await complete;
    assert.deepEqual(received, Array.from({ length: 20 }, (_, i) => i));
  } finally { viewer.close(); publisher.close(); }
});

test('deletion closes live viewers and a recreated feed never restores old access', async () => {
  const keys = await create(), viewer = await open(keys.id, keys.reader);
  const closed = new Promise<number>((resolve, reject) => {
    // Local workerd can take a close-handshake grace period; cloud delivery is
    // faster. Bound the wait without treating that emulator grace as a failure.
    const timer = setTimeout(() => { viewer.terminate(); reject(new Error('Deleted feed stayed connected')); }, 15_000);
    viewer.once('close', code => { clearTimeout(timer); resolve(code); });
  });
  const deleted = await fetch(`${base}/v1/macs/${keys.id}/feed`, {
    method: 'DELETE', headers: { Authorization: `Bearer ${keys.publisher}` },
  });
  assert.equal(deleted.status, 200); await deleted.body?.cancel();
  assert.equal(await closed, 1008);
  const replacement = { publisher: credential(), reader: credential(), usageReader: credential() };
  const recreated = await fetch(`${base}/v1/macs/${keys.id}/initialize`, {
    method: 'POST', headers: { Authorization: `Bearer ${replacement.publisher}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader: replacement.reader, usageReader: replacement.usageReader }),
  });
  assert.equal(recreated.status, 200); await recreated.body?.cancel();
  created.push({ id: keys.id, publisher: replacement.publisher });
  const denied = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${keys.reader}` } });
  assert.equal(denied.status, 401); await denied.body?.cancel();
  const empty = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${replacement.reader}` } });
  assert.deepEqual(await empty.json(), { type: 'waiting' });
});

test('Live Activity registration requires full access, a snapshot, and an enabled device subscription', async () => {
  const keys = await create(), device = credential();
  // Exercise opaque Apple token sizes on this disposable subscription.
  const body = { token: credential(), environment: 'sandbox', kinds: [], liveActivities: { enabled: false, pushToStartToken: 'ab'.repeat(168) } };
  const send = (value: unknown, method = 'POST') => fetch(`${base}/v1/macs/${keys.id}/notifications`, {
    method, headers: { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' }, body: JSON.stringify(value),
  });
  assert.equal((await send(body)).status, 200);
  assert.equal((await send({ ...body, liveActivities: { enabled: false, pushToStartToken: 'a'.repeat(335) } })).status, 400);
  assert.equal((await send({ ...body, liveActivities: { enabled: false, pushToStartToken: 'ab'.repeat(2049) } })).status, 400);
  assert.equal((await send(body, 'DELETE')).status, 200);

  const registration = { token: device, environment: 'sandbox', activityID: 'test-activity', dismissed: true };
  const activity = (bearer: string, extra = {}) => fetch(`${base}/v1/macs/${keys.id}/live-activity`, {
    method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...registration, ...extra }),
  });
  const subscribe = (enabled: boolean) => fetch(`${base}/v1/macs/${keys.id}/notifications`, {
    method: 'POST', headers: { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: device, environment: 'sandbox', kinds: [], liveActivities: { enabled } }),
  });
  assert.equal((await activity(keys.publisher)).status, 403);
  assert.equal((await activity(keys.usageReader)).status, 403);
  assert.equal((await activity(keys.reader)).status, 403);
  assert.equal((await subscribe(true)).status, 200);
  const refreshed = await Promise.all(Array.from({ length: 8 }, () => subscribe(true)));
  assert.deepEqual(refreshed.map(response => response.status), Array(8).fill(200),
    'Concurrent refreshes for the same phone are not revoked viewing links');
  for (const response of refreshed) await response.body?.cancel();
  assert.equal((await activity(keys.reader)).status, 403, 'No snapshot has been published');
  const publisher = await open(keys.id, keys.publisher);
  try {
    const ack = next(publisher); publisher.send(JSON.stringify(snapshot(keys.id))); await ack;
    // A dismissal exercises registration without sending an APNs request.
    assert.equal((await activity(keys.reader)).status, 200);
    assert.equal((await activity(keys.reader, { dismissed: false, ended: true })).status, 200);
    assert.equal((await activity(keys.reader, { ended: true })).status, 400, 'An activity cannot be both ended and user-dismissed');
    assert.equal((await activity(keys.reader, { dismissed: false })).status, 400, 'Updates require an activity token');
    assert.equal((await activity(keys.reader, { dismissed: false, activityToken: 'invalid' })).status, 400);
    assert.equal((await subscribe(false)).status, 200);
    assert.equal((await activity(keys.reader)).status, 403, 'Disabled Live Activities reject registration');
  } finally { publisher.close(); }
});

test('rotated viewing links cannot register Live Activities or restore their subscription', async () => {
  const keys = await create(), device = credential();
  const headers = { Authorization: `Bearer ${keys.reader}`, 'Content-Type': 'application/json' };
  const url = `${base}/v1/macs/${keys.id}`;
  assert.equal((await fetch(`${url}/notifications`, { method: 'POST', headers,
    body: JSON.stringify({ token: device, environment: 'sandbox', kinds: [], liveActivities: { enabled: true } }),
  })).status, 200);
  assert.equal((await fetch(`${url}/rotate`, { method: 'POST',
    headers: { Authorization: `Bearer ${keys.publisher}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader: credential(), usageReader: credential() }),
  })).status, 200);
  assert.equal((await fetch(`${url}/live-activity`, { method: 'POST', headers,
    body: JSON.stringify({ token: device, environment: 'sandbox', activityID: 'old', dismissed: true }),
  })).status, 401);
});

test('paired devices have independent read-only access and publisher-only removal', async () => {
  const keys = await create();
  const pair = async (name: string, share = keys.reader) => {
    const device = { id: randomUUID(), name, token: credential() };
    const response = await fetch(`${base}/v1/macs/${keys.id}/pair`, {
      method: 'POST', headers: { Authorization: `Bearer ${share}`, 'Content-Type': 'application/json' }, body: JSON.stringify(device),
    });
    assert.equal(response.status, 200); return device;
  };
  const first = await pair('Test iPhone A'), second = await pair('Test iPhone B'), limited = await pair('Usage-only iPhone', keys.usageReader);
  const ownerHeaders = { Authorization: `Bearer ${keys.publisher}`, 'Content-Type': 'application/json' };
  const listing = await fetch(`${base}/v1/macs/${keys.id}/devices`, { headers: ownerHeaders });
  const text = await listing.text();
  assert.equal(listing.status, 200); assert.equal(JSON.parse(text).devices.length, 3);
  assert.ok(!text.includes('digest') && !text.includes(first.token), 'No device credentials in the owner list');
  for (const device of [first, limited]) {
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/devices`, { headers: { Authorization: `Bearer ${device.token}` } })).status, 403);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/devices`, { method: 'DELETE', headers: { Authorization: `Bearer ${device.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: second.id }) })).status, 403);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/pair`, { method: 'POST', headers: { Authorization: `Bearer ${device.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: randomUUID(), name: 'Unauthorized', token: credential() }) })).status, 403);
  }
  const publisher = await open(keys.id, keys.publisher);
  const viewer = await open(keys.id, first.token), other = await open(keys.id, second.token);
  try {
    const ack = next(publisher); publisher.send(JSON.stringify(snapshot(keys.id))); assert.equal((await ack).type, 'accepted');
    const usage = await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${limited.token}` } });
    assert.equal((await usage.json() as { snapshot: { tasks: unknown[] } }).snapshot.tasks.length, 0);
    const closed = new Promise<number>(resolve => viewer.once('close', code => resolve(code)));
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/devices`, { method: 'DELETE', headers: ownerHeaders, body: JSON.stringify({ id: first.id }) })).status, 200);
    assert.equal(await closed, 1008);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${first.token}` } })).status, 401);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${second.token}` } })).status, 200);
    assert.equal(other.readyState, WebSocket.OPEN);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/pair`, { method: 'DELETE', headers: { Authorization: `Bearer ${second.token}` } })).status, 200);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${second.token}` } })).status, 401);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/rotate`, { method: 'POST', headers: ownerHeaders, body: JSON.stringify({ reader: credential(), usageReader: credential() }) })).status, 200);
    assert.equal((await fetch(`${base}/v1/macs/${keys.id}/snapshot`, { headers: { Authorization: `Bearer ${limited.token}` } })).status, 401);
  } finally { publisher.close(); viewer.close(); other.close(); }
});

test('pairing validates credentials, bounded names, unique identities and capacity', async () => {
  const keys = await create(), id = randomUUID(), secret = credential();
  const send = (device: unknown, bearer = keys.reader) => fetch(`${base}/v1/macs/${keys.id}/pair`, { method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify(device) });
  for (const token of [keys.publisher, keys.reader, keys.usageReader]) assert.equal((await send({ id, name: 'Phone', token })).status, 400);
  assert.equal((await send({ id, name: 'x'.repeat(81), token: secret })).status, 400);
  assert.equal((await send({ id, name: 'Phone', token: secret, command: 'run' })).status, 400);
  assert.equal((await send({ id, name: 'Phone', token: secret })).status, 200);
  assert.equal((await send({ id, name: 'Phone', token: secret })).status, 200, 'Idempotent retry');
  assert.equal((await send({ id, name: 'Other', token: credential() })).status, 409);
  assert.equal((await send({ id: randomUUID(), name: 'Duplicate token', token: secret })).status, 409);
  for (let i = 1; i < 16; i++) assert.equal((await send({ id: randomUUID(), name: `Phone ${i}`, token: credential() })).status, 200);
  assert.equal((await send({ id: randomUUID(), name: 'Over limit', token: credential() })).status, 429);
  assert.equal((await send({ id: randomUUID(), name: 'Publisher misuse', token: credential() }, keys.publisher)).status, 403);
});

test('removal revokes push access and late legacy registration cannot replace device ownership', async () => {
  const keys = await create(), device = { id: randomUUID(), name: 'Test phone', token: credential() };
  const send = (action: string, method: string, bearer: string, body: unknown) => fetch(`${base}/v1/macs/${keys.id}/${action}`, { method, headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await send('pair', 'POST', keys.reader, device)).status, 200);
  const registration = { token: credential(), environment: 'sandbox', kinds: [] };
  assert.equal((await send('notifications', 'POST', keys.reader, registration)).status, 200);
  assert.equal((await send('notifications', 'POST', device.token, registration)).status, 200);
  assert.equal((await send('notifications', 'POST', keys.reader, registration)).status, 403);
  assert.equal((await send('notifications', 'DELETE', keys.reader, registration)).status, 403);
  assert.equal((await send('devices', 'DELETE', keys.publisher, { id: device.id })).status, 200);
  assert.equal((await send('notifications', 'POST', device.token, registration)).status, 401);
  const response = await send('test-notification', 'POST', keys.reader, { token: registration.token, environment: 'sandbox' });
  const value = await response.json() as { result: string };
  assert.equal(value.result, 'not-registered');
});
