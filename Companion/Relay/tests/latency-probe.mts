// Headless, disposable measurement. No existing feed, task, or phone is used.
// Run with RELAY_URL=... vp exec node tests/latency-probe.mts.
import { randomBytes, randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import WebSocket from 'ws';

const base = process.env.RELAY_URL ?? 'http://127.0.0.1:8789';
const id = randomUUID();
const credential = () => randomBytes(32).toString('hex');
const publisherKey = credential(), readerKey = credential();
const headers = { Authorization: `Bearer ${publisherKey}`, 'Content-Type': 'application/json' };
const sockets: WebSocket[] = [];
let created = false;
async function connect(key: string) {
  const socket = new WebSocket(`${base.replace(/^http/, 'ws')}/v1/macs/${id}/stream`, {
    headers: { Authorization: `Bearer ${key}` }, handshakeTimeout: 10_000,
  });
  sockets.push(socket);
  await new Promise<void>((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  return socket;
}
try {
  const response = await fetch(`${base}/v1/macs/${id}/initialize`, {
    method: 'POST', headers, body: JSON.stringify({ reader: readerKey, usageReader: credential() }),
    signal: AbortSignal.timeout(10_000),
  });
  if (response.status !== 200) throw new Error(`Feed creation failed: ${response.status}`);
  created = true;
  await response.body?.cancel();
  const publisher = await connect(publisherKey), viewer = await connect(readerKey);
  const samples: number[] = [];
  const start = Date.now() / 1000;
  for (let i = 0; i < 30; i++) {
    const observedAt = start + i / 1000;
    let timer: ReturnType<typeof setTimeout>;
    const sent = performance.now();
    await new Promise<void>((resolve, reject) => {
      const handler = (data: WebSocket.RawData) => {
        const value = JSON.parse(data.toString());
        if (value.type !== 'snapshot' || value.snapshot.observedAt !== observedAt) return;
        clearTimeout(timer); viewer.off('message', handler);
        samples.push(performance.now() - sent); resolve();
      };
      timer = setTimeout(() => { viewer.off('message', handler); reject(new Error('Snapshot delivery timed out')); }, 10_000);
      viewer.on('message', handler);
      publisher.send(JSON.stringify({ schemaVersion: 1, id, name: 'Disposable latency probe', observedAt, tasks: [] }));
    });
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  samples.sort((a, b) => a - b);
  const percentile = (p: number) => Math.round(samples[Math.ceil(samples.length * p) - 1] * 10) / 10;
  console.log(JSON.stringify({ samples: samples.length, medianMS: percentile(0.5), p95MS: percentile(0.95), maxMS: percentile(1),
    note: 'Mac-hosted publisher and viewer through the relay; excludes Codex polling, iPhone rendering, and mobile radio latency.' }, null, 2));
} finally {
  for (const socket of sockets) socket.terminate();
  if (created) {
    const response = await fetch(`${base}/v1/macs/${id}/feed`, { method: 'DELETE', headers, signal: AbortSignal.timeout(10_000) });
    if (response.status !== 200) throw new Error(`Disposable feed cleanup failed: ${response.status}`);
    await response.body?.cancel();
  }
}
