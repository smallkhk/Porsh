import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { createCar, DIM } from './car.js';
import { EngineAudio } from './engine-audio.js';
import { createHost, makeCode, publicBase } from './link.js';

const $ = (s) => document.querySelector(s);
const params = new URLSearchParams(location.search);

/* =========================================================
   Renderer / scene
   ========================================================= */
const canvas = $('#scene');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x07080b);
scene.fog = new THREE.FogExp2(0x07080b, 0.055);

const pmrem = new THREE.PMREMGenerator(renderer);
// custom car-studio environment: dark cyclorama + long softbox strips
function studioEnv() {
  const env = new THREE.Scene();
  env.add(new THREE.Mesh(new THREE.SphereGeometry(30, 32, 16), new THREE.MeshBasicMaterial({ color: 0x0b0d12, side: THREE.BackSide })));
  const panel = (w, h, I, pos, rot, tint = [1, 1, 1]) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(I * tint[0], I * tint[1], I * tint[2]), side: THREE.DoubleSide }));
    m.position.set(...pos); m.rotation.set(...rot); env.add(m);
  };
  panel(14, 2.2, 5, [0, 9, 0], [Math.PI / 2, 0, 0]);               // overhead strip
  panel(14, 0.7, 3.5, [0, 8.5, 3.2], [Math.PI / 2, 0, 0]);
  panel(14, 0.7, 3.5, [0, 8.5, -3.2], [Math.PI / 2, 0, 0]);
  panel(18, 0.9, 2.2, [0, 2.6, 14], [0, 0, 0]);                     // side strips (long reflections in the doors)
  panel(18, 0.9, 2.2, [0, 2.6, -14], [0, 0, 0]);
  panel(6, 5, 1.6, [-16, 3, 0], [0, Math.PI / 2, 0], [0.7, 0.8, 1.2]); // cool rim from behind
  panel(6, 5, 1.2, [16, 3, 0], [0, Math.PI / 2, 0], [1.2, 1, 0.85]);  // warm from front
  panel(40, 40, 0.05, [0, -0.2, 0], [Math.PI / 2, 0, 0]);
  return pmrem.fromScene(env, 0.02).texture;
}
scene.environment = studioEnv();
scene.environmentIntensity = 1.25;

const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 120);
camera.position.set(7.5, 2.2, 7.2);

const controls = new OrbitControls(camera, canvas);
controls.target.set(0, 0.62, 0);
controls.enableDamping = true;
controls.dampingFactor = 0.06;
controls.minDistance = 4.2;
controls.maxDistance = 14;
controls.maxPolarAngle = Math.PI * 0.49;
controls.enablePan = false;
controls.autoRotateSpeed = 0.35;

// lighting
// shadow-casting key, kept gentle
const key = new THREE.SpotLight(0xffffff, 55, 30, 0.62, 0.75, 1.5);
key.position.set(0.5, 9, 1.5);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
key.shadow.bias = -0.0002;
key.shadow.radius = 6;
scene.add(key, key.target);
// overhead studio strips (visible in the paint reflections)
for (const z of [-1.6, 0, 1.6]) {
  const strip = new THREE.Mesh(new THREE.BoxGeometry(6, 0.02, 0.12), new THREE.MeshBasicMaterial({ color: new THREE.Color(2.2, 2.2, 2.4), toneMapped: false }));
  strip.position.set(0, 4.6, z); scene.add(strip);
}

