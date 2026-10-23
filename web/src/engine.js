'use strict';
/* The page's audio engine: one AudioContext, one AudioWorkletNode running OrbitDSP, and the
 * plate reverb, limiter and master chain around it.
 *
 *   OrbitDSP dry  (drums + dub echoes) --------------------------------- master -- limiter -- out
 *   OrbitDSP send -- plate (convolver) -- high-pass 320 -- low-pass 6k -- level --'
 *
 * Settings made before the context exists (it can only be created on a tap) are remembered
 * and replayed when it starts. */

class OrbitEngine {
  /** @param {string} workletSource  the text of dsp.js + worklet.js, loaded as a module */
  constructor(workletSource) {
    this.src = workletSource;
    this.ctx = null;
    this.node = null;
    this.ready = null;                  // promise for the one-time setup
    this.wantsRunning = false;
    this.stopToken = 0;
    // Remembered state, replayed into a new worklet
    this.params = { master: 0, run: 0, bpm: 84, swing: 0.1, division: 2, quantize: 0.5, dub: 0.55,
                    throwAmt: 0, reverbSend: 0.6, dust: 0 };
    this.lists = [null, null, null, null];
    this.mutes = [0, 0, 0, 0];
    this.brights = [0.5, 0.5, 0.5, 0.5];
    this.plateGainValue = 0.92;
    // Beam estimate (the worklet reports every ~20 ms; we interpolate between reports)
    this.last = { s: 0, b: 0, r: false, perf: 0 };
    this.keepAlive = null;
  }

  // ---------- Control (safe before start) ----------

  post(m) { if (this.node) this.node.port.postMessage(m); }

  set(k, v) { this.params[k] = v; this.post({ type: 'set', k, v }); }

  setList(t, list) { this.lists[t] = list; this.post(Object.assign({ type: 'list', t }, list)); }

  setMute(t, muted) { this.mutes[t] = muted ? 1 : 0; this.post({ type: 'mute', t, v: muted ? 1 : 0 }); }

  setBright(t, v) { this.brights[t] = v; this.post({ type: 'bright', t, v }); }

  ping(f, v, p) { this.post({ type: 'ping', f, v, p }); }

  gong(f, v, p) { this.post({ type: 'gong', f, v, p }); }

  /** 0..1: how much plate (the send amount, and the return level, as in the iPhone app). */
  setSpace(x) {
    this.set('reverbSend', 0.2 + 0.8 * x);
    this.plateGainValue = Math.max(0.05, 0.5 + 0.7 * x);
    if (this.plateGain) this.plateGain.gain.setTargetAtTime(this.plateGainValue, this.ctx.currentTime, 0.05);
  }

  get isRunning() { return this.wantsRunning; }

  // ---------- Life cycle ----------

  /** Create the context and graph (once) and make sure it's running. Must follow a tap. */
  async start() {
    this.stopToken++;
    this.wantsRunning = true;
    this._unlockiOS();
    if (!this.ready) this.ready = this._build();
    await this.ready;
    if (this.ctx.state !== 'running') await this.ctx.resume();
    this.set('master', 0.85);
    this.set('run', 1);
  }

  /** Fade out, let the echoes and plate ring, then suspend the context to save power. */
  stop() {
    this.wantsRunning = false;
    this.set('run', 0);
    this.set('master', 0);
    const token = ++this.stopToken;
    setTimeout(() => {
      if (token === this.stopToken && !this.wantsRunning && this.ctx && this.ctx.state === 'running') {
        this.ctx.suspend().catch(() => {});
        this._releaseiOS();
      }
    }, 6000);
  }

