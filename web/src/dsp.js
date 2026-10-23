'use strict';
/* Orbitakt's sound engine: a port of OrbitDSP.swift.
 *
 * The kit is synthesized in the spirit of a Machinedrum played through a dub desk. Every sound
 * is one "modal" voice (up to three decaying sine partials with a pitch sweep, plus filtered
 * noise) with a different recipe per drum:
 *   NAV kick     a round sine dropping onto the root, a soft click, almost nothing to the echo
 *   LEO rimshot  a short tuned knock and a band of noise, mostly *into* the echo
 *   SWARM hat    three metallic partials over high-passed noise, tiny and bright
 *   BELT hat     a longer, ringing hat into a gated reverb (a dense room that slams shut about
 *                150 ms after each hit); its metal is tuned by where the satellite sits
 *   zenith ping  a glass bar, almost all echo
 *   CREW gong    slow-struck inharmonic partials with long tails
 *
 * The dub delay lives here too: a stereo ping-pong on a dotted eighth, high- and low-passed and
 * gently saturated in the loop, with a little tape wow. `dub` sets its feedback; `throwAmt`
 * opens the send and pushes the feedback toward a spiral, the way a dub engineer rides it.
 *
 * The sequencer is a radar sweep: a beam goes round the sky once per one or two bars, starting
 * at north, and each satellite in a track's cone hits as the beam passes its bearing (pulled
 * toward a 16-slot grid by `quantize`). Timing is checked every 32 samples.
 *
 * Two outputs: dry (with the echoes in it), and a reverb send that the page feeds through a
 * plate reverb (a convolver).
 *
 * No browser APIs in this file: it runs in an AudioWorklet and in Node (for the tests).
 */

const OD = {
  TRACKS: 4,
  MAX_EVENTS: 32,
  PING_SLOTS: 4,
  GRID_SLOTS: 16,
  VOICES: 24,
  TABLE: 4096,
  MAX_FRAMES: 8192,
  COMB_TUNE: [1116, 1188, 1277, 1356],
  AP_TUNE: [556, 441],
};

// Voice-state slots (each is a block of VOICES values)
const VS = {};
['on', 'age', 'atk', 'amp', 'gl', 'gr', 'send',
 'ph1', 'ph2', 'ph3', 'inc1', 'inc2', 'inc3', 'g1', 'g2', 'g3', 'm1', 'm2', 'm3',
 'penv', 'pmul', 'pdepth',
 'na', 'nmul', 'hp', 'fa1', 'fa2', 'fa3', 'fk', 'ic1', 'ic2',
 'gsend'].forEach((k, i) => { VS[k] = i; });
const VS_COUNT = Object.keys(VS).length;