// floor: rolling-road texture so the car can "drive" in place
function floorTexture() {
  const c = document.createElement('canvas'); c.width = c.height = 512;
  const g = c.getContext('2d');
  g.fillStyle = '#0c0d11'; g.fillRect(0, 0, 512, 512);
  // subtle concrete grain
  const img = g.getImageData(0, 0, 512, 512);
  for (let i = 0; i < img.data.length; i += 4) {
    const n = (Math.random() - 0.5) * 10;
    img.data[i] += n; img.data[i + 1] += n; img.data[i + 2] += n;
  }
  g.putImageData(img, 0, 0);
  g.strokeStyle = 'rgba(255,255,255,0.055)'; g.lineWidth = 2;
  g.strokeRect(0, 0, 512, 512);
  g.fillStyle = 'rgba(255,255,255,0.10)';
  g.fillRect(0, 252, 180, 8); // dashed lane mark
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(24, 24); t.anisotropy = 8; t.colorSpace = THREE.SRGBColorSpace;
  return t;
}
const floorTex = floorTexture();
const floor = new THREE.Mesh(new THREE.PlaneGeometry(80, 80), new THREE.MeshStandardMaterial({ map: floorTex, roughness: 0.38, metalness: 0.3, color: 0x9096a0 }));
floor.rotation.x = -Math.PI / 2; floor.receiveShadow = true; scene.add(floor);
// soft contact shadow
const shadowTex = (() => {
  const c = document.createElement('canvas'); c.width = c.height = 256; const g = c.getContext('2d');
  const gr = g.createRadialGradient(128, 128, 10, 128, 128, 128);
  gr.addColorStop(0, 'rgba(0,0,0,0.85)'); gr.addColorStop(0.6, 'rgba(0,0,0,0.45)'); gr.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = gr; g.fillRect(0, 0, 256, 256); return new THREE.CanvasTexture(c);
})();
const contact = new THREE.Mesh(new THREE.PlaneGeometry(6.2, 2.9), new THREE.MeshBasicMaterial({ map: shadowTex, transparent: true, depthWrite: false }));
contact.rotation.x = -Math.PI / 2; contact.position.y = 0.003; scene.add(contact);
// speed streaks
const streaks = new THREE.Group(); scene.add(streaks);
const streakMat = new THREE.MeshBasicMaterial({ color: new THREE.Color(1.6, 1.7, 2), transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false });
for (let i = 0; i < 40; i++) {
  const s = new THREE.Mesh(new THREE.PlaneGeometry(3 + Math.random() * 4, 0.025), streakMat);
  s.rotation.x = -Math.PI / 2;
  s.position.set((Math.random() - 0.5) * 40, 0.01 + Math.random() * 0.02, (Math.random() < 0.5 ? -1 : 1) * (2 + Math.random() * 6));
  streaks.add(s);
}

/* car */
const car = createCar();
scene.add(car.root);

/* post */
const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
const bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0.7, 0.45, 1.8);
composer.addPass(bloom);
composer.addPass(new OutputPass());

function resize() {
  const w = innerWidth, h = innerHeight;
  renderer.setSize(w, h, false);
  composer.setSize(w, h);
  camera.aspect = w / h;
  // shift the car right on wide screens so the headline has room
  if (w / h > 1.25 && !document.body.classList.contains('film')) camera.setViewOffset(w, h, -w * 0.1, 0, w, h);
  else camera.clearViewOffset();
  camera.updateProjectionMatrix();
}
addEventListener('resize', resize); resize();

/* =========================================================
   Simulation
   ========================================================= */
const IDLE = 950, LIMIT = 9000;
const GEAR_TOP = [0, 72, 118, 162, 207, 252, 305]; // km/h at limiter per gear
const PAINTS = [
  ['Voltage Blue', '#1b55e0'], ['Lava Orange', '#ff5a1f'], ['Signal Red', '#c8101e'], ['Chalk', '#d9d6cf'],
  ['Acid Green', '#9fe01b'], ['Obsidian', '#0d0e12'], ['Ultraviolet', '#5a2bd6'], ['Arctic Silver', '#a9b0bb'],
];

const S = {
  locked: true, doors: false, lights: 0,
  running: false, starting: false,
  rpm: 0, thr: 0, thrInput: 0, thrAt: 0, keyThr: 0,
  gear: 'N', speed: 0, // km/h
  mode: 'idle', // idle | arm | run | coast
  modeT: 0, cut: 0, shiftCut: 0,
  t100: null, vmax: 0,
  paint: PAINTS[0][1], wing: true, livery: true, rim: '#1a1b1f',
  remotes: 0,
};
const audio = new EngineAudio();
let crackle = []; // scheduled pop times
let lastThr = 0;

