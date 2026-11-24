// APEX 9R — an original procedural supercar.
// The body is a loft: ~300 cross-sections along the length, each one generated
// from smooth profile curves (width, shoulder, hood, roof, wheel arches).
// Doors and glass are carved out of the same vertex grid, so every panel lines
// up perfectly and the doors can hinge open to reveal the cabin.
import * as THREE from 'three';

/* ---------- monotone cubic interpolation over keypoints ---------- */
function curve(pts) {
  const n = pts.length, xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
  const d = [], m = new Array(n);
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
  m[0] = d[0]; m[n - 1] = d[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (d[i] === 0) { m[i] = m[i + 1] = 0; continue; }
    const a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b;
    if (s > 9) { const t = 3 / Math.sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]; }
  }
  return (x) => {
    if (x <= xs[0]) return ys[0];
    if (x >= xs[n - 1]) return ys[n - 1];
    let i = 0; while (x > xs[i + 1]) i++;
    const h = xs[i + 1] - xs[i], t = (x - xs[i]) / h, t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1];
  };
}
const lerp = (a, b, t) => a + (b - a) * t;
const clamp01 = (v) => Math.max(0, Math.min(1, v));

/* ---------- design: all dimensions in metres, +x is the nose ---------- */
export const DIM = {
  xMin: -2.30, xMax: 2.32,
  wheelR: 0.355, wheelY: 0.355,
  front: { x: 1.42, track: 0.79 },
  rear: { x: -1.38, track: 0.835 },
  arch: { r: 0.45, y: 0.34 },
  door: [-0.86, 0.9],
  cabin: [-2.04, 0.96],
};

const W = curve([[-2.30, 0.82], [-2.2, 0.94], [-1.95, 1.0], [-1.4, 1.03], [-0.95, 0.99], [-0.5, 0.945], [0.3, 0.93], [0.9, 0.955], [1.45, 0.975], [1.9, 0.93], [2.18, 0.84], [2.32, 0.70]]);
const BELT = curve([[-2.30, 0.80], [-2.22, 0.9], [-2.0, 0.975], [-1.45, 1.0], [-0.95, 0.94], [-0.3, 0.9], [0.5, 0.895], [1.0, 0.925], [1.45, 0.935], [1.9, 0.86], [2.18, 0.73], [2.32, 0.58]]);
const HOOD = curve([[-2.30, 0.82], [-2.2, 0.915], [-2.0, 0.955], [-1.5, 0.985], [-0.5, 0.96], [0.4, 0.92], [0.96, 0.845], [1.4, 0.78], [1.9, 0.70], [2.18, 0.62], [2.32, 0.54]]);
const ROOF = curve([[-2.04, 0.955], [-1.6, 1.085], [-1.05, 1.225], [-0.5, 1.285], [0.0, 1.285], [0.2, 1.265], [0.62, 1.07], [0.96, 0.845]]);
const BOTTOM = curve([[-2.30, 0.27], [-2.0, 0.22], [2.0, 0.2], [2.32, 0.23]]);

function archY(x) {
  for (const cx of [DIM.front.x, DIM.rear.x]) {
    const dx = x - cx;
    if (Math.abs(dx) < DIM.arch.r) return DIM.arch.y + Math.sqrt(DIM.arch.r ** 2 - dx * dx);
  }
  return null;
}

/** Right-half cross-section at station x: 14 points [z, y] bottom-centre → top-centre. */
function section(x) {
  const w = W(x), belt = BELT(x), hood = HOOD(x), yb = BOTTOM(x);
  const inCabin = x > DIM.cabin[0] && x < DIM.cabin[1];
  const roof = inCabin ? Math.max(hood, ROOF(x)) : hood;
  const c = clamp01((roof - hood) / 0.08);
  const gb = Math.min(0.75, w - 0.2), gt = Math.min(0.585, gb - 0.1);
  const arch = archY(x);
  const ya = arch ?? yb + 0.05;
  const wi = 0.56;
  const yLow = ya + 0.05;
  const yShoulder = Math.max(belt - 0.075, yLow + 0.02);
  return [
    [0, yb],
    [wi, yb],
    [wi, ya],
    [w - 0.07, ya],
    [w, yLow],
    [w + 0.014, lerp(yLow, yShoulder, 0.5)],
    [w, yShoulder],
    [w - 0.075, belt],
    [gb + (w - 0.075 - gb) * 0.45, lerp(hood, belt, 0.62)],
    [gb, hood],
    [lerp(gb, gt, c), roof - 0.055 * c],
    [gt - 0.09 * c, roof],
    [0.17, roof + 0.008 * c],
    [0, roof + 0.01 * c],
  ];
}

