// Procedural flat-six engine sound. No samples: everything is synthesized
// live in Web Audio from rpm + throttle, so it reacts instantly and never loops.

export class EngineAudio {
  /** Pass an OfflineAudioContext to render to a file instead of the speakers. */
  constructor(ctx = null) {
    this.ctx = ctx;
    this.offline = !!ctx;
    this.enabled = false;
    this.volume = 0.85;
  }

  async enable() {
    // iOS: play through the silent switch like a game/music app would
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch {}
    if (!this.ctx) this._build();
    else if (!this.master) this._build(this.ctx);
    if (!this.offline && this.ctx.state !== 'running') await this.ctx.resume();
    this.enabled = true;
    this.master.gain.setTargetAtTime(this.volume, this.ctx.currentTime, 0.05);
  }

  disable() {
    if (!this.ctx) return;
    this.enabled = false;
    this.master.gain.setTargetAtTime(0, this.ctx.currentTime, 0.05);
  }

  _build(existing) {
    const ctx = (this.ctx = existing || new (window.AudioContext || window.webkitAudioContext)());
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -4; comp.knee.value = 6; comp.ratio.value = 4; // safety limiter only, keep the dynamics
    comp.attack.value = 0.004; comp.release.value = 0.2;
    this.master = ctx.createGain();
    this.master.gain.value = 0;
    this.master.connect(comp).connect(ctx.destination);

    // Small convolution "garage" reverb for space
    const verb = ctx.createConvolver();
    verb.buffer = this._impulse(1.6, 2.6);
    this.verbSend = ctx.createGain(); this.verbSend.gain.value = 0.18;
    this.verbSend.connect(verb).connect(this.master);

    // ---- engine core: periodic wave at half crank freq (one 4-stroke cycle).
    // Harmonic `cyl` = firing frequency; half-orders add the lumpy "lope".
    const wave = this._wave();
    this.oscA = ctx.createOscillator(); this.oscA.setPeriodicWave(wave);
    this.oscB = ctx.createOscillator(); this.oscB.setPeriodicWave(wave);
    this.oscB.detune.value = 9;
    this.oscSub = ctx.createOscillator(); this.oscSub.type = 'triangle';

    const gA = ctx.createGain(); gA.gain.value = 0.55;
    const gB = ctx.createGain(); gB.gain.value = 0.35;
    this.subGain = ctx.createGain(); this.subGain.gain.value = 0.5;

    this.shaper = ctx.createWaveShaper();
    this.shaper.curve = this._curve(2.6); this.shaper.oversample = '2x';
    this.preGain = ctx.createGain(); this.preGain.gain.value = 1.2;

    this.tone = ctx.createBiquadFilter(); this.tone.type = 'lowpass'; this.tone.Q.value = 1.4;
    this.body = ctx.createBiquadFilter(); this.body.type = 'peaking';
    this.body.frequency.value = 160; this.body.gain.value = 6; this.body.Q.value = 0.9;

    this.engineGain = ctx.createGain(); this.engineGain.gain.value = 0;

    this.oscA.connect(gA).connect(this.preGain);
    this.oscB.connect(gB).connect(this.preGain);
    this.oscSub.connect(this.subGain).connect(this.preGain);
    this.preGain.connect(this.shaper).connect(this.tone).connect(this.body).connect(this.engineGain);
    this.engineGain.connect(this.master);
    this.engineGain.connect(this.verbSend);

    // ---- intake / mechanical noise (throttle dependent)
    this.noiseBuf = this._noise(2);
    const n = ctx.createBufferSource(); n.buffer = this.noiseBuf; n.loop = true;
    this.intake = ctx.createBiquadFilter(); this.intake.type = 'bandpass'; this.intake.Q.value = 1.8;
    this.intakeGain = ctx.createGain(); this.intakeGain.gain.value = 0;
    n.connect(this.intake).connect(this.intakeGain).connect(this.master);

    // ---- high "scream" layer for top end
    this.scream = ctx.createOscillator(); this.scream.type = 'sawtooth';
    const sf = ctx.createBiquadFilter(); sf.type = 'bandpass'; sf.Q.value = 3;
    this.screamFilter = sf;
    this.screamGain = ctx.createGain(); this.screamGain.gain.value = 0;
    this.scream.connect(sf).connect(this.screamGain).connect(this.master);
    this.screamGain.connect(this.verbSend);

    // ---- electric motor (Volt): two whine partials + inverter buzz, no combustion
    this.evGain = ctx.createGain(); this.evGain.gain.value = 0;
    this.evA = ctx.createOscillator(); this.evA.type = 'sine';
    this.evB = ctx.createOscillator(); this.evB.type = 'sine';
    this.evC = ctx.createOscillator(); this.evC.type = 'sawtooth';
    const evCf = ctx.createBiquadFilter(); evCf.type = 'bandpass'; evCf.Q.value = 6; this.evCf = evCf;
    const gEa = ctx.createGain(); gEa.gain.value = 0.6;
    const gEb = ctx.createGain(); gEb.gain.value = 0.25;
    const gEc = ctx.createGain(); gEc.gain.value = 0.08;
    this.evA.connect(gEa).connect(this.evGain);
    this.evB.connect(gEb).connect(this.evGain);
    this.evC.connect(evCf).connect(gEc).connect(this.evGain);
    this.evGain.connect(this.master); this.evGain.connect(this.verbSend);

    const t = ctx.currentTime;
    [this.oscA, this.oscB, this.oscSub, this.scream, this.evA, this.evB, this.evC].forEach(o => { o.frequency.value = 10; o.start(t); });
    n.start(t);
  }