function popBurst(n, spread = 0.7, strength = 1) {
  const now = performance.now() / 1000;
  for (let i = 0; i < n; i++) crackle.push({ t: now + Math.random() * spread, s: strength * (0.5 + Math.random() * 0.6) });
}

function deny(text) { toast(text); host && host.send({ t: 'evt', kind: 'deny', text }); }

function cmd(name, arg) {
  switch (name) {
    case 'unlock':
      if (!S.locked) return;
      S.locked = false;
      audio.chirp('unlock'); audio.thud(0.6, 1.6);
      car.hazard(2); car.sweep(1); car.setDRL(true);
      setStatus();
      break;
    case 'lock':
      if (S.locked) return;
      if (S.running) stopEngine();
      if (S.doors) { S.doors = false; car.setDoors(false); setTimeout(() => audio.thud(1, 0.9), 650); }
      S.locked = true; S.lights = 0; car.setLights(0);
      audio.chirp('lock'); audio.thud(0.6, 1.6);
      car.hazard(1); car.sweep(-1);
      setTimeout(() => { if (S.locked) car.setDRL(false); }, 900);
      setStatus();
      break;
    case 'toggleLock': cmd(S.locked ? 'unlock' : 'lock'); break;
    case 'doors':
      if (S.locked) return deny('Unlock the car first');
      if (S.mode === 'run' || S.speed > 2) return deny('Not while moving');
      S.doors = !S.doors; car.setDoors(S.doors);
      if (S.doors) audio.thud(0.5, 1.3); else setTimeout(() => audio.thud(1, 0.9), 650);
      setStatus();
      break;
    case 'lights':
      if (S.locked) return deny('Unlock the car first');
      S.lights = (S.lights + 1) % 3; car.setLights(S.lights); audio.click();
      setStatus();
      break;
    case 'engine':
      if (S.locked) return deny('Unlock the car first');
      if (S.running || S.starting) stopEngine(); else startEngine();
      break;
    case 'throttle':
      S.thrInput = Math.max(0, Math.min(1, +arg || 0)); S.thrAt = performance.now();
      break;
    case 'launch':
      if (S.mode === 'arm' || S.mode === 'run') { S.mode = 'coast'; S.modeT = 0; hideCountdown(); setStatus(); return; }
      if (!S.running) return deny(S.locked ? 'Unlock and start the engine first' : 'Start the engine first');
      if (S.doors) { S.doors = false; car.setDoors(false); setTimeout(() => audio.thud(1, 0.9), 650); }
      if (S.lights === 0) { S.lights = 1; car.setLights(1); }
      S.mode = 'arm'; S.modeT = 0; S.t100 = null; S.vmax = 0;
      setStatus();
      break;
    case 'horn': audio.horn(!!arg); break;
    case 'paint':
      S.paint = arg; car.setPaint(arg); syncPaintUI(); setStatus(false); break;
    case 'wing': S.wing = !!arg; car.setWing(S.wing); $('#opt-wing').checked = S.wing; setStatus(false); break;
    case 'livery': S.livery = !!arg; car.setLivery(S.livery); $('#opt-livery').checked = S.livery; setStatus(false); break;
    case 'rim': S.rim = arg; car.setRim(arg); syncRimUI(); setStatus(false); break;
  }
}

function startEngine() {
  S.starting = true; S.modeT = 0;
  audio.starter(1.0);
  car.setDRL(true);
  if (S.doors) { /* fine, revs with doors up look great */ }
  setStatus();
  setTimeout(() => {
    if (!S.starting) return;
    S.starting = false; S.running = true;
    S.rpm = 2600; // catch + flare
    popBurst(3, 0.3, 0.8);
    car.flames(0.6);
    setStatus();
  }, 1000);
}
function stopEngine() {
  S.starting = false; S.running = false; S.mode = 'idle'; S.gear = 'N';
  hideCountdown();
  setStatus();
}