class OrbitDSP {
  constructor(sampleRate) {
    const sr = sampleRate;
    this.sr = sr;
    this.rng = 0x2545F491 | 0;

    // Control surface (written from the main thread through setParam / setList)
    const T = OD.TRACKS, E = OD.MAX_EVENTS;
    this.g = {
      master: 0, run: 0, bpm: 84, swing: 0, division: 2, quantize: 0.5, dub: 0.55,
      throwAmt: 0, reverbSend: 0.6, dust: 0,
    };
    this.mute = new Float64Array(T);
    this.level = new Float64Array(T).fill(1);
    this.bright = new Float64Array(T).fill(0.5);
    // Pending satellite lists (adopted when the sweep passes north)
    this.ePhase = new Float64Array(T * E);
    this.pVel = new Float64Array(T * E).fill(0.7);
    this.pPan = new Float64Array(T * E);
    this.pFreq = new Float64Array(T * E).fill(110);
    this.eCount = new Int32Array(T);
    this.pGen = new Int32Array(T);
    // Triggers from the main thread
    this.pingQueue = [];
    this.gongQueue = [];

    // Sine table
    this.sine = new Float32Array(OD.TABLE + 1);
    for (let i = 0; i <= OD.TABLE; i++) this.sine[i] = Math.sin(2 * Math.PI * i / OD.TABLE);

    // Sweep state: when each event fires (0..1) after quantizing, and its voice settings
    this.phase = new Float64Array(T * E).fill(2);
    this.vel = new Float64Array(T * E);
    this.pan = new Float64Array(T * E);
    this.freq = new Float64Array(T * E).fill(110);
    this.count = new Int32Array(T);
    this.gen = new Int32Array(T).fill(-1);
    this.running = false;
    this.sweep = 0;
    this.beats = 0;
    this.bpm = 84;

    // Drum voices
    this.vs = new Float64Array(VS_COUNT * OD.VOICES);
    this.voiceRR = 0;

    // Gated reverb (BELT hats): four combs and two allpasses per side, then a gate
    const scale = sr / 44100;
    this.combCap = Math.floor((1356 + 40) * scale) + 4;
    this.apCap = Math.floor((556 + 40) * scale) + 4;
    this.combBuf = new Float32Array(8 * this.combCap);
    this.combLP = new Float64Array(8);
    this.combLen = new Int32Array(8).fill(1);
    this.combIdx = new Int32Array(8);
    for (let c = 0; c < 8; c++) {
      const spread = c >= 4 ? 23 : 0;
      this.combLen[c] = Math.max(1, Math.min(this.combCap, Math.floor((OD.COMB_TUNE[c % 4] + spread) * scale)));
    }
    this.apBuf = new Float32Array(4 * this.apCap);
    this.apLen = new Int32Array(4).fill(1);
    this.apIdx = new Int32Array(4);
    for (let a = 0; a < 4; a++) {
      const spread = a >= 2 ? 23 : 0;
      this.apLen[a] = Math.max(1, Math.min(this.apCap, Math.floor((OD.AP_TUNE[a % 2] + spread) * scale)));
    }
    this.gateIn = new Float32Array(OD.MAX_FRAMES);
    this.gateEnv = 0;
    this.gateHold = 0;          // samples left with the gate open
    this.pendingHold = 0;
    this.gateOpenAt = -1;       // sample offset in this block where a hit opens it
    this.chunkOffset = 0;

    // Buses
    this.sendL = new Float32Array(OD.MAX_FRAMES);   // into the echo
    this.sendR = new Float32Array(OD.MAX_FRAMES);
    this.verbL = new Float32Array(OD.MAX_FRAMES);   // into the plate
    this.verbR = new Float32Array(OD.MAX_FRAMES);
    this.masterG = 0;

    // Dub delay
    this.dlCap = Math.floor(2.6 * sr) + 8;
    this.dlL = new Float32Array(this.dlCap);
    this.dlR = new Float32Array(this.dlCap);
    this.dlW = 0;
    this.dlTime = 0.5 * sr;    // samples, smoothed (tape-like glide on tempo changes)
    this.wowPh = 0;
    this.fb = 0.55;
    this.inGain = 0.55;
    this.hpL = 0; this.hpR = 0; this.lpL = 0; this.lpR = 0;
    this.reverbSend = 0.6;

    // Dust
    this.dust = 0;
    this.hissL = 0; this.hissR = 0;
    this.crackle = 0;
  }

  // ---------- Control ----------

  setParam(k, v) { if (k in this.g) this.g[k] = v; }

  setMute(t, v) { this.mute[t] = v ? 1 : 0; }

  setBright(t, v) { this.bright[t] = v; }

  /** A track's new satellite list: arrays of phase (bearing/360), vel, pan, freq. */
  setList(t, list) {
    const E = OD.MAX_EVENTS;
    const n = Math.max(0, Math.min(E, list.count | 0));
    for (let e = 0; e < n; e++) {
      const i = t * E + e;
      this.ePhase[i] = list.phase[e]; this.pVel[i] = list.vel[e];
      this.pPan[i] = list.pan[e]; this.pFreq[i] = list.freq[e];
    }
    this.eCount[t] = n;
    this.pGen[t] += 1;
  }

