// APEX 9R server: serves the static site and relays messages between the
// showroom (host) and phone keys (remotes) over WebSockets.
//   ws(s)://<host>/relay?room=CODE&role=host|remote
// The relay is dumb on purpose: it never parses payloads, it only forwards
// host → remotes and remote → hosts inside the same room.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = +(process.env.PORT || 8080);
const PUBLIC = new Set(['index.html', 'remote.html', 'manifest.webmanifest', 'remote.webmanifest', 'favicon.svg']);
const PUBLIC_DIRS = ['css/', 'js/', 'icons/'];
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml',
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/healthz') { res.writeHead(200, { 'content-type': 'text/plain' }); return res.end('ok'); }
  let rel = decodeURIComponent(url.pathname).replace(/^\/+/, '');
  if (rel === '' || rel.endsWith('/')) rel += 'index.html';
  if (rel === 'key' || rel === 'remote') rel = 'remote.html';
  const allowed = PUBLIC.has(rel) || PUBLIC_DIRS.some(d => rel.startsWith(d));
  const file = path.join(ROOT, rel);
  if (!allowed || !file.startsWith(ROOT + path.sep) || rel.includes('..')) { res.writeHead(404); return res.end('Not found'); }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404); return res.end('Not found'); }
    const ext = path.extname(file);
    res.writeHead(200, {
      'content-type': TYPES[ext] || 'application/octet-stream',
      'content-length': st.size,
      'cache-control': ext === '.html' || ext === '.webmanifest' ? 'no-cache' : 'public, max-age=300',
      'x-content-type-options': 'nosniff',
    });
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(file).pipe(res);
  });
});

/* ---------------- relay ---------------- */
const rooms = new Map(); // code -> { host: Set<ws>, remote: Set<ws> }
const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://x');
  const room = (url.searchParams.get('room') || '').toUpperCase();
  const role = url.searchParams.get('role');
  if (url.pathname !== '/relay' || !/^[A-Z0-9]{4,12}$/.test(room) || !['host', 'remote'].includes(role)) {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n'); return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, (ws) => join(ws, room, role));
});

function join(ws, code, role) {
  let r = rooms.get(code);
  if (!r) rooms.set(code, (r = { host: new Set(), remote: new Set() }));
  r[role].add(ws);
  ws.isAlive = true;
  ws.on('pong', () => (ws.isAlive = true));
  // rate limit: 120 msgs/s per socket is plenty for a 20 Hz throttle stream
  let bucket = 120, last = Date.now();
  ws.on('message', (data, isBinary) => {
    const now = Date.now(); bucket = Math.min(120, bucket + ((now - last) / 1000) * 120); last = now;
    if (bucket < 1) return; bucket--;
    const targets = role === 'host' ? r.remote : r.host;
    for (const t of targets) if (t.readyState === 1) t.send(data, { binary: isBinary });
  });
  ws.on('close', () => {
    r[role].delete(ws);
    if (!r.host.size && !r.remote.size) rooms.delete(code);
  });
}

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false; ws.ping();
  }
}, 25000);

server.listen(PORT, () => console.log(`APEX 9R listening on :${PORT}`));