const keys = new Set();
function step(dt, now) {
  // throttle: remote input expires if the phone goes quiet
  if (performance.now() - S.thrAt > 700) S.thrInput = 0;
  // keyboard throttle behaves like the phone's pedal: the longer you hold, the harder it revs
  S.keyRamp = S.keyHeld ? (S.keyRamp || 0) + dt : 0;
  S.keyThr = S.keyHeld ? 0.12 + 0.88 * Math.pow(Math.min(1, S.keyRamp / 1.8), 1.4) : 0;
  let thr = Math.max(S.thrInput, S.keyThr);
  if (!S.running) thr = 0;

  if (S.starting) {
    S.rpm = 180 + Math.sin(now * 40) * 60 + S.modeT * 120;
    S.modeT += dt;
  } else if (!S.running) {
    S.rpm = Math.max(0, S.rpm - dt * 2600);
  } else if (S.mode === 'idle') {
    S.gear = 'N';
    const target = IDLE + Math.pow(thr, 1.15) * (LIMIT + 300 - IDLE);
    if (S.cut > 0) { S.cut -= dt; thr = 0; S.rpm -= dt * 9000; }
    else if (S.rpm < target) S.rpm += Math.min(target - S.rpm, dt * (6000 + 16000 * thr));
    else S.rpm -= Math.min(S.rpm - target, dt * 6200);
    if (S.rpm >= LIMIT) { S.rpm = LIMIT; S.cut = 0.055; limiterHit(); }
    S.rpm += (Math.random() - 0.5) * 18;
    // lift-off crackle
    if (lastThr > 0.45 && thr < 0.1 && S.rpm > 4500) popBurst(4 + (Math.random() * 5 | 0), 0.9, 1);
  } else if (S.mode === 'arm') {
    S.modeT += dt;
    const target = 5200;
    if (S.cut > 0) { S.cut -= dt; S.rpm -= dt * 8000; }
    else S.rpm += Math.min(target - S.rpm, dt * 14000);
    if (S.rpm >= target - 5 && S.cut <= 0) { S.cut = 0.07 + Math.random() * 0.05; if (Math.random() < 0.5) { popBurst(1, 0.05, 0.7); } }
    thr = 1;
    const n = 3 - Math.floor(S.modeT);
    showCountdown(n > 0 ? String(n) : 'GO');
    if (S.modeT >= 3) { S.mode = 'run'; S.modeT = 0; S.gear = 1; S.speed = 0; setStatus(); }
  } else if (S.mode === 'run') {
    S.modeT += dt; thr = 1;
    const g = S.gear;
    const v = S.speed / 3.6;
    const vmax = 330 / 3.6;
    let a = [0, 10.5, 8.6, 7.0, 5.9, 4.9, 4.0][g] * (1 - Math.pow(v / vmax, 2.2));
    if (S.shiftCut > 0) { S.shiftCut -= dt; a = 0.4; thr = 0.1; }
    S.speed += a * dt * 3.6;
    const gearRpm = (S.speed / GEAR_TOP[g]) * LIMIT;
    const slip = Math.max(0, 1 - S.modeT / 0.55) * 5200;
    const want = Math.max(IDLE, gearRpm, slip);
    S.rpm += (want - S.rpm) * Math.min(1, dt * (S.shiftCut > 0 ? 18 : 30));
    if (S.rpm > 8750 && g < 6 && S.shiftCut <= 0) {
      S.gear = g + 1; S.shiftCut = 0.11; popBurst(2, 0.12, 1.1); car.flames(1); shiftHit();
    }
    if (S.t100 === null && S.speed >= 100) S.t100 = S.modeT;
    S.vmax = Math.max(S.vmax, S.speed);
    if (S.speed >= 280 || S.modeT > 13) { S.mode = 'coast'; S.modeT = 0; popBurst(8, 1.2, 1.2); setStatus(); }
  } else if (S.mode === 'coast') {
    S.modeT += dt; thr = 0;
    const v = S.speed / 3.6;
    const decel = 7.5 + 0.0009 * v * v;
    S.speed = Math.max(0, S.speed - decel * dt * 3.6);
    let g = S.gear === 'N' ? 1 : S.gear;
    let r = (S.speed / GEAR_TOP[g]) * LIMIT;
    if (r < 3800 && g > 1) { S.gear = g - 1; popBurst(2, 0.25, 0.9); car.flames(0.7); }
    g = S.gear === 'N' ? 1 : S.gear;
    r = Math.max(IDLE, (S.speed / GEAR_TOP[g]) * LIMIT);
    if (S.speed < 6) r = IDLE;
    S.rpm += (r - S.rpm) * Math.min(1, dt * 12);
    if (S.speed <= 0.1) { S.speed = 0; S.mode = 'idle'; S.gear = 'N'; setStatus(); }
  }
  S.thr += (thr - S.thr) * Math.min(1, dt * 20);
  lastThr = thr;
  S.rpm = Math.max(0, S.rpm);

  // crackle scheduler (only off-throttle or during shifts)
  const tNow = performance.now() / 1000;
  crackle = crackle.filter(p => {
    if (p.t > tNow) return true;
    if (S.running) { audio.pop(p.s); car.flames(0.6 + p.s * 0.6); }
    return false;
  });
  // random over-run burble while revs fall
  if (S.running && S.mode === 'idle' && thr < 0.05 && S.rpm > 3200 && Math.random() < dt * 6) { audio.pop(0.5); car.flames(0.35); }
}