  ping(freq, vel, pan) { if (this.pingQueue.length < 16) this.pingQueue.push([freq, vel, pan]); }

  gong(freq, vel, pan) { if (this.gongQueue.length < 4) this.gongQueue.push([freq, vel, pan]); }

  // ---------- Helpers ----------

  sn(ph) {
    const x = ph * OD.TABLE;
    let i = Math.floor(x);
    if (i < 0) i = 0; else if (i > OD.TABLE - 1) i = OD.TABLE - 1;
    const f = x - i;
    const s = this.sine;
    return s[i] + (s[i + 1] - s[i]) * f;
  }

  white() {
    let r = this.rng;
    r ^= r << 13; r ^= r >>> 17; r ^= r << 5;
    this.rng = r;
    return (r >>> 8) / 8388608 - 1;
  }

  rand01() { return 0.5 * (this.white() + 1); }

  // ---------- Drum note-on ----------

  recipe(kind, f, vel, bright) {
    const r = {
      r1: 1, r2: 0, r3: 0, a1: 1, a2: 0, a3: 0, t1: 0.3, t2: 0.1, t3: 0.1,
      pdepth: 0, ptau: 0.05, na: 0, ntau: 0.05, nfc: 2000, nq: 1, highpass: false,
      atk: 0.001, gain: 0.5, send: 0.3, gsend: 0,
    };
    switch (kind) {
      case 'kick':
        // Round and short-attacked, like a Machinedrum EFM kick with the decay up
        r.r2 = 2; r.a2 = 0.05; r.t1 = 0.13 + 0.09 * vel; r.t2 = 0.04;
        r.pdepth = 3.0; r.ptau = 0.018;
        r.na = 0.10; r.ntau = 0.003; r.nfc = 3200; r.nq = 0.8;
        r.atk = 0.002; r.gain = 0.75; r.send = 0.03;
        break;
      case 'rim':
        // A tuned rimshot: short knock, a bandpassed tick, mostly thrown into the echo
        r.r2 = 1.48; r.a1 = 0.65; r.a2 = 0.3;
        r.t1 = 0.028; r.t2 = 0.016;
        r.pdepth = 0.04; r.ptau = 0.008;
        r.na = 0.45; r.ntau = 0.012; r.nfc = f * 1.15; r.nq = 2.2;
        r.atk = 0.0008; r.gain = 0.6; r.send = 0.9;
        break;
      case 'hat':
        // Metallic partials over high-passed noise; brighter for a busier Starlink sky
        r.r2 = 1.342; r.r3 = 1.791;
        r.a1 = 0.22; r.a2 = 0.18; r.a3 = 0.14;
        r.t1 = 0.022 + 0.02 * vel; r.t2 = 0.018; r.t3 = 0.014;
        r.na = 0.75; r.ntau = 0.014 + 0.03 * vel; r.nfc = 6500 + 2500 * bright; r.nq = 0.7;
        r.highpass = true;
        r.atk = 0.0012; r.gain = 0.3; r.send = 0.35;
        break;
      case 'gatedHat':
        // A longer, ringing hat (metal tuned by f) that drives the gated reverb
        r.r1 = 1; r.r2 = 1.342; r.r3 = 1.791;
        r.a1 = 0.26; r.a2 = 0.22; r.a3 = 0.16;
        r.t1 = 0.06 + 0.05 * vel; r.t2 = 0.05; r.t3 = 0.04;
        r.na = 0.8; r.ntau = 0.05 + 0.05 * vel; r.nfc = 6000 + 2000 * bright; r.nq = 0.7;
        r.highpass = true;
        r.atk = 0.001; r.gain = 0.26; r.send = 0.15; r.gsend = 1;
        break;
      case 'ping':
        r.r2 = 2.76; r.r3 = 5.40; r.a2 = 0.3; r.a3 = 0.1;
        r.t1 = 1.2; r.t2 = 0.4; r.t3 = 0.1;
        r.atk = 0.0015; r.gain = 0.16; r.send = 1.0;
        break;
      case 'gong':
        r.r2 = 1.47; r.r3 = 2.09; r.a2 = 0.55; r.a3 = 0.35;
        r.t1 = 4.0; r.t2 = 2.6; r.t3 = 1.6;
        r.pdepth = 0.015; r.ptau = 1.2;
        r.na = 0.04; r.ntau = 0.2; r.nfc = f * 4; r.nq = 1.5;
        r.atk = 0.06; r.gain = 0.22; r.send = 0.85;
        break;
    }
    return r;
  }

