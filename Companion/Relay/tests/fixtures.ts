// Synthetic local-only simulator publishers. Never uses live Mac data or credentials.
import WebSocket from 'ws';
const base = 'http://127.0.0.1:8789';
const ids = ['33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444'];
const sockets = new Set<WebSocket>();
let stopping = false;
for (const [index, id] of ids.entries()) {
  const response = await fetch(`${base}/v1/macs/${id}/initialize`, {
    method: 'POST', headers: { Authorization: `Bearer ${'a'.repeat(64)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reader: 'b'.repeat(64), usageReader: 'c'.repeat(64) }),
  });
  if (![200, 409].includes(response.status)) throw new Error('Fixture initialization failed');
  connect(index, id);
}
function connect(index: number, id: string) {
  if (stopping) return;
  const socket = new WebSocket(`${base.replace('http', 'ws')}/v1/macs/${id}/stream`, { headers: { Authorization: `Bearer ${'a'.repeat(64)}` } });
  sockets.add(socket);
  let count = 0;
  const send = () => {
    if (socket.readyState !== WebSocket.OPEN) return;
    const now = Date.now() / 1000;
    socket.send(JSON.stringify({ schemaVersion: 1, id, name: index === 0 ? 'Fixture MacBook' : 'Fixture Mac mini', observedAt: now,
      account: { id: 'fixture-shared-account', plan: 'Pro', observedAt: now, windows: [
        { id: 'session', name: 'Session', remainingPercent: 83, resetsAt: now + 8000 },
        { id: 'weekly', name: 'Weekly', remainingPercent: 64, resetsAt: now + 280000 }], bankedResets: 2, dailyTokens: [] },
      tasks: [{ id: `task-${index}`, title: index === 0 ? 'Live relay task' : 'Review approval on Mac mini',
        project: 'CodexGauge', state: index === 0 ? 'running' : 'needsApproval',
        activity: `Live update ${++count}`, tokensPerMinute: 2400 + count, totalTokens: 1000 + count,
        startedAt: now - 180, agentCount: 0 },
        { id: `done-${index}`, title: 'Completed follow-up ready task', state: 'completed', activity: 'Completed', tokensPerMinute: 0, totalTokens: 20, agentCount: 0 }],
    }));
  };
  socket.on('open', send);
  const timer = setInterval(send, 2000);
  socket.on('error', () => socket.close());
  socket.on('close', () => {
    clearInterval(timer); sockets.delete(socket);
    if (!stopping) setTimeout(() => connect(index, id), 1000);
  });
}
process.on('SIGINT', () => { stopping = true; for (const socket of sockets) socket.close(); });
console.log('Two synthetic Mac publishers connected to the local relay.');