let limiterAt = 0;
function limiterHit() {
  const n = performance.now();
  if (Math.random() < 0.6) { audio.pop(0.8); car.flames(0.9); }
  if (n - limiterAt > 250) { limiterAt = n; host && host.send({ t: 'evt', kind: 'limiter' }); }
}
function shiftHit() { host && host.send({ t: 'evt', kind: 'shift' }); }

/* =========================================================
   UI
   ========================================================= */
let statusText = '';
function setStatus(broadcast = true) {
  let title, hint;
  if (S.locked) { title = 'Locked.'; hint = S.remotes ? 'Tap Unlock on your phone.' : 'Scan the code with your phone to get the key, then unlock the car.'; }
  else if (S.starting) { title = 'Starting…'; hint = 'Ignition.'; }
  else if (S.mode === 'arm') { title = 'Launch.'; hint = 'Launch control armed. Hold tight.'; }
  else if (S.mode === 'run') { title = 'Full send.'; hint = 'Launching through the gears.'; }
  else if (S.mode === 'coast') { title = 'Lifting.'; hint = 'Coming back down.'; }
  else if (S.running) { title = 'Running.'; hint = 'Use the throttle pad to rev it. Tap Launch for a full launch run.'; }
  else { title = 'Unlocked.'; hint = 'Open the doors, or hold the engine button on your key to start it.'; }
  const h1 = $('#status');
  if (title !== statusText) { statusText = title; h1.textContent = title; h1.classList.remove('swap'); void h1.offsetWidth; h1.classList.add('swap'); }
  $('#hint').textContent = hint;
  S.hint = hint;
  if (broadcast) sendState(true);
}

let toastTimer;
function toast(text) {
  const t = $('#toast'); t.textContent = text; t.classList.add('on');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('on'), 1800);
}
let cdLast = '';
function showCountdown(txt) {
  if (txt === cdLast) return; cdLast = txt;
  const el = $('#countdown'); el.textContent = txt;
  el.classList.toggle('go', txt === 'GO');
  el.classList.remove('pulse'); void el.offsetWidth; el.classList.add('pulse');
  if (txt === 'GO') audio.chirp('go');
}
function hideCountdown() { cdLast = ''; $('#countdown').classList.remove('pulse'); $('#countdown').textContent = ''; }