  trigger(kind, f, vel, pn, bright) {
    const V = OD.VOICES, vs = this.vs, sr = this.sr;
    // A free voice, else the oldest
    let v = -1;
    for (let i = 0; i < V; i++) {
      const k = (this.voiceRR + i) % V;
      if (vs[VS.on * V + k] < 0.5) { v = k; break; }
    }
    if (v < 0) {
      let oldest = -1;
      for (let i = 0; i < V; i++) if (vs[VS.age * V + i] > oldest) { oldest = vs[VS.age * V + i]; v = i; }
    }
    this.voiceRR = (v + 1) % V;
    f = Math.max(20, f);
    const r = this.recipe(kind, f, vel, bright);
    const set = (k, x) => { vs[VS[k] * V + v] = x; };
    const dec = tau => Math.exp(-1 / (Math.max(0.001, tau) * sr));
    const ang = (Math.max(-1, Math.min(1, pn)) + 1) * Math.PI / 4;
    set('on', 1); set('age', 0); set('atk', Math.max(1, r.atk * sr));
    set('amp', r.gain * Math.max(0, Math.min(1.2, vel)));
    set('gl', Math.cos(ang)); set('gr', Math.sin(ang)); set('send', r.send);
    const i1 = f * r.r1 / sr, i2 = f * r.r2 / sr, i3 = f * r.r3 / sr;
    set('inc1', i1); set('inc2', i2); set('inc3', i3);
    // Partials above ~0.45*sr (allowing for the pitch sweep) are left out
    const top = 0.45 / (1 + r.pdepth);
    set('g1', i1 < top ? r.a1 : 0); set('g2', i2 < top ? r.a2 : 0); set('g3', i3 < top ? r.a3 : 0);
    set('m1', dec(r.t1)); set('m2', dec(r.t2)); set('m3', dec(r.t3));
    set('ph1', 0); set('ph2', 0.25); set('ph3', 0.5);
    set('penv', 1); set('pmul', dec(r.ptau)); set('pdepth', r.pdepth);
    set('na', r.na); set('nmul', dec(r.ntau)); set('hp', r.highpass ? 1 : 0);
    const k = 1 / Math.max(0.5, r.nq);
    const gg = Math.tan(Math.PI * Math.min(Math.max(r.nfc, 40), sr * 0.45) / sr);
    const a1 = 1 / (1 + gg * (gg + k));
    set('fa1', a1); set('fa2', gg * a1); set('fa3', gg * gg * a1); set('fk', k);
    set('ic1', 0); set('ic2', 0);
    set('gsend', r.gsend);
    if (r.gsend > 0) {
      // Open the gate at this hit: ~150 ms, a touch longer for a louder hit
      this.gateOpenAt = this.chunkOffset;
      this.pendingHold = Math.floor((0.13 + 0.05 * Math.min(1, vel)) * sr);
    }
  }

  // ---------- Sweep ----------