/* segment tags: which material / part each strip of the cross-section belongs to */
function tagFor(x, seg, side) {
  const [d0, d1] = DIM.door;
  const inDoor = x > d0 && x < d1 && seg >= 3 && seg <= 9;
  const windshield = x > 0.14 && x < DIM.cabin[1];
  const rearGlass = x > -1.5 && x < -0.72;
  const sideGlass = x > -1.28 && x < DIM.cabin[1];
  if (seg <= 2) return 'under';
  if (inDoor) {
    const glass = seg === 9 && sideGlass;
    return (side > 0 ? 'doorR' : 'doorL') + (glass ? 'Glass' : '');
  }
  if (seg === 9) return sideGlass ? 'glass' : 'paint';
  if (seg === 10) return windshield ? 'glass' : 'paint';
  if (seg === 11) return windshield || rearGlass ? 'glass' : 'paint';
  if (seg === 12) return windshield || rearGlass ? 'glass' : 'stripe';
  return 'paint';
}

function buildBody() {
  // stations: dense, plus exact break points so panel boundaries are crisp
  const xs = new Set();
  for (let x = DIM.xMin; x <= DIM.xMax + 1e-6; x += 0.016) xs.add(+x.toFixed(4));
  const bps = [...DIM.door, ...DIM.cabin, 0.14, -1.5, -0.72, -1.28, DIM.xMin, DIM.xMax];
  for (const cx of [DIM.front.x, DIM.rear.x]) {
    for (const f of [-1, -0.995, -0.98, -0.95, -0.9, 0.9, 0.95, 0.98, 0.995, 1]) bps.push(cx + f * DIM.arch.r);
  }
  bps.forEach(b => { for (const v of [...xs]) if (Math.abs(v - b) < 0.004) xs.delete(v); xs.add(+b.toFixed(5)); });
  // nudge arch edges inward by a hair so the vertical step lands between stations
  const stations = [...xs].sort((a, b) => a - b);

  const rings = stations.map(x => {
    const r = section(x);
    const full = [...r];
    for (let j = 12; j >= 1; j--) full.push([-r[j][0], r[j][1]]);
    return full.map(([z, y]) => new THREE.Vector3(x, y, z));
  });
  const R = rings[0].length; // 26

  // rounded end caps
  function cap(ring, dir, depth) {
    let ymin = Infinity, ymax = -Infinity;
    ring.forEach(p => { ymin = Math.min(ymin, p.y); ymax = Math.max(ymax, p.y); });
    const cy = (ymin + ymax) / 2, x0 = ring[0].x, out = [];
    for (const a of [0.22, 0.45, 0.68, 0.9, 1.1, 1.28, 1.42, 1.52]) {
      const s = Math.cos(a), dx = Math.sin(a) * depth * dir;
      out.push(ring.map(p => new THREE.Vector3(x0 + dx, cy + (p.y - cy) * s, p.z * s)));
    }
    return { rings: out, center: new THREE.Vector3(x0 + depth * dir, cy, 0) };
  }
  const rearCap = cap(rings[0], -1, 0.05);
  const frontCap = cap(rings[rings.length - 1], 1, 0.07);
  const all = [...rearCap.rings.reverse(), ...rings, ...frontCap.rings];
  const stationX = [...rearCap.rings.map(() => DIM.xMin - 0.01), ...stations, ...frontCap.rings.map(() => DIM.xMax + 0.01)];

  const pos = [];
  all.forEach(r => r.forEach(p => pos.push(p.x, p.y, p.z)));
  const rearC = pos.length / 3; pos.push(rearCap.center.x, rearCap.center.y, rearCap.center.z);
  const frontC = pos.length / 3; pos.push(frontCap.center.x, frontCap.center.y, frontCap.center.z);

  const groups = {};
  const add = (tag, ...idx) => (groups[tag] ||= []).push(...idx);
  const segOf = (k) => (k <= 12 ? [k, 1] : [25 - k, -1]);
  for (let i = 0; i < all.length - 1; i++) {
    const xm = (stationX[i] + stationX[i + 1]) / 2;
    const nCap = rearCap.rings.length, isCap = i < nCap || i >= all.length - 1 - nCap;
    for (let k = 0; k < R; k++) {
      const a = i * R + k, b = (i + 1) * R + k, c = (i + 1) * R + (k + 1) % R, d = i * R + (k + 1) % R;
      const [seg, side] = segOf(k);
      let tag = isCap ? 'paint' : tagFor(xm, seg, side);
      // black intake mouth at the nose and diffuser band at the tail
      const qy = (pos[a * 3 + 1] + pos[b * 3 + 1] + pos[c * 3 + 1] + pos[d * 3 + 1]) / 4;
      const qz = Math.abs(pos[a * 3 + 2] + pos[c * 3 + 2]) / 2;
      if (tag === 'paint' && xm > 2.12 && qy < 0.43 && qz < 0.7) tag = 'under';
      if (tag === 'paint' && xm < DIM.xMin + 0.02 && qy < 0.56 && qz < 0.8) tag = 'under';
      add(tag, a, b, d, b, c, d);
    }
  }
  const last = all.length - 1;
  for (let k = 0; k < R; k++) {
    const k2 = (k + 1) % R, seg = segOf(k)[0];
    add(all[0][k].y < 0.56 ? 'under' : 'paint', rearC, k2, k);
    add(all[last][k].y < 0.43 ? 'under' : 'paint', frontC, last * R + k, last * R + k2);
  }

  // compute smooth normals over the whole shell, then share attributes
  const base = new THREE.BufferGeometry();
  base.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  base.setIndex(Object.values(groups).flat());
  base.computeVertexNormals();
  const out = {};
  for (const [tag, idx] of Object.entries(groups)) {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', base.getAttribute('position'));
    g.setAttribute('normal', base.getAttribute('normal'));
    g.setIndex(idx);
    g.computeBoundingSphere();
    out[tag] = g;
  }
  return out;
}