// tabs
let openTab = null;
function showPanel(tab) {
  openTab = tab;
  document.querySelectorAll('.tabs button').forEach(x => x.classList.toggle('active', x.dataset.tab === openTab));
  document.querySelectorAll('.panel').forEach(p => p.classList.toggle('open', p.id === 'panel-' + openTab));
}
document.querySelectorAll('.tabs button').forEach(b => b.addEventListener('click', () => showPanel(openTab === b.dataset.tab ? null : b.dataset.tab)));
document.querySelectorAll('[data-cmd]').forEach(b => b.addEventListener('click', () => {
  const c = b.dataset.cmd;
  cmd(c === 'unlock' || c === 'lock' ? c : c);
}));
$('#opt-wing').addEventListener('change', e => cmd('wing', e.target.checked));
$('#opt-livery').addEventListener('change', e => cmd('livery', e.target.checked));
document.querySelectorAll('#rims button').forEach(b => b.addEventListener('click', () => cmd('rim', b.dataset.rim)));
const paintsEl = $('#paints');
PAINTS.forEach(([name, hex]) => {
  const b = document.createElement('button'); b.style.setProperty('--c', hex); b.title = name; b.dataset.hex = hex;
  b.addEventListener('click', () => cmd('paint', hex)); paintsEl.appendChild(b);
});
function syncPaintUI() {
  paintsEl.querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.hex === S.paint));
  const p = PAINTS.find(p => p[1] === S.paint); $('#paint-name').textContent = p ? p[0] : S.paint;
}
function syncRimUI() { document.querySelectorAll('#rims button').forEach(b => b.classList.toggle('on', b.dataset.rim === S.rim)); }
syncPaintUI();

// sound + film
const soundBtn = $('#sound');
function syncSound() { soundBtn.textContent = audio.enabled ? 'Sound on' : 'Sound off'; soundBtn.classList.toggle('on', audio.enabled); }
soundBtn.addEventListener('click', async () => { if (audio.enabled) audio.disable(); else await audio.enable(); syncSound(); });
let film = false;
function toggleFilm() {
  film = !film; document.body.classList.toggle('film', film); $('#film').classList.toggle('on', film);
  controls.autoRotate = film; controls.autoRotateSpeed = film ? 0.9 : 0.35; resize();
}
$('#film').addEventListener('click', toggleFilm);

// keyboard
addEventListener('keydown', (e) => {
  if (e.repeat || e.target.tagName === 'INPUT') return;
  const k = e.key.toLowerCase();
  if (k === 'u') cmd('toggleLock');
  else if (k === 'k') cmd('lock');
  else if (k === 'd') cmd('doors');
  else if (k === 'l') cmd('lights');
  else if (k === 'e') cmd('engine');
  else if (k === 'x') cmd('launch');
  else if (k === 'f') toggleFilm();
  else if (k === 'h') cmd('horn', true);
  else if (k === ' ' || k === 'w' || k === 'arrowup') { S.keyHeld = true; e.preventDefault(); }
});
addEventListener('keyup', (e) => {
  const k = e.key.toLowerCase();
  if (k === 'h') cmd('horn', false);
  if (k === ' ' || k === 'w' || k === 'arrowup') S.keyHeld = false;
});