  /** Take a track's new satellite list (called as the beam passes north). Each event's firing
   *  phase is its bearing, pulled toward the nearest of 16 grid slots by `quantize`; with swing,
   *  the odd slots sit a little late. */
  adopt(t) {
    const E = OD.MAX_EVENTS, G = OD.GRID_SLOTS;
    const q = Math.max(0, Math.min(1, this.g.quantize));
    const sw = Math.max(0, Math.min(0.4, this.g.swing));
    const n = Math.max(0, Math.min(E, this.eCount[t]));
    for (let e = 0; e < n; e++) {
      const i = t * E + e;
      const a = Math.max(0, Math.min(1, this.ePhase[i]));
      const slot = Math.round(a * G);          // (Swift's .rounded() is half away from zero; a >= 0)
      const grid = (slot + (slot % 2 === 1 ? sw : 0)) / G;
      let f = a + q * (grid - a);
      if (f >= 1) f -= 1;
      this.phase[i] = Math.max(0, f);
      this.vel[i] = this.pVel[i]; this.pan[i] = this.pPan[i]; this.freq[i] = this.pFreq[i];
    }
    this.count[t] = n;
    this.gen[t] = this.pGen[t];
  }

  /** Fire every event whose phase falls in [a, b). */
  fire(a, b) {
    const E = OD.MAX_EVENTS;
    for (let t = 0; t < OD.TRACKS; t++) {
      if (this.mute[t] >= 0.5) continue;
      const kind = t === 0 ? 'kick' : t === 1 ? 'rim' : t === 2 ? 'hat' : 'gatedHat';
      for (let e = 0; e < this.count[t]; e++) {
        const i = t * E + e;
        const ph = this.phase[i];
        if (!(ph >= a && ph < b)) continue;
        this.trigger(kind, this.freq[i], this.vel[i] * this.level[t], this.pan[i], this.bright[t]);
      }
    }
  }

  /** Pings and the gong are triggered by the main thread at any moment. */
  events() {
    while (this.pingQueue.length) {
      const [f, v, p] = this.pingQueue.shift();
      this.trigger('ping', f, v, p, 0.5);
    }
    while (this.gongQueue.length) {
      const [f, v, p] = this.gongQueue.shift();
      this.trigger('gong', f, v, p, 0.5);
    }
  }

  // ---------- Render: voices ----------

