import { createRemote } from './link.js';

const $ = (s) => document.querySelector(s);
const PAINTS = ['#1b55e0', '#ff5a1f', '#c8101e', '#d9d6cf', '#9fe01b', '#0d0e12', '#5a2bd6', '#a9b0bb'];
const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };

/* ---------- haptics: native Taptic Engine in the iOS app, vibrate() on Android ---------- */
const NativeHaptics = window.Capacitor?.isNativePlatform?.() ? window.Capacitor.registerPlugin('Haptics') : null;
function buzz(p) {
  if (NativeHaptics) {
    const ms = Array.isArray(p) ? Math.max(...p) : p;
    if (Array.isArray(p)) NativeHaptics.notification({ type: 'WARNING' }).catch(() => {});
    else NativeHaptics.impact({ style: ms >= 30 ? 'HEAVY' : ms >= 15 ? 'MEDIUM' : 'LIGHT' }).catch(() => {});
    return;
  }
  try { navigator.vibrate && navigator.vibrate(p); } catch {}
}

/* ---------- pairing ---------- */
const clean = (c) => (c || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
function codeFrom(text) {
  // accepts a bare code or any URL ending in #CODE
  const m = String(text).match(/#([A-Za-z0-9]{4,12})\s*$/);
  return clean(m ? m[1] : text);
}
const code = clean(location.hash.slice(1)) || clean(store.get('apex-last-code'));
if (!code || code.length < 4) showPair();
else { store.set('apex-last-code', code); if (location.hash.slice(1) !== code) history.replaceState(null, '', '#' + code); start(code); }

function connectTo(c) { store.set('apex-last-code', c); location.hash = c; location.reload(); }

function showPair() {
  $('#pair').hidden = false; $('#key').hidden = true;
  const inp = $('#pair-code');
  inp.value = store.get('apex-last-code') || '';
  $('#pair-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const c = clean(inp.value);
    if (c.length >= 4) connectTo(c);
  });
  $('#scan').addEventListener('click', scanQR);
}

/* in-app QR scanner (camera + jsQR), so the native app can pair without leaving */
async function scanQR() {
  const box = $('#scanner'), video = $('#scan-video'), msg = $('#scan-msg');
  box.hidden = false; msg.textContent = 'Point at the QR code on the showroom screen';
  let stream, stop = false;
  const close = () => { stop = true; stream && stream.getTracks().forEach(t => t.stop()); box.hidden = true; };
  $('#scan-close').onclick = close;
  try {
    if (!window.jsQR) await new Promise((ok, no) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js'; s.onload = ok; s.onerror = no; document.head.appendChild(s); });
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
  } catch (e) {
    msg.textContent = 'Camera unavailable. Type the code instead.'; setTimeout(close, 1800); return;
  }
  video.srcObject = stream; video.setAttribute('playsinline', ''); await video.play();
  const cv = document.createElement('canvas'), g = cv.getContext('2d', { willReadFrequently: true });
  const tick = () => {
    if (stop) return;
    if (video.readyState >= 2) {
      const w = 480, h = Math.round(480 * video.videoHeight / video.videoWidth) || 360;
      cv.width = w; cv.height = h; g.drawImage(video, 0, 0, w, h);
      const hit = window.jsQR(g.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: 'dontInvert' });
      const c = hit && codeFrom(hit.data);
      if (c && c.length >= 4) { buzz(30); close(); connectTo(c); return; }
    }
    requestAnimationFrame(tick);
  };
  tick();
}

function start(code) {
  $('#key').hidden = false;
  $('#car-code').textContent = code;
  document.body.classList.add('disabled');
  const link = createRemote(code);
  const send = (c, v) => link.send({ t: 'cmd', c, v });
  let S = null, connected = false;

  /* connection status */
  const conn = $('#conn');
  function setConn(state) {
    const txt = { connecting: 'Connecting…', searching: 'Searching…', connected: 'Connected', nohost: 'Car not found', lost: 'Reconnecting…', error: 'Reconnecting…' }[state] || state;
    conn.querySelector('span').textContent = txt;
    conn.className = 'conn ' + (state === 'connected' ? 'ok' : state === 'nohost' ? 'bad' : '');
  }
  link.on('status', (s) => { if (s !== 'connected') { connected = false; document.body.classList.add('disabled'); } setConn(s); });
  setInterval(() => {
    const ok = link.open && S;
    if (ok && !connected) { connected = true; document.body.classList.remove('disabled'); setConn('connected'); buzz(15); }
    else if (!ok && connected) { connected = false; document.body.classList.add('disabled'); setConn('searching'); }
  }, 300);
  // Forget the paired car: always available, connected or not
  const forget = () => { history.replaceState(null, '', location.pathname); store.set('apex-last-code', ''); location.reload(); };
  $('#change-car').addEventListener('click', forget);
  $('#lost-pair').addEventListener('click', forget);
  $('#forget').addEventListener('click', () => {
    if (!connected || confirm(`Forget car ${code}? You'll need to scan its QR code again.`)) forget();
  });
  // after a few seconds of searching, offer to pair a different car
  $('#lost-code').textContent = code;
  let lostSince = performance.now();
  setInterval(() => {
    if (connected) lostSince = performance.now();
    $('#lost').hidden = connected || performance.now() - lostSince < 6000;
  }, 500);

  /* incoming */
  link.on('message', (m) => {
    if (!m) return;
    if (m.t === 'state') { S = m; render(); }
    else if (m.t === 'evt') {
      if (m.kind === 'limiter') buzz(12);
      else if (m.kind === 'shift') buzz(35);
      else if (m.kind === 'deny') { buzz([20, 50, 20]); flashHint(m.text); }
    }
  });

  /* round buttons */
  document.querySelectorAll('[data-cmd]').forEach(b => b.addEventListener('click', () => { buzz(10); send(b.dataset.cmd); }));

  /* engine: hold to start / stop */
  const eng = $('#engine'), prog = $('#engine-prog');
  const HOLD = 650; let holdStart = 0, holdRAF = 0;
  const C = 289;
  function holdTick() {
    const p = Math.min(1, (performance.now() - holdStart) / HOLD);
    prog.style.strokeDashoffset = C * (1 - p);
    if (p >= 1) { endHold(true); return; }
    holdRAF = requestAnimationFrame(holdTick);
  }
  function endHold(fire) {
    cancelAnimationFrame(holdRAF); holdStart = 0;
    prog.style.transition = 'stroke-dashoffset .25s'; prog.style.strokeDashoffset = C;
    setTimeout(() => (prog.style.transition = ''), 260);
    if (fire) { buzz([30, 40, 60]); send('engine'); }
  }
  eng.addEventListener('pointerdown', (e) => { e.preventDefault(); if (holdStart) return; holdStart = performance.now(); buzz(8); holdTick(); });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach(ev => eng.addEventListener(ev, () => { if (holdStart) endHold(false); }));
  eng.addEventListener('contextmenu', e => e.preventDefault());

  /* throttle pad: a gas pedal. Hold it and the revs keep climbing (full in ~1.8 s); let go and they drop. */
  const pad = $('#throttle'), fill = $('#thr-fill'), tval = $('#thr-val');
  const RAMP = 1.8;
  const pedal = (sec) => 0.12 + 0.88 * Math.pow(Math.min(1, sec / RAMP), 1.4);
  let thr = 0, pid = null, thrTimer = 0, holdAt = 0, raf = 0, lastStep = 0;
  function setThr(v) {
    thr = v;
    fill.style.height = (v * 100).toFixed(0) + '%';
    tval.textContent = v > 0 ? Math.round(v * 100) + '%' : '';
  }
  const pushThr = () => link.send({ t: 'thr', v: +thr.toFixed(3) });
  function ramp() {
    if (pid === null) return;
    setThr(pedal((performance.now() - holdAt) / 1000));
    const step = Math.floor(thr * 10);
    if (step !== lastStep) { lastStep = step; buzz(6); }
    raf = requestAnimationFrame(ramp);
  }
  pad.addEventListener('pointerdown', (e) => {
    e.preventDefault(); pid = e.pointerId; pad.setPointerCapture(pid); pad.classList.add('on');
    holdAt = performance.now(); lastStep = 0; buzz(8);
    ramp(); pushThr();
    clearInterval(thrTimer); thrTimer = setInterval(pushThr, 50);
  });
  const release = (e) => {
    if (e.pointerId !== pid) return;
    pid = null; cancelAnimationFrame(raf); pad.classList.remove('on'); clearInterval(thrTimer);
    setThr(0); pushThr(); setTimeout(pushThr, 80);
  };
  pad.addEventListener('pointerup', release); pad.addEventListener('pointercancel', release);
  pad.addEventListener('contextmenu', e => e.preventDefault());

  /* launch */
  $('#launch').addEventListener('click', () => { buzz(20); send('launch'); });

  /* garage */
  const sw = $('#sw');
  PAINTS.forEach(hex => {
    const b = document.createElement('button'); b.style.setProperty('--c', hex); b.dataset.hex = hex;
    b.addEventListener('click', () => { buzz(8); send('paint', hex); }); sw.appendChild(b);
  });
  $('#t-wing').addEventListener('click', () => S && send('wing', !S.wing));
  $('#t-livery').addEventListener('click', () => S && send('livery', !S.livery));
  const horn = $('#horn');
  horn.addEventListener('pointerdown', (e) => { e.preventDefault(); send('horn', true); buzz(30); });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach(ev => horn.addEventListener(ev, () => send('horn', false)));

  /* shift lights */
  const shift = $('#shift');
  shift.innerHTML = '<i></i>'.repeat(10);
  const leds = [...shift.children];

  /* render */
  let lastTitle = '', hintLock = 0;
  function flashHint(text) { $('#hint').textContent = text; hintLock = performance.now() + 1800; }
  function render() {
    if (!S) return;
    let title, sub = '';
    if (S.locked) title = 'Locked';
    else if (S.starting) title = 'Starting';
    else if (S.mode === 'arm') title = S.cd > 0 ? String(S.cd) : 'GO';
    else if (S.mode === 'run' || S.mode === 'coast') { title = `${S.speed}<small>km/h</small>`; sub = `GEAR ${S.gear} · ${S.rpm.toLocaleString('en-US')} RPM${S.t100 ? ` · 0–100 ${S.t100.toFixed(2)}s` : ''}`; }
    else if (S.running) { title = `${S.rpm.toLocaleString('en-US')}<small>rpm</small>`; sub = S.t100 ? `Last launch: 0–100 in ${S.t100.toFixed(2)} s` : 'Idle · neutral'; }
    else title = 'Unlocked';
    const t = $('#title');
    if (title !== lastTitle) {
      const kind = (s) => s.replace(/[\d,]+/g, '#');
      const changedKind = kind(title) !== kind(lastTitle);
      t.innerHTML = title; lastTitle = title;
      if (changedKind) { t.classList.remove('pop'); void t.offsetWidth; t.classList.add('pop'); }
    }
    $('#sub').textContent = sub;

    $('#b-unlock').classList.toggle('on', !S.locked);
    $('#b-lock').classList.toggle('on', S.locked);
    $('#b-doors').classList.toggle('on', S.doors);
    $('#b-lights').classList.toggle('on', S.lights > 0);
    $('#l-lights').textContent = S.lights === 2 ? 'High' : 'Lights';
    eng.classList.toggle('running', S.running || S.starting);
    const L = $('#launch');
    L.classList.toggle('ready', S.running && S.mode === 'idle');
    L.classList.toggle('armed', S.mode === 'arm' || S.mode === 'run');
    L.textContent = S.mode === 'arm' ? 'Armed — tap to abort' : S.mode === 'run' ? 'Abort' : 'Launch';
    if (performance.now() > hintLock) {
      $('#hint').textContent = S.locked ? 'Unlock the car to begin.'
        : S.running ? (S.mode === 'idle' ? 'Hold the throttle: the longer you hold, the harder it revs.' : 'Hold on…')
        : 'Hold the engine button to start it.';
    }

    // shift lights: 5000 → 8800 rpm
    const r = S.rpm;
    const n = S.running ? Math.max(0, Math.min(10, Math.ceil((r - 5000) / 380))) : 0;
    const flash = r > 8800 && (performance.now() / 70 | 0) % 2 === 0;
    shift.classList.toggle('flash', flash);
    leds.forEach((el, i) => { el.className = i < n ? (i < 4 ? 'g' : i < 7 ? 'y' : 'r') : ''; });

    sw.querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.hex === S.paint));
    $('#t-wing').classList.toggle('on', !!S.wing);
    $('#t-livery').classList.toggle('on', !!S.livery);
  }

  // keep the screen awake while holding the key
  async function wake() { try { await navigator.wakeLock?.request('screen'); } catch {} }
  wake(); document.addEventListener('visibilitychange', () => !document.hidden && wake());
}