// gauge
const gsvg = $('#gauge-svg');
const GA0 = 225, GSWEEP = 270, GMAX = 10000, GCX = 110, GCY = 112, GR = 88;
const ang = (rpm) => (GA0 - (rpm / GMAX) * GSWEEP) * Math.PI / 180;
const pt = (a, r) => [GCX + Math.cos(a) * r, GCY - Math.sin(a) * r];
const arcPath = (r0, r1, R) => {
  const [x0, y0] = pt(ang(r0), R), [x1, y1] = pt(ang(r1), R);
  const large = ((r1 - r0) / GMAX) * GSWEEP > 180 ? 1 : 0;
  return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${R} ${R} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`;
};
gsvg.innerHTML = `<defs><linearGradient id="g-arc" gradientUnits="userSpaceOnUse" x1="20" y1="0" x2="200" y2="0"><stop offset="0" stop-color="#7fb2ff"/><stop offset=".7" stop-color="#ffffff"/><stop offset="1" stop-color="#ff5b5b"/></linearGradient></defs>
  <path class="arc-bg" d="${arcPath(0, GMAX, GR)}"/>
  <path class="arc-red" d="${arcPath(LIMIT - 1000, GMAX, GR)}"/>
  <path class="arc" id="arc" d=""/>
  ${Array.from({ length: 11 }, (_, i) => {
    const a = ang(i * 1000), [x0, y0] = pt(a, GR - 12), [x1, y1] = pt(a, GR - 18), [lx, ly] = pt(a, GR - 30);
    return `<line class="tick" x1="${x0}" y1="${y0}" x2="${x1}" y2="${y1}"/><text class="tick-l" x="${lx}" y="${ly}">${i}</text>`;
  }).join('')}`;
const arcEl = $('#arc');

let uiAcc = 0;
function updateUI(dt) {
  uiAcc += dt; if (uiAcc < 1 / 30) return; uiAcc = 0;
  const on = S.running || S.starting || S.rpm > 50;
  $('#gauge').classList.toggle('on', on);
  arcEl.setAttribute('d', S.rpm > 30 ? arcPath(0, Math.min(GMAX, S.rpm), GR) : '');
  $('#gauge').classList.toggle('limiter', S.rpm > LIMIT - 150);
  $('#gear').textContent = S.gear;
  $('#rpm').textContent = Math.round(S.rpm).toLocaleString('en-US');
  $('#speed').textContent = Math.round(S.speed);
  $('#t100').textContent = S.t100 ? `0–100 in ${S.t100.toFixed(2)} s` : '';
}

/* =========================================================
   Phone link
   ========================================================= */
let host = null, newCodeBound = false;
// The code is remembered, so a paired phone reconnects by itself next time.
const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
let code = (params.get('code') || store.get('apex-code') || makeCode()).toUpperCase();
function startLink() {
  store.set('apex-code', code);
  host = createHost(code);
  const url = `${publicBase()}remote.html#${code}`;
  $('#code').textContent = code;
  const a = $('#remote-link'); a.href = url; a.textContent = url.replace(/^https?:\/\//, '');
  drawQR(url);
  host.on('status', (s) => {
    if (S.remotes) return;
    $('#link-status').textContent = s === 'ready' ? 'Waiting for your phone…' : s === 'local' ? 'Offline: same-browser key only.' : 'Reconnecting…';
  });
  host.on('count', (n) => {
    const was = S.remotes; S.remotes = n;
    const chip = $('#key-chip');
    chip.classList.toggle('on', n > 0);
    chip.querySelector('span').textContent = n > 0 ? (n === 1 ? 'Key connected' : `${n} keys connected`) : 'No key connected';
    if (n > 0) $('#link-status').textContent = 'Phone connected.';
    if (n > was) { toast('Phone key connected'); if (openTab === 'key') showPanel(null); }
    setStatus();
  });
  host.on('hello', () => sendState(true));
  host.on('collision', () => { host.destroy(); code = makeCode(); startLink(); });
  if (!newCodeBound) { newCodeBound = true; $('#new-code').addEventListener('click', () => { host.destroy(); code = makeCode(); startLink(); toast('New code. Paired keys must re-pair.'); }); }
  host.on('message', (m) => {
    if (!m || typeof m !== 'object') return;
    if (m.t === 'cmd') cmd(m.c, m.v);
    else if (m.t === 'thr') cmd('throttle', m.v);
  });
}
function drawQR(text) {
  const el = $('#qr');
  if (typeof qrcode === 'undefined') { el.textContent = ''; return; }
  const q = qrcode(0, 'M'); q.addData(text); q.make();
  el.innerHTML = q.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
}

let stateAcc = 0;
function sendState(force) {
  if (!host) return;
  host.send({
    t: 'state', locked: S.locked, doors: S.doors, lights: S.lights, running: S.running, starting: S.starting,
    rpm: Math.round(S.rpm), gear: S.gear, speed: Math.round(S.speed), mode: S.mode, t100: S.t100,
    paint: S.paint, wing: S.wing, livery: S.livery, hint: S.hint, cd: S.mode === 'arm' ? Math.max(0, 3 - Math.floor(S.modeT)) : null,
  });
}

/* =========================================================
   Loop
   ========================================================= */
const clock = new THREE.Clock();
let roll = 0, pitch = 0, prevSpeed = 0, intro = 0, idleT = 0;
controls.addEventListener('start', () => { idleT = 0; controls.autoRotate = film; });
const introFrom = new THREE.Vector3(9.5, 1.1, -6.5), introTo = new THREE.Vector3(5.4, 1.55, 4.4);
let introDone = false;

function frame() {
  const dt = Math.min(clock.getDelta(), 1 / 20);
  const now = clock.elapsedTime;

  step(dt, now);
  audio.update(S.rpm, S.thr, S.running || S.starting);

  // car body dynamics
  const accel = (S.speed - prevSpeed) / Math.max(dt, 1e-3) / 3.6; prevSpeed = S.speed;
  const torque = S.running ? S.thr * 0.012 + (S.rpm / LIMIT) * 0.004 : 0;
  roll += (torque - roll) * Math.min(1, dt * 8);
  pitch += (THREE.MathUtils.clamp(accel * 0.0028, -0.025, 0.03) - pitch) * Math.min(1, dt * 5);
  const shake = S.running ? 0.0012 + S.thr * 0.0016 + (S.rpm < 1300 ? 0.0012 : 0) : S.starting ? 0.003 : 0;
  car.chassis.position.y = (Math.random() - 0.5) * shake;
  car.chassis.rotation.x = roll + (Math.random() - 0.5) * shake * 1.5;
  car.chassis.rotation.z = pitch;
  car.setBrake(S.mode === 'coast' ? 1 : 0);

  // wheels + rolling road
  const v = S.speed / 3.6;
  car.spinWheels((v / DIM.wheelR) * dt * (S.mode === 'run' && S.modeT < 0.6 ? 1.6 : 1)); // a bit of wheelspin off the line
  floorTex.offset.x += (v * dt) / (80 / 24);
  streakMat.opacity = Math.min(0.55, v / 50);
  streaks.children.forEach(s => { s.position.x -= v * dt * 1.0; if (s.position.x < -20) s.position.x += 40; });

  car.update(dt, now);

  // camera intro + shake
  if (!introDone) {
    intro = Math.min(1, intro + dt / 3.2);
    const e = 1 - Math.pow(1 - intro, 3);
    camera.position.lerpVectors(introFrom, introTo, e);
    if (intro >= 1) introDone = true;
  }
  idleT += dt;
  if (!film && idleT > 12 && S.mode === 'idle') controls.autoRotate = true;
  controls.update();
  if (S.running) {
    const cs = (S.mode === 'run' ? 0.004 + v * 0.00012 : S.thr * 0.0025);
    camera.position.x += (Math.random() - 0.5) * cs; camera.position.y += (Math.random() - 0.5) * cs;
  }

  updateUI(dt);
  stateAcc += dt;
  if (stateAcc > 0.06) { stateAcc = 0; sendState(); }

  composer.render(dt);
  requestAnimationFrame(frame);
}

/* =========================================================
   Boot
   ========================================================= */
setStatus(false);
frame();
const enter = $('#enter');
function ready() {
  enter.disabled = false; enter.textContent = 'Enter showroom';
}
// wait for the deferred CDN scripts (PeerJS + QR)
if (document.readyState === 'complete') { startLink(); ready(); }
else addEventListener('load', () => { startLink(); ready(); });

async function go(withSound) {
  if (withSound) { try { await audio.enable(); } catch {} }
  syncSound();
  $('#splash').classList.add('gone');
  if (!S.remotes) setTimeout(() => !S.remotes && !openTab && showPanel('key'), 1800);
  intro = 0; introDone = false;
}
enter.addEventListener('click', () => go(true));
$('#enter-mute').addEventListener('click', () => go(false));
if (params.has('nosplash')) go(false);

// expose for debugging / automated checks
window.APEX = { S, cmd, car, camera, controls, scene, bloom, step, get link() { return host; }, skipIntro() { intro = 1; introDone = true; } };