  renderVoices(L, R, o, m) {
    const V = OD.VOICES, vs = this.vs, sendL = this.sendL, sendR = this.sendR, gateIn = this.gateIn;
    for (let v = 0; v < V; v++) {
      if (vs[VS.on * V + v] <= 0.5) continue;
      const at = k => VS[k] * V + v;
      let age = vs[at('age')];
      const atk = vs[at('atk')], amp = vs[at('amp')];
      const gl = vs[at('gl')] * amp, gr = vs[at('gr')] * amp;
      const snd = vs[at('send')];
      let ph1 = vs[at('ph1')], ph2 = vs[at('ph2')], ph3 = vs[at('ph3')];
      const inc1 = vs[at('inc1')], inc2 = vs[at('inc2')], inc3 = vs[at('inc3')];
      let g1 = vs[at('g1')], g2 = vs[at('g2')], g3 = vs[at('g3')];
      const m1 = vs[at('m1')], m2 = vs[at('m2')], m3 = vs[at('m3')];
      let penv = vs[at('penv')];
      const pmul = vs[at('pmul')], pdepth = vs[at('pdepth')];
      let na = vs[at('na')];
      const nmul = vs[at('nmul')], hp = vs[at('hp')] > 0.5;
      const fa1 = vs[at('fa1')], fa2 = vs[at('fa2')], fa3 = vs[at('fa3')], fk = vs[at('fk')];
      let ic1 = vs[at('ic1')], ic2 = vs[at('ic2')];
      const gs = vs[at('gsend')] * amp * 0.7;
      const noisy = na > 1e-5;
      for (let i = o; i < o + m; i++) {
        const pm = 1 + pdepth * penv;
        penv *= pmul;
        let x = g1 * this.sn(ph1) + g2 * this.sn(ph2) + g3 * this.sn(ph3);
        ph1 += inc1 * pm; if (ph1 >= 1) ph1 -= Math.floor(ph1);
        ph2 += inc2 * pm; if (ph2 >= 1) ph2 -= Math.floor(ph2);
        ph3 += inc3 * pm; if (ph3 >= 1) ph3 -= Math.floor(ph3);
        g1 *= m1; g2 *= m2; g3 *= m3;
        if (noisy) {
          const w = this.white();
          const v3 = w - ic2;
          const v1 = fa1 * ic1 + fa2 * v3;
          const v2 = ic2 + fa2 * ic1 + fa3 * v3;
          ic1 = 2 * v1 - ic1;
          ic2 = 2 * v2 - ic2;
          x += (hp ? (w - fk * v1 - v2) : v1) * na;
          na *= nmul;
        }
        const env = age < atk ? age / atk : 1;
        age += 1;
        const y = x * env;
        L[i] += y * gl;
        R[i] += y * gr;
        sendL[i] += y * gl * snd;
        sendR[i] += y * gr * snd;
        if (gs > 0) gateIn[i] += y * gs;
      }
      vs[at('age')] = age;
      vs[at('ph1')] = ph1; vs[at('ph2')] = ph2; vs[at('ph3')] = ph3;
      vs[at('g1')] = g1; vs[at('g2')] = g2; vs[at('g3')] = g3;
      vs[at('penv')] = penv; vs[at('na')] = na;
      vs[at('ic1')] = Math.abs(ic1) < 1e-15 ? 0 : ic1;
      vs[at('ic2')] = Math.abs(ic2) < 1e-15 ? 0 : ic2;
      if (age > atk && g1 + g2 + g3 + na < 1e-4) vs[at('on')] = 0;
    }
  }

  // ---------- Render: the gated reverb ----------

  /** A dense, bright room (Freeverb-style combs and allpasses), heard only through a gate that a
   *  BELT hit throws open and that slams shut ~150 ms later, cutting the tail dead. */
  renderGate(L, R, n) {
    const sr = this.sr;
    const fbk = 0.86, damp = 0.22;
    const release = Math.exp(-1 / (0.006 * sr));
    const attack = 1 - Math.exp(-1 / (0.0015 * sr));
    const wet = 1.0;
    const C = this.combCap, A = this.apCap;
    const combBuf = this.combBuf, combLP = this.combLP, combIdx = this.combIdx, combLen = this.combLen;
    const apBuf = this.apBuf, apIdx = this.apIdx, apLen = this.apLen;
    const gateIn = this.gateIn, sendL = this.sendL, sendR = this.sendR;
    for (let i = 0; i < n; i++) {
      if (i === this.gateOpenAt) this.gateHold = Math.max(this.gateHold, this.pendingHold);
      if (this.gateHold > 0) {
        this.gateHold -= 1;
        this.gateEnv += (1 - this.gateEnv) * attack;
      } else {
        this.gateEnv *= release;
      }
      const x = gateIn[i] * 0.2;
      let outL = 0, outR = 0;
      for (let c = 0; c < 8; c++) {
        const base = c * C;
        const j = combIdx[c];
        const y = combBuf[base + j];
        combLP[c] = y * (1 - damp) + combLP[c] * damp;
        combBuf[base + j] = x + combLP[c] * fbk;
        combIdx[c] = j + 1 >= combLen[c] ? 0 : j + 1;
        if (c < 4) outL += y; else outR += y;
      }
      for (let a = 0; a < 4; a++) {
        const base = a * A;
        const j = apIdx[a];
        const b = apBuf[base + j];
        const inp = a < 2 ? outL : outR;
        const o = b - inp;
        apBuf[base + j] = inp + b * 0.5;
        apIdx[a] = j + 1 >= apLen[a] ? 0 : j + 1;
        if (a < 2) outL = o; else outR = o;
      }
      const g = this.gateEnv * wet;
      L[i] += outL * g;
      R[i] += outR * g;
      // A little of the gated room reaches the dub echo too
      sendL[i] += outL * g * 0.2;
      sendR[i] += outR * g * 0.2;
    }
    this.gateOpenAt = -1;
    for (let c = 0; c < 8; c++) if (Math.abs(combLP[c]) < 1e-15) combLP[c] = 0;
    if (this.gateEnv < 1e-6) this.gateEnv = 0;
  }