/* ---------- wheels ---------- */
function buildWheel(mats, rimMat) {
  const g = new THREE.Group();
  const spin = new THREE.Group(); g.add(spin);
  const R = DIM.wheelR, w = 0.29, rr = 0.245;
  // tyre profile (radius, axial)
  const prof = [];
  const steps = 14;
  for (let i = 0; i <= steps; i++) {
    const a = -Math.PI / 2 + (i / steps) * Math.PI;
    prof.push(new THREE.Vector2(R - 0.035 + Math.cos(a) * 0.035, Math.sin(a) * (w / 2 - 0.01) * 1.0));
  }
  prof.unshift(new THREE.Vector2(rr + 0.005, -w / 2 + 0.02));
  prof.push(new THREE.Vector2(rr + 0.005, w / 2 - 0.02));
  const tyreGeo = new THREE.LatheGeometry(prof, 56);
  tyreGeo.rotateX(Math.PI / 2);
  const tyre = new THREE.Mesh(tyreGeo, mats.tyre); tyre.castShadow = true;
  spin.add(tyre);

  // barrel
  const barrel = new THREE.Mesh(new THREE.CylinderGeometry(rr, rr, w - 0.05, 40, 1, true), mats.trimDark);
  barrel.rotation.x = Math.PI / 2; spin.add(barrel);
  // rim lip
  const lip = new THREE.Mesh(new THREE.TorusGeometry(rr, 0.012, 8, 48), rimMat);
  lip.position.z = w / 2 - 0.03; spin.add(lip);
  // spokes (10, slightly dished)
  const spokeGeo = new THREE.BoxGeometry(0.034, rr - 0.05, 0.028);
  spokeGeo.translate(0, (rr - 0.05) / 2 + 0.045, 0);
  for (let i = 0; i < 10; i++) {
    const s = new THREE.Mesh(spokeGeo, rimMat);
    s.rotation.z = (i / 10) * Math.PI * 2;
    s.rotation.x = -0.12;
    s.position.z = w / 2 - 0.06;
    spin.add(s);
  }
  const hub = new THREE.Mesh(new THREE.CylinderGeometry(0.06, 0.07, 0.06, 6), rimMat);
  hub.rotation.x = Math.PI / 2; hub.position.z = w / 2 - 0.05; spin.add(hub);
  const nut = new THREE.Mesh(new THREE.CylinderGeometry(0.035, 0.035, 0.03, 6), mats.chrome);
  nut.rotation.x = Math.PI / 2; nut.position.z = w / 2 - 0.02; spin.add(nut);

  // brakes (do not spin)
  const disc = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.2, 0.03, 40), mats.disc);
  disc.rotation.x = Math.PI / 2; disc.position.z = 0.0; g.add(disc);
  const caliper = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.08, 0.07), mats.caliper);
  caliper.position.set(-0.1, 0.14, 0.03); caliper.rotation.z = 0.6; g.add(caliper);
  g.userData.spin = spin;
  return g;
}

/* ---------- airfoil for the wing ---------- */
function airfoil(chord, thick) {
  const s = new THREE.Shape();
  const N = 24, top = [], bot = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N, x = (1 - Math.cos(t * Math.PI)) / 2;
    const yt = 5 * thick * (0.2969 * Math.sqrt(x) - 0.126 * x - 0.3516 * x * x + 0.2843 * x ** 3 - 0.1036 * x ** 4);
    const camber = 0.06 * Math.sin(x * Math.PI);
    top.push([x * chord, (camber + yt) * chord]); bot.push([x * chord, (camber - yt) * chord]);
  }
  s.moveTo(...top[0]);
  top.slice(1).forEach(p => s.lineTo(...p));
  bot.reverse().forEach(p => s.lineTo(...p));
  return s;
}