  /** Where the beam is, 0..1 from north, and the beats since play. */
  beam(now = performance.now()) {
    const l = this.last;
    if (!l.r) return { sweep: l.s, beats: l.b, running: false };
    const sweepBeats = this.params.division > 3 ? 4 : 8;
    const rate = Math.max(30, this.params.bpm) / 60 / sweepBeats;   // sweeps per second
    // What's coming out of the speakers lags what the worklet just rendered by the output latency
    const lat = this.ctx ? (this.ctx.baseLatency || 0) + (this.ctx.outputLatency || 0) : 0;
    const dt = Math.max(0, Math.min(0.25, (now - l.perf) / 1000));
    let s = l.s + (dt - lat) * rate;
    s -= Math.floor(s);
    return { sweep: s, beats: l.b + dt * rate * sweepBeats, running: true };
  }

  async _build() {
    const AC = window.AudioContext || window.webkitAudioContext;
    const ctx = this.ctx = new AC({ latencyHint: 'playback' });
    const url = URL.createObjectURL(new Blob([this.src], { type: 'text/javascript' }));
    try { await ctx.audioWorklet.addModule(url); }
    catch (e) {   // a page opened from file:// has an opaque origin and can't load blob modules; a data: URL can
      await ctx.audioWorklet.addModule('data:text/javascript;base64,' + btoa(unescape(encodeURIComponent(this.src))));
    } finally { URL.revokeObjectURL(url); }
    const node = this.node = new AudioWorkletNode(ctx, 'orbitakt', {
      numberOfInputs: 0, numberOfOutputs: 2, outputChannelCount: [2, 2],
    });
    node.port.onmessage = (e) => {
      const m = e.data;
      this.last = { s: m.s, b: m.b, r: m.r, perf: performance.now() };
    };

    // Master and a safety limiter (the iPhone app has one too): a fast compressor set as a limiter
    const limiter = ctx.createDynamicsCompressor();
    limiter.threshold.value = -2; limiter.knee.value = 0; limiter.ratio.value = 20;
    limiter.attack.value = 0.003; limiter.release.value = 0.15;
    limiter.connect(ctx.destination);
    node.connect(limiter, 0);

    // The plate
    const plate = ctx.createConvolver();
    plate.normalize = false;
    const ir = makePlateIR(ctx.sampleRate);
    const buf = ctx.createBuffer(2, ir[0].length, ctx.sampleRate);
    buf.copyToChannel(ir[0], 0); buf.copyToChannel(ir[1], 1);
    plate.buffer = buf;
    const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 320; hp.Q.value = 0.707;
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 6000; lp.Q.value = 0.707;
    const gain = this.plateGain = ctx.createGain();
    gain.gain.value = this.plateGainValue;
    node.connect(plate, 1);
    plate.connect(hp); hp.connect(lp); lp.connect(gain); gain.connect(limiter);

    // Replay what was set before we existed
    for (const [k, v] of Object.entries(this.params)) this.post({ type: 'set', k, v });
    this.lists.forEach((l, t) => { if (l) this.post(Object.assign({ type: 'list', t }, l)); });
    this.mutes.forEach((v, t) => this.post({ type: 'mute', t, v }));
    this.brights.forEach((v, t) => this.post({ type: 'bright', t, v }));

    // If the system interrupts us (a call, the phone locking), come back when asked
    ctx.onstatechange = () => { this.onstate && this.onstate(ctx.state); };
  }

  /** On iPhone the ringer switch silences Web Audio unless the page is "playing media". A silent
   *  looping <audio> element, and the audio session type where the browser supports it, fix that. */
  _unlockiOS() {
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
    if (this.keepAlive) { this.keepAlive.play().catch(() => {}); return; }
    try {
      const sr = 8000, n = 800, buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
      const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
      w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); v.setUint32(16, 16, true);
      v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, sr, true); v.setUint32(28, sr * 2, true);
      v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
      const a = new Audio(URL.createObjectURL(new Blob([buf], { type: 'audio/wav' })));
      a.loop = true; a.volume = 0.01;
      a.setAttribute('playsinline', '');
      this.keepAlive = a;
      a.play().catch(() => {});
    } catch (e) {}
  }

  _releaseiOS() { try { this.keepAlive && this.keepAlive.pause(); } catch (e) {} }
}

if (typeof module !== 'undefined') module.exports = { OrbitEngine };