  // ---------- Render: the dub delay and dust ----------

  readDelay(buf, d) {
    let r = this.dlW - d;
    const cap = this.dlCap;
    while (r < 0) r += cap;
    const i = Math.floor(r);
    const f = r - i;
    const a = buf[i % cap], b = buf[(i + 1) % cap];
    return a + (b - a) * f;
  }

  renderDub(L, R, n) {
    const sr = this.sr, p = this.g;
    const bt = n / sr;
    // Dotted eighth; the time glides (pitching the echoes a little, like tape) when tempo moves
    const target = Math.min(this.dlCap - 4, 60 / Math.max(30, this.bpm) * 0.75 * sr);
    this.dlTime += (target - this.dlTime) * (1 - Math.exp(-bt / 1.2));
    const thr = Math.max(0, Math.min(1, p.throwAmt));
    const fbT = Math.min(0.93, Math.max(0, p.dub) + 0.28 * thr);
    const inT = 0.5 + 0.9 * thr;
    const fb0 = this.fb, in0 = this.inGain;
    this.fb += (fbT - this.fb) * (1 - Math.exp(-bt / 0.25));
    this.inGain += (inT - this.inGain) * (1 - Math.exp(-bt / 0.05));
    const fbInc = (this.fb - fb0) / n, inInc = (this.inGain - in0) / n;
    this.reverbSend += (p.reverbSend - this.reverbSend) * (1 - Math.exp(-bt / 0.5));
    const hpA = 1 - Math.exp(-2 * Math.PI * 220 / sr);
    const lpA = 1 - Math.exp(-2 * Math.PI * 2600 / sr);
    const wowInc = 0.33 / sr;
    let f = fb0, g = in0;
    const dWet = 0.8;
    const { dlL, dlR, sendL, sendR, verbL, verbR } = this;
    const rs = this.reverbSend;
    let hpL = this.hpL, hpR = this.hpR, lpL = this.lpL, lpR = this.lpR;
    for (let i = 0; i < n; i++) {
      f += fbInc; g += inInc;
      this.wowPh += wowInc; if (this.wowPh >= 1) this.wowPh -= 1;
      const d = this.dlTime * (1 + 0.0018 * this.sn(this.wowPh));
      const yL = this.readDelay(dlL, d), yR = this.readDelay(dlR, d);
      // Ping-pong: the input enters left, each side feeds the other
      const inp = (sendL[i] + sendR[i]) * 0.5 * g;
      let xL = inp + f * yR;
      let xR = f * yL;
      // Band-limit and saturate the loop so repeats get darker and rounder
      hpL += (xL - hpL) * hpA; xL -= hpL;
      hpR += (xR - hpR) * hpA; xR -= hpR;
      lpL += (xL - lpL) * lpA;
      lpR += (xR - lpR) * lpA;
      dlL[this.dlW] = Math.tanh(lpL * 1.3) / 1.3;
      dlR[this.dlW] = Math.tanh(lpR * 1.3) / 1.3;
      this.dlW += 1; if (this.dlW >= this.dlCap) this.dlW = 0;
      L[i] += yL * dWet;
      R[i] += yR * dWet;
      verbL[i] = (sendL[i] * 0.35 + yL * 0.55) * rs;
      verbR[i] = (sendR[i] * 0.35 + yR * 0.55) * rs;
    }
    this.hpL = Math.abs(hpL) < 1e-15 ? 0 : hpL; this.hpR = Math.abs(hpR) < 1e-15 ? 0 : hpR;
    this.lpL = Math.abs(lpL) < 1e-15 ? 0 : lpL; this.lpR = Math.abs(lpR) < 1e-15 ? 0 : lpR;

    // Dust: a breath of hiss and the odd crackle, more of it the busier the sky
    this.dust += (p.dust - this.dust) * (1 - Math.exp(-bt / 2));
    if (this.dust > 1e-4) {
      const hissG = 0.0035 * this.dust;
      const rate = (2 + 10 * this.dust) / sr;
      const hA = 1 - Math.exp(-2 * Math.PI * 4500 / sr);
      for (let i = 0; i < n; i++) {
        this.hissL += (this.white() - this.hissL) * hA;
        this.hissR += (this.white() - this.hissR) * hA;
        if (this.rand01() < rate) this.crackle = (this.white() > 0 ? 1 : -1) * (0.01 + 0.03 * this.rand01()) * this.dust;
        const c = this.crackle;
        this.crackle *= 0.55;
        L[i] += this.hissL * hissG + c;
        R[i] += this.hissR * hissG + c * 0.7;
      }
    }
  }