  /** Engine character from cars.json: { type: 'ice'|'ev', cyl, lope, sub, scream, limit } */
  setCharacter(engine) {
    this.char = engine;
    if (this.ctx && this.oscA) {
      const w = this._wave();
      this.oscA.setPeriodicWave(w); this.oscB.setPeriodicWave(w);
    }
  }

  _wave() {
    const c = this.char || { cyl: 6, lope: 0.28 };
    const cyl = c.cyl || 6, half = Math.max(1, cyl / 2), lope = c.lope ?? 0.28;
    const N = Math.max(48, cyl * 4 + 1), re = new Float32Array(N), im = new Float32Array(N);
    const amp = (k) => {
      let a = 0.05 / k;
      if (k % cyl === 0) a += 1.0 / (k / cyl);          // firing pulses
      if (k % half === 0) a += lope / Math.sqrt(k);      // half-order lope
      if (k % 2 === 0) a += 0.12 / Math.sqrt(k);
      return a;
    };
    for (let k = 1; k < N; k++) { im[k] = amp(k) * (k % 4 === 1 ? -1 : 1); re[k] = amp(k) * 0.3; }
    return this.ctx.createPeriodicWave(re, im);
  }

  _curve(k) {
    const n = 2048, c = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const x = (i / (n - 1)) * 2 - 1;
      c[i] = Math.tanh(k * x) * (x > 0 ? 1 : 0.86); // asymmetry = even harmonics
    }
    return c;
  }
  _noise(sec) {
    const b = this.ctx.createBuffer(1, this.ctx.sampleRate * sec, this.ctx.sampleRate);
    const d = b.getChannelData(0);
    let last = 0;
    for (let i = 0; i < d.length; i++) { const w = Math.random() * 2 - 1; last = last * 0.6 + w * 0.4; d[i] = last; }
    return b;
  }
  _impulse(sec, decay) {
    const ctx = this.ctx, len = ctx.sampleRate * sec;
    const b = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch++) {
      const d = b.getChannelData(ch);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
    }
    return b;
  }

  /** Called every frame. rpm: crank rpm, load: 0..1 throttle, on: engine running */
  update(rpm, load, on, at) {
    if (!this.ctx || !this.enabled) return;
    const t = at ?? this.ctx.currentTime, k = 0.025;
    const C = this.char || { type: 'ice', cyl: 6, sub: 0.55, scream: 1, limit: 9000 };
    const live = on ? 1 : 0;
    if (C.type === 'ev') {
      // motor whine rises with motor speed; louder under load
      const m = Math.max(rpm, 1) / 60, r = Math.min(1, rpm / (C.limit || 16000));
      this.evA.frequency.setTargetAtTime(40 + m * 2, t, k);
      this.evB.frequency.setTargetAtTime(60 + m * 3.03, t, k);
      this.evC.frequency.setTargetAtTime(80 + m * 9, t, k);
      this.evCf.frequency.setTargetAtTime(600 + m * 9, t, k);
      this.evGain.gain.setTargetAtTime(live * (0.025 + 0.2 * Math.pow(r, 0.8) + 0.16 * load * (0.3 + 0.7 * r)), t, 0.04);
      this.engineGain.gain.setTargetAtTime(0, t, 0.03);
      this.intakeGain.gain.setTargetAtTime(0, t, k);
      this.screamGain.gain.setTargetAtTime(0, t, k);
      return;
    }
    this.evGain.gain.setTargetAtTime(0, t, 0.03);
    const crank = Math.max(rpm, 1) / 60;
    const cycle = crank / 2;
    this.oscA.frequency.setTargetAtTime(cycle, t, k);
    this.oscB.frequency.setTargetAtTime(cycle, t, k);
    this.oscSub.frequency.setTargetAtTime(crank * 1.5, t, k);
    const fire = (C.cyl || 6) / 2; // firing events per crank revolution
    this.scream.frequency.setTargetAtTime(crank * fire, t, k);

    const r = Math.min(1, rpm / (C.limit || 9000));
    this.tone.frequency.setTargetAtTime(260 + r * 2600 + load * 1700, t, k);
    this.preGain.gain.setTargetAtTime(0.9 + load * 1.6, t, k);
    this.subGain.gain.setTargetAtTime((C.sub ?? 0.55) * (1 - r) + 0.1, t, k);

    // the harder you rev, the louder it gets: ~20 dB from idle to full-throttle redline
    const vol = live * (0.055 + 0.32 * Math.pow(r, 1.3) + 0.3 * load * (0.35 + 0.65 * r)) * Math.min(1, rpm / 500);
    this.engineGain.gain.setTargetAtTime(vol, t, 0.03);

    this.intake.frequency.setTargetAtTime(500 + crank * 9, t, k);
    this.intakeGain.gain.setTargetAtTime(live * load * (0.02 + 0.3 * r * r), t, k);

    this.screamFilter.frequency.setTargetAtTime(crank * fire * 2, t, k);
    const s = Math.max(0, (r - 0.55) / 0.45);
    this.screamGain.gain.setTargetAtTime(live * s * s * (0.05 + 0.09 * load) * (C.scream ?? 1), t, k);
  }

  /** Exhaust pop / crackle */
  pop(strength = 1, at) {
    if (!this.ctx || !this.enabled) return;
    const ctx = this.ctx, t = (at ?? ctx.currentTime) + Math.random() * 0.01;
    const src = ctx.createBufferSource(); src.buffer = this.noiseBuf;
    src.playbackRate.value = 0.6 + Math.random() * 0.6;
    const f = ctx.createBiquadFilter(); f.type = 'bandpass';
    f.frequency.value = 500 + Math.random() * 1600; f.Q.value = 0.8;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(0.7 * strength, t + 0.003);
    g.gain.exponentialRampToValueAtTime(0.001, t + 0.05 + Math.random() * 0.06);
    // low thump
    const o = ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(140, t); o.frequency.exponentialRampToValueAtTime(40, t + 0.08);
    const og = ctx.createGain();
    og.gain.setValueAtTime(0.7 * strength, t); og.gain.exponentialRampToValueAtTime(0.001, t + 0.1);
    src.connect(f).connect(g).connect(this.master); g.connect(this.verbSend);
    o.connect(og).connect(this.master);
    src.start(t, Math.random()); src.stop(t + 0.2); o.start(t); o.stop(t + 0.12);
  }

  /** Starter motor whine + chug, `dur` seconds */
  starter(dur = 0.9, at) {
    if (!this.ctx || !this.enabled) return;
    const ctx = this.ctx, t = at ?? ctx.currentTime;
    const o = ctx.createOscillator(); o.type = 'sawtooth';
    o.frequency.setValueAtTime(90, t); o.frequency.linearRampToValueAtTime(150, t + dur);
    const lfo = ctx.createOscillator(); lfo.frequency.setValueAtTime(7, t); lfo.frequency.linearRampToValueAtTime(13, t + dur);
    const lg = ctx.createGain(); lg.gain.value = 0.35;
    const g = ctx.createGain(); g.gain.value = 0;
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.32, t + 0.05);
    g.gain.setValueAtTime(0.32, t + dur - 0.06); g.gain.linearRampToValueAtTime(0, t + dur);
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 900;
    lfo.connect(lg).connect(g.gain);
    o.connect(f).connect(g).connect(this.master);
    o.start(t); lfo.start(t); o.stop(t + dur + 0.05); lfo.stop(t + dur + 0.05);
  }

  /** Key fob chirps */
  chirp(kind) {
    if (!this.ctx || !this.enabled) return;
    const ctx = this.ctx, t0 = ctx.currentTime;
    const beeps = kind === 'lock' ? [[0, 1900]] : kind === 'unlock' ? [[0, 1700], [0.14, 2100]] : [[0, 1200]];
    for (const [dt, fq] of beeps) {
      const t = t0 + dt;
      const o = ctx.createOscillator(); o.type = 'square'; o.frequency.value = fq;
      const g = ctx.createGain();
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.06, t + 0.005);
      g.gain.setValueAtTime(0.06, t + 0.08); g.gain.linearRampToValueAtTime(0, t + 0.1);
      o.connect(g).connect(this.master); g.connect(this.verbSend);
      o.start(t); o.stop(t + 0.12);
    }
  }

  /** Door thunk / lock clunk */
  thud(level = 1, pitch = 1) {
    if (!this.ctx || !this.enabled) return;
    const ctx = this.ctx, t = ctx.currentTime;
    const o = ctx.createOscillator(); o.type = 'sine';
    o.frequency.setValueAtTime(110 * pitch, t); o.frequency.exponentialRampToValueAtTime(45 * pitch, t + 0.12);
    const g = ctx.createGain(); g.gain.setValueAtTime(0.5 * level, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.18);
    const s = ctx.createBufferSource(); s.buffer = this.noiseBuf;
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 1200 * pitch;
    const sg = ctx.createGain(); sg.gain.setValueAtTime(0.25 * level, t); sg.gain.exponentialRampToValueAtTime(0.001, t + 0.06);
    o.connect(g).connect(this.master);
    s.connect(f).connect(sg).connect(this.master); sg.connect(this.verbSend);
    o.start(t); o.stop(t + 0.2); s.start(t, Math.random()); s.stop(t + 0.08);
  }

  /** Light switch relay click */
  click() { this.thud(0.25, 4); }

  /** Dual-tone horn */
  horn(on) {
    if (!this.ctx || !this.enabled) return;
    const ctx = this.ctx, t = ctx.currentTime;
    if (on && !this._horn) {
      const g = ctx.createGain(); g.gain.value = 0;
      g.gain.linearRampToValueAtTime(0.16, t + 0.03);
      const f = ctx.createBiquadFilter(); f.type = 'bandpass'; f.frequency.value = 1100; f.Q.value = 0.7;
      const os = [415, 495].map(fq => { const o = ctx.createOscillator(); o.type = 'square'; o.frequency.value = fq; o.connect(f); o.start(t); return o; });
      f.connect(g).connect(this.master); g.connect(this.verbSend);
      this._horn = { g, os };
    } else if (!on && this._horn) {
      const { g, os } = this._horn; this._horn = null;
      g.gain.setTargetAtTime(0, t, 0.02);
      os.forEach(o => o.stop(t + 0.15));
    }
  }
}
