// Tiny realtime link between the showroom (host) and phone keys (remotes).
// WebRTC via PeerJS (free public broker, no keys) + BroadcastChannel fallback
// so two tabs on the same machine work even offline.

export const PREFIX = 'apex9r-';
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export function makeCode(n = 5) {
  let s = '';
  const r = crypto.getRandomValues(new Uint32Array(n));
  for (let i = 0; i < n; i++) s += ALPHABET[r[i] % ALPHABET.length];
  return s;
}

function emitter() {
  const h = {};
  return {
    on(e, f) { (h[e] ||= []).push(f); },
    emit(e, ...a) { (h[e] || []).forEach(f => f(...a)); },
  };
}

/* ---------------- Host (desktop) ---------------- */
export function createHost(code) {
  const ev = emitter();
  const conns = new Set();
  let peer = null, destroyed = false, retry = 0;
  const bc = new BroadcastChannel(PREFIX + code);

  // Presence: each phone tags messages with its id `rid` and sends a heartbeat,
  // so one phone reachable over two channels still counts once.
  const seenRemote = new Map(); // rid -> last seen ms
  let lastCount = 0;
  const count = () => {
    const now = performance.now();
    for (const [rid, t] of seenRemote) if (now - t > 3500) seenRemote.delete(rid);
    return seenRemote.size;
  };
  const presence = setInterval(() => { const n = count(); if (n !== lastCount) { lastCount = n; ev.emit('count', n); } }, 500);

  // The same message may arrive over WebRTC and BroadcastChannel: dedupe by id.
  const seen = new Map();
  const deliver = (m) => {
    if (!m || typeof m !== 'object') return;
    if (m.rid) {
      const isNew = !seenRemote.has(m.rid);
      seenRemote.set(m.rid, performance.now());
      if (isNew) { lastCount = count(); ev.emit('count', lastCount); ev.emit('hello', m.rid); }
    }
    if (m.id) {
      if (seen.has(m.id)) return;
      seen.set(m.id, 1);
      if (seen.size > 400) seen.delete(seen.keys().next().value);
    }
    if (m.t === 'hb') return;
    ev.emit('message', m);
  };
  bc.onmessage = (e) => deliver(e.data);

  function start() {
    if (destroyed || typeof Peer === 'undefined') { ev.emit('status', 'local'); return; }
    peer = new Peer(PREFIX + code, { debug: 0 });
    peer.on('open', () => { retry = 0; ev.emit('status', 'ready'); });
    peer.on('connection', (c) => {
      c.on('open', () => conns.add(c));
      c.on('data', (d) => deliver(d));
      const drop = () => conns.delete(c);
      c.on('close', drop); c.on('error', drop);
    });
    peer.on('disconnected', () => { if (!destroyed) setTimeout(() => peer && !peer.destroyed && peer.reconnect(), 1000); });
    peer.on('error', (err) => {
      if (err.type === 'unavailable-id') { ev.emit('collision'); return; }
      ev.emit('status', 'error');
      if (['network', 'server-error', 'socket-error', 'socket-closed'].includes(err.type)) {
        try { peer.destroy(); } catch {}
        setTimeout(start, Math.min(8000, 1000 * 2 ** retry++));
      }
    });
  }
  start();

  return {
    on: ev.on,
    count,
    send(msg) {
      for (const c of conns) if (c.open) { try { c.send(msg); } catch {} }
      bc.postMessage(msg);
    },
    destroy() { destroyed = true; clearInterval(presence); try { peer && peer.destroy(); } catch {} bc.close(); },
  };
}

/* ---------------- Remote (phone) ---------------- */
export function createRemote(code) {
  const ev = emitter();
  let peer = null, conn = null, destroyed = false, lastHost = 0, retry = 0, seq = 0;
  const me = makeCode(6);
  const bc = new BroadcastChannel(PREFIX + code);
  bc.onmessage = (e) => { lastHost = performance.now(); ev.emit('message', e.data); };

  function connect() {
    if (destroyed || typeof Peer === 'undefined') return;
    if (!peer || peer.destroyed) {
      peer = new Peer({ debug: 0 });
      peer.on('open', dial);
      peer.on('error', (err) => {
        if (err.type === 'peer-unavailable') ev.emit('status', 'nohost');
        else ev.emit('status', 'error');
        schedule();
      });
      peer.on('disconnected', () => { try { peer.reconnect(); } catch {} });
    } else dial();
  }
  function dial() {
    ev.emit('status', 'connecting');
    conn = peer.connect(PREFIX + code, { reliable: true, serialization: 'json' });
    conn.on('open', () => { retry = 0; ev.emit('status', 'connected'); api.send({ t: 'hb' }); });
    conn.on('data', (d) => { lastHost = performance.now(); ev.emit('message', d); });
    conn.on('close', () => { ev.emit('status', 'lost'); schedule(); });
    conn.on('error', () => schedule());
  }
  let timer = 0;
  function schedule() {
    if (destroyed) return;
    clearTimeout(timer);
    timer = setTimeout(connect, Math.min(6000, 800 * 2 ** retry++));
  }
  connect();
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && (!conn || !conn.open)) { retry = 0; connect(); }
  });

  const api = {
    on: ev.on,
    get open() { return !!(conn && conn.open) || performance.now() - lastHost < 1500; },
    send(msg) {
      msg = { ...msg, rid: me, id: me + ':' + (++seq) };
      if (conn && conn.open) { try { conn.send(msg); } catch {} }
      bc.postMessage(msg);
    },
  };
  api.send({ t: 'hb' });
  setInterval(() => api.send({ t: 'hb' }), 1000);
  return api;
}