  // ---------- Render ----------

  /** Render n frames: the dry bus (with echoes) into L/R and the plate send into VL/VR. */
  render(n0, L, R, VL, VR) {
    if (n0 <= 0) return;
    const n = Math.min(n0, OD.MAX_FRAMES);
    L.fill(0, 0, n0); R.fill(0, 0, n0);
    this.sendL.fill(0, 0, n); this.sendR.fill(0, 0, n); this.gateIn.fill(0, 0, n);
    const sr = this.sr, p = this.g;
    const bt = n / sr;
    this.bpm += (p.bpm - this.bpm) * (1 - Math.exp(-bt / 0.4));

    // Transport: the sweep starts at north
    const wantRun = p.run > 0.5;
    if (wantRun && !this.running) {
      this.running = true;
      this.sweep = 0;
      this.beats = 0;
      for (let t = 0; t < OD.TRACKS; t++) this.adopt(t);
    } else if (!wantRun && this.running) {
      this.running = false;
    }

    // One revolution per bar (sixteenths grid) or per two bars (eighths grid)
    const sweepBeats = p.division > 3 ? 4 : 8;
    const perSample = Math.max(30, this.bpm) / 60 / sweepBeats / sr;
    let o = 0;
    while (o < n) {
      const m = Math.min(32, n - o);
      this.chunkOffset = o;
      this.events();
      if (this.running) {
        const a = this.sweep;
        let b = a + perSample * m;
        this.fire(a, Math.min(b, 1));
        if (b >= 1) {
          b -= 1;
          for (let t = 0; t < OD.TRACKS; t++) if (this.pGen[t] !== this.gen[t]) this.adopt(t);
          this.fire(0, b);
        }
        this.sweep = b;
        this.beats += perSample * m * sweepBeats;
      }
      this.renderVoices(L, R, o, m);
      o += m;
    }

    this.renderGate(L, R, n);
    this.renderDub(L, R, n);

    // Master: soft clip the dry bus; the plate send takes the same gain
    const m0 = this.masterG;
    this.masterG += (p.master - this.masterG) * (1 - Math.exp(-bt / 0.6));
    const mInc = (this.masterG - m0) / n;
    let mg = m0;
    const { verbL, verbR } = this;
    for (let i = 0; i < n; i++) {
      mg += mInc;
      L[i] = Math.tanh(L[i] * mg);
      R[i] = Math.tanh(R[i] * mg);
      VL[i] = verbL[i] * mg;
      VR[i] = verbR[i] * mg;
    }
  }
}

if (typeof module !== 'undefined') module.exports = { OrbitDSP, OD };