/* ---------- the car ---------- */
export function createCar() {
  const root = new THREE.Group();     // placed in world
  const chassis = new THREE.Group();  // body roll/pitch/vibration
  root.add(chassis);

  const mats = {
    paint: new THREE.MeshPhysicalMaterial({ color: 0x1b55e0, metalness: 0.5, roughness: 0.26, clearcoat: 1, clearcoatRoughness: 0.07, side: THREE.DoubleSide }),
    stripe: new THREE.MeshPhysicalMaterial({ color: 0xe8c15a, metalness: 0.6, roughness: 0.3, clearcoat: 1, clearcoatRoughness: 0.03, side: THREE.DoubleSide }),
    glass: new THREE.MeshPhysicalMaterial({ color: 0x020305, metalness: 0.1, roughness: 0.1, clearcoat: 1, clearcoatRoughness: 0.12, envMapIntensity: 0.6, side: THREE.DoubleSide }),
    under: new THREE.MeshStandardMaterial({ color: 0x08090b, roughness: 0.9, side: THREE.DoubleSide }),
    carbon: new THREE.MeshPhysicalMaterial({ color: 0x111215, metalness: 0.3, roughness: 0.35, clearcoat: 0.8 }),
    trimDark: new THREE.MeshStandardMaterial({ color: 0x15161a, metalness: 0.6, roughness: 0.5 }),
    tyre: new THREE.MeshStandardMaterial({ color: 0x0d0d0f, roughness: 0.82 }),
    rim: new THREE.MeshStandardMaterial({ color: 0x1a1b1f, metalness: 0.9, roughness: 0.28 }),
    chrome: new THREE.MeshStandardMaterial({ color: 0xdddddd, metalness: 1, roughness: 0.12 }),
    disc: new THREE.MeshStandardMaterial({ color: 0x6b6b70, metalness: 0.9, roughness: 0.42 }),
    caliper: new THREE.MeshStandardMaterial({ color: 0xd0202a, metalness: 0.3, roughness: 0.35 }),
    interior: new THREE.MeshStandardMaterial({ color: 0x121317, roughness: 0.8 }),
    alcantara: new THREE.MeshStandardMaterial({ color: 0x1d1e22, roughness: 0.95 }),
    accent: new THREE.MeshStandardMaterial({ color: 0xc81e2c, roughness: 0.6 }),
    housing: new THREE.MeshPhysicalMaterial({ color: 0x050608, metalness: 0.4, roughness: 0.12, clearcoat: 1, clearcoatRoughness: 0.1 }),
  };
  const glow = (hex) => new THREE.MeshBasicMaterial({ color: hex, toneMapped: false });

  /* body shell */
  const geos = buildBody();
  const shell = new THREE.Group(); chassis.add(shell);
  const meshOf = (tag, mat) => {
    if (!geos[tag]) return null;
    const m = new THREE.Mesh(geos[tag], mat); m.castShadow = true; m.receiveShadow = true; return m;
  };
  const bodyMesh = meshOf('paint', mats.paint); shell.add(bodyMesh);
  const stripeMesh = meshOf('stripe', mats.stripe); shell.add(stripeMesh);
  shell.add(meshOf('glass', mats.glass));
  shell.add(meshOf('under', mats.under));

  /* doors: same geometry grid, hinged at the A-pillar */
  const doors = [];
  for (const side of [1, -1]) {
    const key = side > 0 ? 'doorR' : 'doorL';
    const hx = DIM.door[1] - 0.02, hy = 0.93, hz = side * W(hx);
    const pivot = new THREE.Group();
    pivot.position.set(hx, hy, hz);
    pivot.rotation.order = 'YZX';
    const inner = new THREE.Group(); inner.position.set(-hx, -hy, -hz);
    pivot.add(inner);
    const p = meshOf(key, mats.paint); if (p) inner.add(p);
    const g = meshOf(key + 'Glass', mats.glass); if (g) inner.add(g);
    // mirror on the door
    const mx = 0.6, wz = W(mx), mz = side * (wz + 0.07);
    const stalk = new THREE.Mesh(new THREE.BoxGeometry(0.07, 0.11, 0.02), mats.carbon);
    stalk.position.set(mx + 0.02, BELT(mx) + 0.04, side * (wz - 0.02)); stalk.rotation.x = side * 0.9; inner.add(stalk);
    const mirror = new THREE.Mesh(new THREE.SphereGeometry(1, 24, 16), mats.paint);
    mirror.scale.set(0.11, 0.055, 0.085); mirror.position.set(mx, BELT(mx) + 0.09, mz); mirror.castShadow = true;
    inner.add(mirror);
    const mglass = new THREE.Mesh(new THREE.CircleGeometry(1, 24), mats.chrome);
    mglass.scale.set(0.045, 0.075, 1); mglass.rotation.y = -Math.PI / 2; mglass.position.set(mx - 0.085, BELT(mx) + 0.09, mz);
    inner.add(mglass);
    chassis.add(pivot);
    doors.push({ pivot, side });
  }

  /* interior (visible with doors open) */
  const interior = new THREE.Group(); chassis.add(interior);
  const floor = new THREE.Mesh(new THREE.BoxGeometry(1.9, 0.04, 1.6), mats.interior);
  floor.position.set(-0.05, 0.3, 0); interior.add(floor);
  for (const z of [-0.37, 0.37]) {
    const seat = new THREE.Group();
    const base = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.1, 0.46), mats.alcantara); base.position.y = 0.05;
    const back = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.62, 0.46), mats.alcantara);
    back.position.set(-0.25, 0.33, 0); back.rotation.z = 0.22;
    const bolsterL = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.14, 0.06), mats.accent); bolsterL.position.set(0, 0.1, 0.22);
    const bolsterR = bolsterL.clone(); bolsterR.position.z = -0.22;
    seat.add(base, back, bolsterL, bolsterR);
    seat.position.set(-0.35, 0.32, z); interior.add(seat);
  }
  const dash = new THREE.Mesh(new THREE.BoxGeometry(0.3, 0.16, 1.5), mats.interior);
  dash.position.set(0.55, 0.76, 0); interior.add(dash);
  const wheel = new THREE.Mesh(new THREE.TorusGeometry(0.17, 0.022, 10, 32), mats.alcantara);
  wheel.position.set(0.3, 0.82, -0.37); wheel.rotation.y = Math.PI / 2; wheel.rotation.x = 0; wheel.rotation.order = 'YXZ';
  wheel.rotation.x = -0.35; interior.add(wheel);
  const cage = new THREE.Mesh(new THREE.TorusGeometry(0.62, 0.025, 8, 32, Math.PI), mats.chrome);
  cage.position.set(-0.78, 0.4, 0); cage.rotation.y = Math.PI / 2; interior.add(cage);

  /* aero + trim */
  const splitter = new THREE.Mesh(new THREE.BoxGeometry(0.3, 0.02, 1.5), mats.carbon);
  splitter.position.set(2.3, 0.2, 0); splitter.castShadow = true; chassis.add(splitter);
  for (const s of [1, -1]) {
    const skirt = new THREE.Mesh(new THREE.BoxGeometry(1.75, 0.05, 0.06), mats.carbon);
    skirt.position.set(0.02, 0.24, s * 0.96); chassis.add(skirt);
  }
  // hood vents
  for (const s of [1, -1]) {
    const v = new THREE.Mesh(new THREE.BoxGeometry(0.34, 0.02, 0.2), mats.under);
    v.position.set(1.7, HOOD(1.7) + 0.0, s * 0.3); v.rotation.z = Math.atan2(HOOD(1.85) - HOOD(1.55), 0.3); chassis.add(v);
  }
  // diffuser
  const diff = new THREE.Mesh(new THREE.BoxGeometry(0.42, 0.03, 1.5), mats.carbon);
  diff.position.set(-2.12, 0.255, 0); diff.rotation.z = -0.18; chassis.add(diff);
  for (let i = -3; i <= 3; i++) {
    const fin = new THREE.Mesh(new THREE.BoxGeometry(0.4, 0.1, 0.012), mats.carbon);
    fin.position.set(-2.14, 0.24, i * 0.2); fin.rotation.z = -0.18; chassis.add(fin);
  }
  // engine louvres on the fastback
  for (let i = 0; i < 6; i++) {
    const x = -1.58 - i * 0.07;
    const l = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.012, 0.9), mats.carbon);
    const yy = Math.max(HOOD(x), ROOF(x)) + 0.005;
    l.position.set(x, yy, 0); l.rotation.z = Math.atan2(ROOF(x + 0.05) - ROOF(x - 0.05), 0.1);
    chassis.add(l);
  }

  // rear wing (swan neck)
  const wing = new THREE.Group(); chassis.add(wing);
  const foilGeo = new THREE.ExtrudeGeometry(airfoil(0.4, 0.12), { depth: 1.86, bevelEnabled: false, steps: 1 });
  foilGeo.translate(0, 0, -0.93);
  const foil = new THREE.Mesh(foilGeo, mats.carbon);
  foil.rotation.z = Math.PI + 0.1; // trailing edge up, facing forward
  foil.position.set(-1.92, 1.36, 0); foil.castShadow = true; wing.add(foil);
  for (const s of [1, -1]) {
    const plate = new THREE.Mesh(new THREE.BoxGeometry(0.44, 0.13, 0.012), mats.carbon);
    plate.position.set(-2.12, 1.345, s * 0.935); wing.add(plate);
    const neck = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.42, 0.018), mats.carbon);
    neck.position.set(-2.0, 1.17, s * 0.42); neck.rotation.z = -0.28; wing.add(neck);
  }
  const ducktail = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.035, 1.6), mats.carbon);
  ducktail.position.set(-2.22, 0.925, 0); ducktail.rotation.z = 0.2; ducktail.visible = false; chassis.add(ducktail);

  /* exhaust + flames */
  const exhausts = [];
  for (const z of [-0.13, 0.13]) {
    const tip = new THREE.Mesh(new THREE.CylinderGeometry(0.055, 0.05, 0.14, 24, 1, true), mats.chrome);
    tip.rotation.z = Math.PI / 2; tip.position.set(-2.32, 0.4, z); chassis.add(tip);
    const inner = new THREE.Mesh(new THREE.CircleGeometry(0.048, 24), mats.under);
    inner.rotation.y = -Math.PI / 2; inner.position.set(-2.3, 0.4, z); chassis.add(inner);
    const flame = new THREE.Group();
    const fl1 = new THREE.Mesh(new THREE.ConeGeometry(0.06, 0.55, 16, 1, true), new THREE.MeshBasicMaterial({ color: new THREE.Color(4, 1.4, 0.25), transparent: true, opacity: 0.85, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
    fl1.rotation.z = Math.PI / 2; fl1.position.x = -0.27;
    const fl2 = new THREE.Mesh(new THREE.ConeGeometry(0.035, 0.3, 16, 1, true), new THREE.MeshBasicMaterial({ color: new THREE.Color(0.6, 1.2, 4), transparent: true, opacity: 0.9, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false }));
    fl2.rotation.z = Math.PI / 2; fl2.position.x = -0.15;
    flame.add(fl1, fl2);
    flame.position.set(-2.38, 0.4, z); flame.visible = false; chassis.add(flame);
    exhausts.push(flame);
  }
  const flameLight = new THREE.PointLight(0xff7a2a, 0, 4, 2); flameLight.position.set(-2.7, 0.45, 0); chassis.add(flameLight);

  /* ---------- lights ---------- */
  // headlights: glossy pods with a DRL ring and four LED projectors
  const head = { drl: [], leds: [], ind: [] };
  const drlMat = glow(0xffffff), ledMat = glow(0xffffff), indMat = glow(0xffa21a);
  for (const s of [1, -1]) {
    const hx = 1.96, hz = s * 0.66, hy = BELT(hx) - 0.03;
    const pod = new THREE.Group();
    pod.position.set(hx, hy, hz);
    const slope = Math.atan2(BELT(hx + 0.1) - BELT(hx - 0.1), 0.2);
    pod.rotation.z = slope * 0.8;
    const housing = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 20), mats.housing);
    housing.scale.set(0.2, 0.072, 0.14); pod.add(housing);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.105, 0.011, 8, 40), drlMat);
    ring.rotation.y = Math.PI / 2; ring.scale.set(1, 0.62, 1); ring.position.x = 0.13; pod.add(ring);
    for (let i = 0; i < 4; i++) {
      const led = new THREE.Mesh(new THREE.SphereGeometry(0.019, 12, 8), ledMat);
      led.position.set(0.15, (i < 2 ? 1 : -1) * 0.022, (i % 2 ? 1 : -1) * 0.032); pod.add(led);
    }
    const ind = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.018, 0.12), indMat);
    ind.position.set(0.13, -0.065, s * 0.03); pod.add(ind);
    chassis.add(pod);
  }
  // light beams (real lights that hit the floor)
  const beams = [];
  for (const s of [1, -1]) {
    const L = new THREE.SpotLight(0xe8f0ff, 0, 30, 0.42, 0.55, 1.4);
    L.position.set(2.1, 0.8, s * 0.66);
    L.target.position.set(9, 0, s * 1.0);
    chassis.add(L, L.target); beams.push(L);
  }
  // volumetric cones
  const coneGeo = new THREE.ConeGeometry(1.4, 6, 32, 1, true);
  coneGeo.translate(0, -3, 0); coneGeo.rotateZ(Math.PI / 2 + 0.07);
  const coneMat = new THREE.ShaderMaterial({
    uniforms: { uI: { value: 0 } },
    vertexShader: `varying float vX; varying vec3 vN; varying vec3 vV;
      void main(){ vX = position.x; vec4 mv = modelViewMatrix*vec4(position,1.0); vN = normalize(normalMatrix*normal); vV = normalize(-mv.xyz); gl_Position = projectionMatrix*mv; }`,
    fragmentShader: `uniform float uI; varying float vX; varying vec3 vN; varying vec3 vV;
      void main(){ float f = clamp(1.0 - vX/6.0, 0.0, 1.0); float rim = pow(abs(dot(vN, vV)), 1.5);
      gl_FragColor = vec4(vec3(0.8,0.88,1.0)*uI*f*f*rim*0.22, 1.0); }`,
    transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide,
  });
  for (const s of [1, -1]) {
    const c = new THREE.Mesh(coneGeo, coneMat); c.position.set(2.1, 0.82, s * 0.66); c.rotation.y = -s * 0.04;
    chassis.add(c);
  }
  const cones = coneMat;

  // full-width tail light bar (instanced so we can animate each segment)
  const SEG = 34;
  const tailGeo = new THREE.BoxGeometry(0.03, 0.035, 1);
  const tail = new THREE.InstancedMesh(tailGeo, new THREE.MeshBasicMaterial({ toneMapped: false }), SEG);
  const tailSpan = 1.62, segW = tailSpan / SEG;
  const tm = new THREE.Matrix4();
  const tailX = DIM.xMin - 0.035, tailY = 0.835;
  for (let i = 0; i < SEG; i++) {
    const z = -tailSpan / 2 + segW * (i + 0.5);
    const t = Math.abs(z) / (tailSpan / 2);
    tm.makeScale(1, 1, segW * 0.82);
    tm.setPosition(tailX + 0.02 * t * t, tailY, z);
    tail.setMatrixAt(i, tm);
    tail.setColorAt(i, new THREE.Color(0.05, 0, 0));
  }
  chassis.add(tail);
  const tailHousing = new THREE.Mesh(new THREE.BoxGeometry(0.03, 0.06, tailSpan + 0.04), mats.housing);
  tailHousing.position.set(tailX + 0.012, tailY, 0); chassis.add(tailHousing);
  const tailGlow = new THREE.PointLight(0xff2020, 0, 3, 2); tailGlow.position.set(-2.9, 0.5, 0); chassis.add(tailGlow);
  // rear "APEX" lettering bar
  const badge = new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.06), new THREE.MeshBasicMaterial({ map: badgeTexture(), transparent: true }));
  badge.rotation.y = -Math.PI / 2; badge.position.set(DIM.xMin - 0.04, 0.73, 0); chassis.add(badge);

  /* wheels */
  const rimMat = mats.rim;
  const wheels = [];
  for (const [axle, front] of [[DIM.front, true], [DIM.rear, false]]) {
    for (const s of [1, -1]) {
      const w = buildWheel(mats, rimMat);
      const steer = new THREE.Group();
      steer.position.set(axle.x, DIM.wheelY, s * axle.track);
      if (s < 0) w.scale.z = -1;
      steer.add(w); root.add(steer);
      wheels.push({ steer, spin: w.userData.spin, front });
    }
  }

  /* courtesy lighting: cabin glow + logo puddle lamps when the doors open */
  const cabinLight = new THREE.PointLight(0xffd9a8, 0, 2.6, 1.6);
  cabinLight.position.set(-0.1, 1.0, 0); chassis.add(cabinLight);
  const puddleMat = new THREE.MeshBasicMaterial({ map: puddleTexture(), transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false });
  for (const s of [1, -1]) {
    const p = new THREE.Mesh(new THREE.PlaneGeometry(1.1, 1.1), puddleMat);
    p.rotation.x = -Math.PI / 2; p.rotation.z = s > 0 ? 0 : Math.PI;
    p.position.set(0.25, 0.006, s * 1.55); root.add(p);
  }

  /* ---------- API ---------- */
  const state = {
    doorTarget: 0, door: 0,
    lights: 0, lightLevel: 0, // 0 off, 1 low, 2 high
    drl: 0, drlTarget: 0,
    brake: 0, hazard: 0, hazardT: 0,
    sweep: null, // {t, dir}
    flame: 0,
    wheelAngle: 0,
  };
  const tailCol = new THREE.Color();

  const api = {
    root, chassis, mats, wing, ducktail, stripeMesh,
    setPaint(hex) { mats.paint.color.set(hex); if (!api.livery) stripeMesh.material = mats.paint; },
    livery: true,
    setLivery(on, hex) {
      api.livery = on; stripeMesh.material = on ? mats.stripe : mats.paint;
      if (hex) mats.stripe.color.set(hex);
    },
    setRim(hex) { rimMat.color.set(hex); },
    setWing(on) { wing.visible = on; ducktail.visible = !on; },
    setDoors(open) { state.doorTarget = open ? 1 : 0; },
    setLights(level) { state.lights = level; },
    setDRL(on) { state.drlTarget = on ? 1 : 0; },
    setBrake(v) { state.brake = v; },
    hazard(n = 2) { state.hazard = n; state.hazardT = 0; },
    sweep(dir = 1) { state.sweep = { t: 0, dir }; },
    flames(power = 1) { state.flame = Math.max(state.flame, power); },
    spinWheels(da) { state.wheelAngle += da; },
    steer(a) { wheels.forEach(w => { if (w.front) w.steer.rotation.y = a; }); },
    get doorAmount() { return state.door; },

    update(dt, t) {
      // doors: ease with a little overshoot
      const k = 1 - Math.exp(-dt * 4.2);
      state.door += (state.doorTarget - state.door) * k;
      const e = state.door;
      for (const d of doors) {
        d.pivot.rotation.z = -e * 1.05;       // up
        d.pivot.rotation.y = d.side * e * 0.28; // out
      }
      cabinLight.intensity = e * 2.2;
      puddleMat.opacity = Math.min(1, e * 1.3);

      // DRL & beams
      state.drl += (state.drlTarget - state.drl) * (1 - Math.exp(-dt * 6));
      const lvlT = state.lights;
      state.lightLevel += (lvlT - state.lightLevel) * (1 - Math.exp(-dt * 10));
      const lv = state.lightLevel;
      const drlI = Math.max(state.drl, Math.min(1, lv)) * 3.2;
      drlMat.color.setRGB(drlI, drlI, drlI * 1.08);
      const ledI = lv * 2.4 + 0.02;
      ledMat.color.setRGB(ledI * 0.95, ledI, ledI * 1.15);
      beams.forEach(b => { b.intensity = lv * 28; b.angle = lv > 1.2 ? 0.34 : 0.42; b.target.position.y = lv > 1.2 ? 0.6 : 0; });
      cones.uniforms.uI.value = Math.max(0, lv - 0.2);

      // hazards
      let blink = 0;
      if (state.hazard > 0) {
        state.hazardT += dt;
        blink = Math.floor(state.hazardT / 0.35) % 2 === 0 ? 1 : 0;
        if (state.hazardT > state.hazard * 0.7) state.hazard = 0;
      }
      indMat.color.setRGB(blink * 4, blink * 2.2, 0.0 + blink * 0.15);

      // tail bar
      let sweepT = -1, sweepDir = 1;
      if (state.sweep) {
        state.sweep.t += dt; sweepT = state.sweep.t / 0.75; sweepDir = state.sweep.dir;
        if (sweepT > 1.6) { state.sweep = null; sweepT = -1; }
      }
      const base = Math.max(state.drl, Math.min(1, lv)) * 1.0;
      for (let i = 0; i < SEG; i++) {
        const u = Math.abs((i + 0.5) / SEG - 0.5) * 2; // 0 centre → 1 edge
        let v = base * 2.4 + state.brake * 3.5;
        if (sweepT >= 0) {
          const front = sweepDir > 0 ? sweepT : 1 - sweepT;
          const sweepV = u < front ? 3.4 * (1 - Math.max(0, sweepT - 1) / 0.6) : 0;
          v = Math.max(v, sweepV);
        }
        const amber = blink && u > 0.82;
        if (amber) tailCol.setRGB(4, 1.9, 0.1);
        else tailCol.setRGB(Math.max(0.05, v), v * 0.04, v * 0.05);
        tail.setColorAt(i, tailCol);
      }
      tail.instanceColor.needsUpdate = true;
      tailGlow.intensity = state.brake * 1.5;

      // flames
      state.flame = Math.max(0, state.flame - dt * 9);
      const f = state.flame;
      exhausts.forEach((fl, i) => {
        fl.visible = f > 0.05;
        const flick = 0.7 + Math.random() * 0.6;
        fl.scale.set(f * flick, 0.7 + f * 0.5 * flick, 0.7 + f * 0.5 * flick);
        fl.children[0].material.opacity = Math.min(1, f) * 0.9;
      });
      flameLight.intensity = f * 5;

      // wheels (mirrored left wheels share the same sense: z-reflection commutes with z-rotation)
      wheels.forEach(w => { w.spin.rotation.z = -state.wheelAngle; });
    },
  };
  return api;
}

