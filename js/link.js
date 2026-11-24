// Realtime link between the showroom (host) and phone keys (remotes).
//
// Transports, in order of preference:
//   1. WebSocket relay on your own server (server/server.js). Most reliable:
//      works on mobile data, through NAT, everywhere.
//   2. WebRTC via PeerJS's free public broker. Used automatically when the
//      relay isn't there (e.g. on a static host like Vercel).
//   3. BroadcastChannel, so two tabs in one browser work even offline.
// Messages may arrive over more than one transport; they carry ids and are deduped.

export const PREFIX = 'apex9r-';
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CFG = window.APEX_CONFIG || {};

export function makeCode(n = 5) {
  let s = '';
  const r = crypto.getRandomValues(new Uint32Array(n));
  for (let i = 0; i < n; i++) s += ALPHABET[r[i] % ALPHABET.length];
  return s;
}

/** Where the relay lives: configured (native apps) or same origin (VPS). */
export function relayUrl() {
  if (CFG.relay) return CFG.relay;
  if (location.protocol === 'http:' || location.protocol === 'https:') {
    return (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/relay';
  }
  return null;
}

/** Public web address used for QR codes (apps run from capacitor://, which a phone can't open). */
export function publicBase() {
  if (CFG.publicUrl) return CFG.publicUrl.replace(/\/?$/, '/');
  return location.href.split('#')[0].split('?')[0].replace(/[^/]*$/, '');
}

function emitter() {
  const h = {};
  return {
    on(e, f) { (h[e] ||= []).push(f); },
    emit(e, ...a) { (h[e] || []).forEach(f => f(...a)); },
  };
}

/** WebSocket relay transport with reconnect. onDead fires if it never manages to open. */
function relayTransport(code, role, { onMessage, onOpen, onClose, onDead }) {
  const base = relayUrl();
  if (!base || typeof WebSocket === 'undefined') { setTimeout(onDead, 0); return null; }
  let ws = null, everOpen = false, retry = 0, closed = false, failures = 0;
  function connect() {
    if (closed) return;
    try { ws = new WebSocket(`${base}?room=${encodeURIComponent(code)}&role=${role}`); }
    catch { failures++; return schedule(); }
    const openTimer = setTimeout(() => { if (ws.readyState !== 1) ws.close(); }, 5000);
    ws.onopen = () => { clearTimeout(openTimer); everOpen = true; retry = 0; onOpen && onOpen(); };
    ws.onmessage = (e) => { try { onMessage(JSON.parse(e.data)); } catch {} };
    ws.onclose = () => {
      clearTimeout(openTimer);
      if (!everOpen && ++failures >= 2) { closed = true; onDead && onDead(); return; }
      onClose && onClose(); schedule();
    };
    ws.onerror = () => {};
  }
  function schedule() { setTimeout(connect, Math.min(8000, 600 * 2 ** retry++)); }
  connect();
  document.addEventListener('visibilitychange', () => { if (!document.hidden && ws && ws.readyState > 1 && !closed) { retry = 0; connect(); } });
  return {
    get open() { return !!ws && ws.readyState === 1; },
    send(msg) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg)); },
    close() { closed = true; try { ws && ws.close(); } catch {} },
  };
}

/* ---------------- Host (showroom) ---------------- */
export function createHost(code) {
  const ev = emitter();
  const conns = new Set();
  let peer = null, destroyed = false, retry = 0;
  const bc = new BroadcastChannel(PREFIX + code);

  // Presence: each phone tags messages with its id `rid` and sends a heartbeat,
  // so one phone reachable over two channels still counts once.
  const seenRemote = new Map();
  let lastCount = 0;
  const count = () => {
    const now = performance.now();
    for (const [rid, t] of seenRemote) if (now - t > 3500) seenRemote.delete(rid);
    return seenRemote.size;
  };
  const presence = setInterval(() => { const n = count(); if (n !== lastCount) { lastCount = n; ev.emit('count', n); } }, 500);

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

  const relay = relayTransport(code, 'host', {
    onMessage: deliver,
    onOpen: () => ev.emit('status', 'ready'),
    onClose: () => ev.emit('status', 'error'),
    onDead: () => startPeer(),
  });

  function startPeer() {
    if (destroyed) return;
    if (typeof Peer === 'undefined') { ev.emit('status', 'local'); return; }
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
        setTimeout(startPeer, Math.min(8000, 1000 * 2 ** retry++));
      }
    });
  }

  return {
    on: ev.on,
    count,
    get transport() { return relay && relay.open ? 'relay' : peer ? 'p2p' : 'local'; },
    send(msg) {
      relay && relay.send(msg);
      for (const c of conns) if (c.open) { try { c.send(msg); } catch {} }
      bc.postMessage(msg);
    },
    destroy() { destroyed = true; clearInterval(presence); relay && relay.close(); try { peer && peer.destroy(); } catch {} bc.close(); },
  };
}

/* ---------------- Remote (phone key) ---------------- */
export function createRemote(code) {
  const ev = emitter();
  let peer = null, conn = null, destroyed = false, lastHost = 0, retry = 0, seq = 0;
  const me = makeCode(6);
  const bc = new BroadcastChannel(PREFIX + code);
  const fromHost = (m) => { lastHost = performance.now(); ev.emit('message', m); };
  bc.onmessage = (e) => fromHost(e.data);

  const relay = relayTransport(code, 'remote', {
    onMessage: fromHost,
    onOpen: () => { ev.emit('status', 'searching'); api.send({ t: 'hb' }); },
    onClose: () => ev.emit('status', 'lost'),
    onDead: () => connectPeer(),
  });

  function connectPeer() {
    if (destroyed || typeof Peer === 'undefined') return;
    if (!peer || peer.destroyed) {
      peer = new Peer({ debug: 0 });
      peer.on('open', dial);
      peer.on('error', (err) => {
        ev.emit('status', err.type === 'peer-unavailable' ? 'nohost' : 'error');
        schedule();
      });
      peer.on('disconnected', () => { try { peer.reconnect(); } catch {} });
    } else dial();
  }
  function dial() {
    ev.emit('status', 'connecting');
    conn = peer.connect(PREFIX + code, { reliable: true, serialization: 'json' });
    conn.on('open', () => { retry = 0; ev.emit('status', 'searching'); api.send({ t: 'hb' }); });
    conn.on('data', fromHost);
    conn.on('close', () => { ev.emit('status', 'lost'); schedule(); });
    conn.on('error', () => schedule());
  }
  let timer = 0;
  function schedule() {
    if (destroyed) return;
    clearTimeout(timer);
    timer = setTimeout(connectPeer, Math.min(6000, 800 * 2 ** retry++));
  }
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && peer && (!conn || !conn.open)) { retry = 0; connectPeer(); }
  });

  const api = {
    on: ev.on,
    /** true while the car is actually talking to us (it streams state ~16×/s) */
    get open() { return performance.now() - lastHost < 2500; },
    send(msg) {
      msg = { ...msg, rid: me, id: me + ':' + (++seq) };
      relay && relay.send(msg);
      if (conn && conn.open) { try { conn.send(msg); } catch {} }
      bc.postMessage(msg);
    },
  };
  api.send({ t: 'hb' });
  setInterval(() => api.send({ t: 'hb' }), 1000);
  return api;
}
