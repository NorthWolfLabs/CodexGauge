// Disposable development feed only. No real subscription or push registration.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import WebSocket from 'ws';
const base = process.env.RELAY_URL ?? 'http://127.0.0.1:8798';
assert.ok(base === 'http://127.0.0.1:8798' || base === 'https://codexgauge-relay-dev.north-wolf-labs.workers.dev');
const id = randomUUID();
const credential = () => randomBytes(32).toString('hex');
const publisher = credential(), reader = credential(), usageReader = credential();
const sockets: WebSocket[] = [];
const headers = { Authorization: `Bearer ${publisher}`, 'Content-Type': 'application/json' };
function next(socket: WebSocket): Promise<any> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Snapshot timed out')), 10000);
    socket.once('message', message => { clearTimeout(timer); resolve(JSON.parse(message.toString())); });
  });
}
async function open(token: string): Promise<WebSocket> {
  const socket = new WebSocket(`${base.replace(/^http/, 'ws')}/v1/macs/${id}/stream`, { headers: { Authorization: `Bearer ${token}` } });
  sockets.push(socket);
  await new Promise<void>((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  return socket;
}
let initialized = false;
try {
  const setup = await fetch(`${base}/v1/macs/${id}/initialize`, { method: 'POST', headers, body: JSON.stringify({ reader, usageReader }) });
  assert.equal(setup.status, 200); initialized = true;
  const source = await open(publisher), viewer = await open(reader);
  assert.equal((await next(viewer)).type, 'waiting');
  const now = Date.now() / 1000;
  const snapshot = { schemaVersion: 1, id, name: 'Refinement compatibility fixture', observedAt: now,
    account: { id: 'synthetic-account', plan: 'Pro', email: 'fixture@example.com', accountType: 'chatgpt', historyObservedAt: now - 30, historyTruncated: true, observedAt: now,
      windows: [{ id: 'weekly', name: 'Weekly', remainingPercent: 62 }], bankedResets: 3,
      dailyTokens: Array.from({ length: 500 }, (_, index) => ({ id: new Date(Date.UTC(2025, 0, 1 + index)).toISOString().slice(0, 10), tokens: index })), credits: [{ id: 'codex', name: 'Codex', hasCredits: true, unlimited: false, balance: '137' }],
      metrics: { peakDailyTokens: 2000, longestTurnSeconds: 300, currentStreakDays: 2, longestStreakDays: 3 } },
    tasks: [{ id: 'synthetic-task', title: 'Synthetic compatibility task', state: 'running', activity: 'Using tool',
      tokensPerMinute: 0, totalTokens: 0, agentCount: 1, startedAt: now - 120, observedAt: now,
      hasTokenObservation: false, contextPercent: 32,
      metrics: { model: 'fixture-model', contextIncludesAgent: true, tokenTotalsComplete: false } }] };
  const accepted = next(source), delivery = next(viewer), start = performance.now();
  source.send(JSON.stringify(snapshot));
  assert.equal((await accepted).type, 'accepted');
  const received = await delivery;
  const deliveryMilliseconds = performance.now() - start;
  assert.deepEqual(received.snapshot.tasks, snapshot.tasks);
  assert.deepEqual(received.snapshot.account, snapshot.account);
  const response = await fetch(`${base}/v1/macs/${id}/snapshot`, { headers: { Authorization: `Bearer ${usageReader}` } });
  assert.equal(response.status, 200);
  const usage = (await response.json() as any).snapshot;
  assert.deepEqual(usage.tasks, []);
  assert.deepEqual(usage.account, snapshot.account);
  console.log(`Optional metadata round trip and usage-only redaction passed; live delivery ${Math.round(deliveryMilliseconds)} ms.`);
} finally {
  sockets.forEach(socket => socket.close());
  if (initialized) {
    const cleanup = await fetch(`${base}/v1/macs/${id}/feed`, { method: 'DELETE', headers });
    assert.equal(cleanup.status, 200); console.log('Disposable feed removed.');
  }
}