function puddleTexture() {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const g = c.getContext('2d');
  const gr = g.createRadialGradient(128, 128, 10, 128, 128, 120);
  gr.addColorStop(0, 'rgba(255,240,220,0.55)'); gr.addColorStop(0.55, 'rgba(255,230,200,0.22)'); gr.addColorStop(1, 'rgba(255,230,200,0)');
  g.fillStyle = gr; g.beginPath(); g.arc(128, 128, 120, 0, Math.PI * 2); g.fill();
  g.strokeStyle = 'rgba(255,255,255,0.8)'; g.lineWidth = 3; g.beginPath(); g.arc(128, 128, 78, 0, Math.PI * 2); g.stroke();
  g.fillStyle = 'rgba(255,255,255,0.95)'; g.font = '800 30px Inter, system-ui, sans-serif';
  g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText('APEX', 128, 122);
  g.font = '600 13px Inter, system-ui, sans-serif'; g.fillStyle = 'rgba(255,255,255,0.7)'; g.fillText('9 R', 128, 150);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

function badgeTexture() {
  const c = document.createElement('canvas'); c.width = 512; c.height = 64;
  const g = c.getContext('2d');
  g.fillStyle = '#e9ecf2'; g.font = '700 44px Inter, system-ui, sans-serif';
  g.textAlign = 'center'; g.textBaseline = 'middle';
  g.letterSpacing = '22px';
  g.fillText('A P E X', 256, 34);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 4;
  return t;
}
