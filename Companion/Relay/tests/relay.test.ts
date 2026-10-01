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
