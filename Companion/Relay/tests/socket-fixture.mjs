// Loopback-only Foundation WebSocket regression fixture. No credentials or APNs.
import { WebSocketServer } from 'ws';
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
server.on('listening', () => process.stdout.write(`ws://127.0.0.1:${server.address().port}\n`));
server.on('connection', (socket, request) => {
  socket.on('error', () => {});
  if (request.url === '/silent') return;
  socket.on('message', message => socket.send(message.toString() === 'ping' ? 'pong' : message.toString()));
});
const close = () => { for (const socket of server.clients) socket.terminate(); server.close(() => process.exit(0)); };
process.on('SIGTERM', close);
process.on('SIGINT', close);
