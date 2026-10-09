import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomBytes, randomUUID } from 'node:crypto';
import WebSocket from 'ws';

const base = process.env.RELAY_URL ?? 'http://127.0.0.1:8789';
const credential = () => randomBytes(32).toString('hex');
function connect(id: string, bearer: string, adaptive = false) {
  const socket = new WebSocket(`${base.replace('http', 'ws')}/v1/macs/${id}/stream${adaptive ? '?publishing=adaptive' : ''}`, { headers: { Authorization: `Bearer ${bearer}` } });
  const queue: any[] = [];
  socket.on('message', data => queue.push(data.toString() === 'pong' ? { type: 'pong' } : JSON.parse(data.toString())));
  const opened = new Promise<void>((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  async function next(type: string, matches = (_: any) => true) {
    for (let i = 0; i < 300; i++) {
      const index = queue.findIndex(message => message.type === type && matches(message));
      if (index >= 0) return queue.splice(index, 1)[0];
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error(`Missing ${type} control message`);
  }
  return { socket, opened, next, queue };
}

test('adaptive demand follows viewers and subscriptions; cached reads preserve revocation and widget freshness', async () => {
  const id = randomUUID(), publisher = credential(), reader = credential(), usageReader = credential();
  const request = (action: string, body?: unknown, bearer = publisher, method = 'POST') => fetch(`${base}/v1/macs/${id}/${action}`, {
    method, headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.equal((await request('initialize', { reader, usageReader })).status, 200);
  const pub = connect(id, publisher, true);
  let viewer: ReturnType<typeof connect> | undefined, replacement: ReturnType<typeof connect> | undefined;
  try {
    await pub.opened;
    assert.deepEqual(await pub.next('demand'), { type: 'demand', viewers: 0, push: false, paired: false, refreshPush: true });
    const feed = { schemaVersion: 1, id, name: 'Adaptive fixture', observedAt: Date.now() / 1000 - 10,
      tasks: [{ id: 'task', title: 'Task', state: 'running', activity: 'Thinking', tokensPerMinute: 1, totalTokens: 1, agentCount: 0 }] };
    pub.socket.send(JSON.stringify(feed)); await pub.next('accepted');
    const widget = request('snapshot', undefined, reader, 'GET');
    await pub.next('refresh'); feed.observedAt = Date.now() / 1000;
    pub.socket.send(JSON.stringify(feed)); await pub.next('accepted');
    assert.equal((await (await widget).json() as any).snapshot.observedAt, feed.observedAt);
    viewer = connect(id, reader); await viewer.opened;
    assert.equal((await pub.next('demand')).viewers, 1); await pub.next('refresh'); await viewer.next('snapshot');
    viewer.socket.close(); assert.equal((await pub.next('demand')).viewers, 0);
    const device = { token: credential(), environment: 'sandbox', kinds: ['completed'], liveActivities: { enabled: false } };
    assert.equal((await request('notifications', device, reader)).status, 200);
    assert.equal((await pub.next('demand')).push, true); await pub.next('refresh');
    assert.equal((await request('notifications', { ...device, kinds: [] }, reader)).status, 200);
    assert.equal((await pub.next('demand')).push, false); await pub.next('refresh');
    const phone = { id: randomUUID(), name: 'Phone', token: credential() };
    assert.equal((await request('pair', phone, reader)).status, 200);
    assert.equal((await pub.next('demand')).paired, true);
    const diagnostic = async () => (await (await request('diagnostics', undefined, publisher, 'GET')).json() as any).runtime;
    const before = await diagnostic();
    for (let i = 0; i < 100; i++) {
      feed.observedAt += .001; feed.tasks[0].tokensPerMinute++;
      pub.socket.send(JSON.stringify(feed)); await pub.next('accepted');
    }
    const after = await diagnostic();
    assert.equal(after.checkpoints, before.checkpoints);
    assert.equal(after.reads, before.reads, 'Warm authorization and snapshot processing must not reread SQL per frame');
    pub.socket.send('ping'); await pub.next('pong');
    assert.equal((await diagnostic()).frames, after.frames, 'Heartbeat does not invoke the snapshot handler');
    replacement = connect(id, publisher, true); await replacement.opened;
    assert.equal((await replacement.next('demand')).paired, true, 'Reconnect reconstructs demand');
    assert.equal((await request('devices', { id: phone.id }, publisher, 'DELETE')).status, 200);
    assert.equal((await replacement.next('demand', value => !value.paired)).paired, false);
    assert.equal((await request('snapshot', undefined, phone.token, 'GET')).status, 401, 'Cached device authority is revoked');
    assert.equal((await request('feed', undefined, publisher, 'DELETE')).status, 200);
    assert.equal((await request('snapshot', undefined, reader, 'GET')).status, 401, 'Cached shared authority is revoked');
  } finally {
    pub.socket.close(); viewer?.socket.close(); replacement?.socket.close();
    await request('feed', undefined, publisher, 'DELETE');
  }
});
